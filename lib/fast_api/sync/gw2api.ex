defmodule FastApi.Sync.GW2API do
  @moduledoc "Synchronize the spreadsheet using GW2 API data."
  import Ecto.Query, only: [where: 3, select: 3, order_by: 3]

  alias FastApi.Repo
  alias FastApi.Schemas.Fast

  require Logger

  @items "https://api.guildwars2.com/v2/items"
  @prices "https://api.guildwars2.com/v2/commerce/prices"
  @step 200
  @concurrency min(System.schedulers_online() * 2, 8)
  @chunk_attempts 3
  @chunk_backoff_ms 1_500
  @flags_cache_ttl_ms 86_400_000
  @flags_cache_table :gw2_flags

  defp ensure_flags_cache! do
    case :ets.info(@flags_cache_table) do
      :undefined ->
        try do
          :ets.new(@flags_cache_table, [:named_table, :set, :public, read_concurrency: true])
        catch
          :error, :badarg -> :ok
        end

      _ ->
        :ok
    end

    :ok
  end

  defp flags_lookup(id) do
    case :ets.info(@flags_cache_table) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(@flags_cache_table, id) do
          [{^id, flags, ts}] -> {flags, ts}
          _ -> nil
        end
    end
  end

  defp flags_insert(id, flags, ts) do
    case :ets.info(@flags_cache_table) do
      :undefined -> :ok
      _ -> :ets.insert(@flags_cache_table, {id, flags, ts})
    end
  end

  defp fmt_ms(ms) do
    total = div(ms, 1000)
    mins = div(total, 60)
    secs = rem(total, 60)
    "#{mins}:#{String.pad_leading(Integer.to_string(secs), 2, "0")} mins"
  end

  defp now_ts(), do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  defp mono_ms(), do: System.monotonic_time(:millisecond)

  @spec sync_items() :: :ok
  def sync_items do
    item_ids = get_item_ids()
    commerce_item_ids = get_commerce_item_ids()
    tradable_set = MapSet.new(commerce_item_ids)

    {tradable_ids, non_tradable_ids} =
      Enum.split_with(item_ids, &MapSet.member?(tradable_set, &1))

    now = now_ts()

    tradable_rows =
      tradable_ids
      |> get_details(@items)
      |> Enum.map(&to_item(&1, true))
      |> to_insert_rows(now)

    non_tradable_rows =
      non_tradable_ids
      |> get_details(@items)
      |> Enum.map(&to_item/1)
      |> to_insert_rows(now)

    batch_upsert(tradable_rows)
    batch_upsert(non_tradable_rows)

    :ok
  end

  @spec sync_prices() :: {:ok, %{updated: non_neg_integer, changed_ids: MapSet.t()}}
  def sync_prices do
    ensure_flags_cache!()

    items =
      Fast.Item
      |> where([i], i.tradable == true)
      |> select([i], %{id: i.id, vendor_value: i.vendor_value, buy_old: i.buy, sell_old: i.sell})
      |> Repo.all()

    pairs =
      items
      |> Enum.chunk_every(@step)
      |> Task.async_stream(&fetch_prices_for_chunk_with_retry/1,
        max_concurrency: @concurrency,
        timeout: 30_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.flat_map(fn
        {:ok, pairs} -> pairs
        {:exit, reason} ->
          Logger.error("concurrent fetch failed (final): #{inspect(reason)}")
          []
      end)

    {rows_changed, {_zeroed_bound_no_vendor, changed_ids}} =
      pairs
      |> Enum.map_reduce({0, MapSet.new()}, fn
        {%{id: id, vendor_value: vendor, buy_old: buy_old, sell_old: sell_old},
         %{"buys" => buys, "sells" => sells, "flags" => flags}}, {acc_zero, acc_ids} ->
          {buy, sell, zero_inc} =
            if accountbound_only?(flags) do
              cond do
                is_nil(vendor) or vendor == 0 -> {0, 0, 1}
                true -> {vendor, 0, 0}
              end
            else
              buy0  = buys  && Map.get(buys,  "unit_price")
              sell0 = sells && Map.get(sells, "unit_price")
              buy_v = if is_nil(buy0) or buy0 == 0, do: vendor || 0, else: buy0
              sell_v = if is_nil(sell0), do: 0, else: sell0
              {buy_v, sell_v, 0}
            end

          if buy != buy_old or sell != sell_old do
            row = %{id: id, buy: buy, sell: sell}
            {row, {acc_zero + zero_inc, MapSet.put(acc_ids, id)}}
          else
            {nil, {acc_zero + zero_inc, acc_ids}}
          end

        _other, acc ->
          {nil, acc}
      end)

    rows_changed = Enum.reject(rows_changed, &is_nil/1)
    now = now_ts()

    updated =
      rows_changed
      |> Enum.chunk_every(5_000)
      |> Enum.reduce(0, fn batch, acc ->
        batch_with_ts =
          Enum.map(batch, fn row ->
            row
            |> Map.put(:inserted_at, now)  # overwrite to satisfy NOT NULL on first insert
            |> Map.put(:updated_at, now)
          end)

        {count, _} =
          Repo.insert_all(
            Fast.Item,
            batch_with_ts,
            on_conflict: {:replace, [:buy, :sell, :updated_at]},
            conflict_target: [:id]
          )

        acc + count
      end)

    {:ok, %{updated: updated, changed_ids: changed_ids}}
  end

  def sync_sheet do
    t0 = mono_ms()

    {:ok, %{updated: updated_prices, changed_ids: changed_ids}} = sync_prices()

    items =
      Fast.Item
      |> select([i], %{id: i.id, name: i.name, buy: i.buy, sell: i.sell, icon: i.icon, rarity: i.rarity, vendor_value: i.vendor_value})
      |> order_by([i], asc: i.id)
      |> Repo.all()

    total_rows = length(items)

    {:ok, token} = Goth.fetch(FastApi.Goth)
    connection = GoogleApi.Sheets.V4.Connection.new(token.token)

    sheet_id = "1WdwWxyP9zeJhcxoQAr-paMX47IuK6l5rqAPYDOA8mho"

    cond do
      MapSet.size(changed_ids) == 0 ->
        dt = mono_ms() - t0
        Logger.info("[job] gw2.sync_sheet completed in #{fmt_ms(dt)} prices_updated=#{updated_prices} rows_written=0")
        :ok

      MapSet.size(changed_ids) > trunc(total_rows * 0.8) ->
        values =
          Enum.map(items, fn i -> [i.id, i.name, i.buy, i.sell, i.icon, i.rarity, i.vendor_value] end)

        {:ok, _response} =
          GoogleApi.Sheets.V4.Api.Spreadsheets.sheets_spreadsheets_values_update(
            connection,
            sheet_id,
            "API!A4:G#{4 + total_rows}",
            body: %{values: values},
            valueInputOption: "RAW"
          )

        dt = mono_ms() - t0
        Logger.info("[job] gw2.sync_sheet completed in #{fmt_ms(dt)} prices_updated=#{updated_prices} rows_written=#{total_rows}")
        :ok

      true ->
        idx_map =
          items
          |> Enum.with_index()
          |> Map.new(fn {%{id: id}, idx} -> {id, idx} end)

        data =
          items
          |> Stream.filter(fn i -> MapSet.member?(changed_ids, i.id) end)
          |> Stream.map(fn i ->
            row = Map.fetch!(idx_map, i.id) + 4
            %{
              range: "API!C#{row}:D#{row}",
              values: [[i.buy, i.sell]]
            }
          end)
          |> Enum.to_list()

        if data == [] do
          :ok
        else
          {:ok, _resp} =
            GoogleApi.Sheets.V4.Api.Spreadsheets.sheets_spreadsheets_values_batch_update(
              connection,
              sheet_id,
              body: %{
                data: data,
                valueInputOption: "RAW"
              }
            )

          dt = mono_ms() - t0
          Logger.info("[job] gw2.sync_sheet completed in #{fmt_ms(dt)} prices_updated=#{updated_prices} rows_written=#{length(data)}")
          :ok
        end
    end
  end

  defp get_details(ids, base_url) do
    ids
    |> Enum.chunk_every(@step)
    |> Task.async_stream(
      fn chunk -> get_details_chunk_with_retry(chunk, base_url) end,
      max_concurrency: @concurrency,
      timeout: 30_000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, list} -> list
      {:exit, reason} ->
        Logger.error("items fetch failed (final): #{inspect(reason)}")
        []
    end)
    |> Enum.map(&keys_to_atoms/1)
  end

  defp get_item_ids do
    Finch.build(:get, @items)
    |> request_json()
  end

  defp get_commerce_item_ids do
    Finch.build(:get, @prices)
    |> request_json()
  end

  defp request_json(request, retry \\ 0) do
    case Finch.request(request, FastApi.Finch) do
      {:ok, %Finch.Response{status: status, body: body}} when status >= 500 ->
        Logger.error("HTTP #{status} from remote; body_snippet=#{inspect(String.slice(to_string(body), 0, 200))}")
        []
      {:ok, %Finch.Response{status: status, body: body}} ->
        case Jason.decode(body) do
          {:ok, decoded} when is_list(decoded) ->
            if status != 200 do
              Logger.error("HTTP #{status} with list body from remote: #{inspect(Enum.take(decoded, 1))}")
            end
            decoded
          {:ok, decoded} when is_map(decoded) ->
            if status != 200 do
              Logger.error("HTTP #{status} with map body from remote: #{inspect(decoded)}")
            end
            [decoded]
          {:ok, _other} ->
            Logger.error("Unexpected JSON shape (status #{status})")
            []
          {:error, error} ->
            Logger.error("Failed to decode JSON (status #{status}): #{inspect(error)} body_snippet=#{inspect(String.slice(to_string(body), 0, 200))}")
            []
        end
      {:error, %Mint.TransportError{reason: :timeout}} when retry < 5 ->
        request_json(request, retry + 1)
      {:error, error} ->
        Logger.error("HTTP request error: #{inspect(error)}")
        []
    end
  end

  defp keys_to_atoms(map) do
    Enum.into(map, %{}, fn {key, value} -> {String.to_atom(key), value} end)
  end

  defp to_item(params, tradable \\ false) do
    params
    |> Map.put(:tradable, tradable)
    |> then(&struct(Fast.Item, &1))
  end

  defp accountbound_only?(flags) when is_list(flags) do
    Enum.any?(flags, &(&1 == "AccountBound"))
  end
  defp accountbound_only?(_), do: false

  defp to_insert_rows(items, now) do
    items
    |> Stream.map(&Map.from_struct/1)
    |> Stream.map(&Map.drop(&1, [:__meta__, :__struct__]))
    |> Stream.map(fn row ->
      row
      |> Map.put(:inserted_at, now)  # overwrite even if nil
      |> Map.put(:updated_at, now)
    end)
    |> Enum.to_list()
  end

  defp batch_upsert(rows) do
    rows
    |> Enum.chunk_every(5_000)
    |> Enum.each(fn batch ->
      Repo.insert_all(
        Fast.Item,
        batch,
        # keep original inserted_at when row already exists
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: [:id]
      )
    end)
  end

  defp fetch_prices_for_chunk(chunk) do
    now = mono_ms()
    ids = Enum.map(chunk, & &1.id)

    misses =
      ids
      |> Enum.reject(fn id ->
        case flags_lookup(id) do
          {_, ts} -> now - ts < @flags_cache_ttl_ms
          _ -> false
        end
      end)

    if misses != [] do
      result = get_details_chunk_with_retry(misses, @items)
      Enum.each(result, fn %{"id" => id, "flags" => flags} ->
        flags_insert(id, flags || [], now)
      end)
    end

    flags_by_id =
      ids
      |> Enum.map(fn id ->
        case flags_lookup(id) do
          {flags, _ts} -> {id, flags}
          _ -> {id, []}
        end
      end)
      |> Map.new()

    req_prices = "#{@prices}?ids=#{Enum.map_join(ids, ",", & &1)}"

    prices =
      Finch.build(:get, req_prices)
      |> request_json()

    prices_by_id =
      prices
      |> Enum.filter(&match?(%{"id" => _}, &1))
      |> Map.new(&{&1["id"], &1})

    for item <- chunk,
        price = Map.get(prices_by_id, item.id),
        not is_nil(price) do
      merged = Map.put(price, "flags", Map.get(flags_by_id, item.id, []))
      {item, merged}
    end
  end

  defp fetch_prices_for_chunk_with_retry(chunk, attempts \\ @chunk_attempts, backoff \\ @chunk_backoff_ms) do
    :timer.sleep(:rand.uniform(300))
    try do
      res = fetch_prices_for_chunk(chunk)
      cond do
        res == [] and attempts > 1 ->
          :timer.sleep(backoff)
          fetch_prices_for_chunk_with_retry(chunk, attempts - 1, backoff * 2)
        res == [] ->
          Logger.error("prices empty after retries ids=#{Enum.map(chunk, & &1.id)}")
          []
        true ->
          res
      end
    rescue
      e ->
        if attempts > 1 do
          Logger.warning("prices error=#{Exception.message(e)}; retrying in #{backoff}ms")
          :timer.sleep(backoff)
          fetch_prices_for_chunk_with_retry(chunk, attempts - 1, backoff * 2)
        else
          Logger.error("prices error (final): #{Exception.message(e)} ids=#{Enum.map(chunk, & &1.id)}")
          []
        end
    catch
      :exit, reason ->
        if attempts > 1 do
          Logger.warning("prices exit=#{inspect(reason)}; retrying in #{backoff}ms")
          :timer.sleep(backoff)
          fetch_prices_for_chunk_with_retry(chunk, attempts - 1, backoff * 2)
        else
          Logger.error("prices failed after retries: #{inspect(reason)} ids=#{Enum.map(chunk, & &1.id)}")
          []
        end
    end
  end

  defp get_details_chunk_with_retry(chunk, base_url, attempts \\ @chunk_attempts, backoff \\ @chunk_backoff_ms) do
    :timer.sleep(:rand.uniform(300))
    req_url = "#{base_url}?ids=#{Enum.join(chunk, ",")}"
    try do
      result =
        Finch.build(:get, req_url)
        |> request_json()

      if length(result) != length(chunk) do
        missing_ids = chunk -- Enum.map(result, &Map.get(&1, "id"))
        Logger.error("Missing IDs for #{req_url}: #{inspect(missing_ids)}")
      end

      cond do
        result == [] and attempts > 1 ->
          :timer.sleep(backoff)
          get_details_chunk_with_retry(chunk, base_url, attempts - 1, backoff * 2)
        result == [] ->
          Logger.error("items empty after retries url=#{req_url}")
          []
        true ->
          result
      end
    rescue
      e ->
        if attempts > 1 do
          Logger.warning("items error=#{Exception.message(e)}; retrying in #{backoff}ms url=#{req_url}")
          :timer.sleep(backoff)
          get_details_chunk_with_retry(chunk, base_url, attempts - 1, backoff * 2)
        else
          Logger.error("items error (final) url=#{req_url} error=#{Exception.message(e)}")
          []
        end
    catch
      :exit, reason ->
        if attempts > 1 do
          Logger.warning("items exit=#{inspect(reason)}; retrying in #{backoff}ms url=#{req_url}")
          :timer.sleep(backoff)
          get_details_chunk_with_retry(chunk, base_url, attempts - 1, backoff * 2)
        else
          Logger.error("items failed after retries url=#{req_url} reason=#{inspect(reason)}")
          []
        end
    end
  end
end
