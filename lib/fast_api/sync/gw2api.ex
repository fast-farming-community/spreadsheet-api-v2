defmodule FastApi.Sync.GW2API do
  @moduledoc "Synchronize the spreadsheet using GW2 API data."
  import Ecto.Query, only: [from: 2, where: 3, select: 3, order_by: 3]

  alias FastApi.Repo
  alias FastApi.Schemas.Fast

  require Logger

  @items "https://api.guildwars2.com/v2/items"
  @prices "https://api.guildwars2.com/v2/commerce/prices"
  @step 150
  @concurrency System.schedulers_online() * 4
  @chunk_attempts 3
  @chunk_backoff_ms 600

  defp fmt_ms(ms) do
    total = div(ms, 1000)
    mins = div(total, 60)
    secs = rem(total, 60)
    "#{mins}:#{String.pad_leading(Integer.to_string(secs), 2, "0")} mins"
  end

  @spec sync_items() :: :ok
  def sync_items do
    item_ids = get_item_ids()
    commerce_item_ids = get_commerce_item_ids()
    tradable_set = MapSet.new(commerce_item_ids)

    {tradable_ids, non_tradable_ids} =
      Enum.split_with(item_ids, &MapSet.member?(tradable_set, &1))

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

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

  @spec sync_prices() :: {:ok, non_neg_integer}
  def sync_prices do
    t0 = System.monotonic_time(:millisecond)

    items =
      Fast.Item
      |> where([i], i.tradable == true)
      |> select([i], %{id: i.id, vendor_value: i.vendor_value})
      |> Repo.all()

    pairs =
      items
      |> Enum.chunk_every(@step)
      |> Task.async_stream(&fetch_prices_for_chunk_with_retry/1,
        max_concurrency: @concurrency,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, pairs} -> pairs
        {:exit, reason} ->
          Logger.error("concurrent fetch failed (final): #{inspect(reason)}")
          []
      end)

    {rows, zeroed_bound_no_vendor} =
      pairs
      |> Enum.map_reduce(0, fn
        {%{id: id, vendor_value: vendor}, %{"buys" => buys, "sells" => sells} = m}, acc ->
          flags = Map.get(m, "flags", [])

          if accountbound_only?(flags) do
            cond do
              is_nil(vendor) or vendor == 0 ->
                {%{id: id, buy: 0, sell: 0}, acc + 1}
              true ->
                {%{id: id, buy: vendor, sell: 0}, acc}
            end
          else
            buy0  = buys  && Map.get(buys,  "unit_price")
            sell0 = sells && Map.get(sells, "unit_price")
            buy   = if is_nil(buy0) or buy0 == 0, do: vendor || 0, else: buy0
            sell  = if is_nil(sell0), do: 0, else: sell0
            {%{id: id, buy: buy, sell: sell}, acc}
          end

        _other, acc ->
          {nil, acc}
      end)

    rows = Enum.reject(rows, &is_nil/1)

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    updated =
      rows
      |> Enum.chunk_every(5_000)
      |> Enum.reduce(0, fn batch, acc ->
        batch_with_ts =
          Enum.map(batch, fn row ->
            row
            |> Map.put_new(:inserted_at, now)
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

    dt = System.monotonic_time(:millisecond) - t0
    Logger.info("[job] gw2.sync_prices completed in #{fmt_ms(dt)} updated=#{updated} zeroed_bound_no_vendor=#{zeroed_bound_no_vendor}")

    {:ok, updated}
  end

  defp fetch_prices_for_chunk(chunk) do
    ids = Enum.map(chunk, & &1.id)

    req_prices = "#{@prices}?ids=#{Enum.map_join(ids, ",", & &1)}"
    req_items  = "#{@items}?ids=#{Enum.map_join(ids, ",", & &1)}"

    prices =
      Finch.build(:get, req_prices)
      |> request_json()

    items =
      Finch.build(:get, req_items)
      |> request_json()

    prices_by_id =
      prices
      |> Enum.filter(&match?(%{"id" => _}, &1))
      |> Map.new(&{&1["id"], &1})

    flags_by_id =
      items
      |> Enum.filter(&match?(%{"id" => _}, &1))
      |> Map.new(&{&1["id"], Map.get(&1, "flags", [])})

    for item <- chunk,
        price = Map.get(prices_by_id, item.id),
        not is_nil(price) do
      merged = Map.put(price, "flags", Map.get(flags_by_id, item.id, []))
      {item, merged}
    end
  end

  def sync_sheet do
    t0 = System.monotonic_time(:millisecond)

    {:ok, updated_prices} = sync_prices()

    items =
      Fast.Item
      |> select([i], [i.id, i.name, i.buy, i.sell, i.icon, i.rarity, i.vendor_value])
      |> order_by([i], asc: i.id)
      |> Repo.all()

    {:ok, token} = Goth.fetch(FastApi.Goth)
    connection = GoogleApi.Sheets.V4.Connection.new(token.token)

    {:ok, _response} =
      GoogleApi.Sheets.V4.Api.Spreadsheets.sheets_spreadsheets_values_update(
        connection,
        "1WdwWxyP9zeJhcxoQAr-paMX47IuK6l5rqAPYDOA8mho",
        "API!A4:G#{4 + length(items)}",
        body: %{values: items},
        valueInputOption: "RAW"
      )

    dt = System.monotonic_time(:millisecond) - t0
    Logger.info("[job] gw2.sync_sheet completed in #{fmt_ms(dt)} prices_updated=#{updated_prices} rows_written=#{length(items)}")

    :ok
  end

  defp get_details(ids, base_url) do
    ids
    |> Enum.chunk_every(@step)
    |> Task.async_stream(
      fn chunk -> get_details_chunk_with_retry(chunk, base_url) end,
      max_concurrency: @concurrency,
      timeout: 30_000,
      on_timeout: :kill_task
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
            Logger.error("Failed to decode JSON (status #{status}): #{inspect(error)} body_snippet=#{inspect(String.slice(to_string(body), 0, 400))}")
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
      |> Map.put_new(:inserted_at, now)
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
        on_conflict: :replace_all,
        conflict_target: [:id]
      )
    end)
  end

  defp fetch_prices_for_chunk_with_retry(chunk, attempts \\ @chunk_attempts, backoff \\ @chunk_backoff_ms) do
    try do
      res = fetch_prices_for_chunk(chunk)
      cond do
        res == [] and attempts > 1 ->
          Logger.warn("prices empty; retrying in #{backoff}ms (left=#{attempts - 1}) ids=#{Enum.map(chunk, & &1.id)}")
          :timer.sleep(backoff)
          fetch_prices_for_chunk_with_retry(chunk, attempts - 1, backoff * 2)
        res == [] ->
          Logger.error("prices empty after retries ids=#{Enum.map(chunk, & &1.id)}")
          []
        true ->
          res
      end
    catch
      :exit, reason ->
        if attempts > 1 do
          Logger.warn("prices exit=#{inspect(reason)}; retrying in #{backoff}ms (left=#{attempts - 1})")
          :timer.sleep(backoff)
          fetch_prices_for_chunk_with_retry(chunk, attempts - 1, backoff * 2)
        else
          Logger.error("prices failed after retries: #{inspect(reason)} ids=#{Enum.map(chunk, & &1.id)}")
          []
        end
    rescue
      e ->
        if attempts > 1 do
          Logger.warn("prices error=#{Exception.message(e)}; retrying in #{backoff}ms (left=#{attempts - 1})")
          :timer.sleep(backoff)
          fetch_prices_for_chunk_with_retry(chunk, attempts - 1, backoff * 2)
        else
          Logger.error("prices error (final): #{Exception.message(e)} ids=#{Enum.map(chunk, & &1.id)}")
          []
        end
    end
  end

  defp get_details_chunk_with_retry(chunk, base_url, attempts \\ @chunk_attempts, backoff \\ @chunk_backoff_ms) do
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
          Logger.warn("items empty; retrying in #{backoff}ms (left=#{attempts - 1}) url=#{req_url}")
          :timer.sleep(backoff)
          get_details_chunk_with_retry(chunk, base_url, attempts - 1, backoff * 2)
        result == [] ->
          Logger.error("items empty after retries url=#{req_url}")
          []
        true ->
          result
      end
    catch
      :exit, reason ->
        if attempts > 1 do
          Logger.warn("items exit=#{inspect(reason)}; retrying in #{backoff}ms (left=#{attempts - 1}) url=#{req_url}")
          :timer.sleep(backoff)
          get_details_chunk_with_retry(chunk, base_url, attempts - 1, backoff * 2)
        else
          Logger.error("items failed after retries url=#{req_url} reason=#{inspect(reason)}")
          []
        end
    rescue
      e ->
        if attempts > 1 do
          Logger.warn("items error=#{Exception.message(e)}; retrying in #{backoff}ms (left=#{attempts - 1}) url=#{req_url}")
          :timer.sleep(backoff)
          get_details_chunk_with_retry(chunk, base_url, attempts - 1, backoff * 2)
        else
          Logger.error("items error (final) url=#{req_url} error=#{Exception.message(e)}")
          []
        end
    end
  end
end
