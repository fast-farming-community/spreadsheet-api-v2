defmodule FastApi.Sync.GW2API do
  @moduledoc "Synchronize the spreadsheet using GW2 API data."
  import Ecto.Query, only: [where: 3, select: 3, order_by: 3, limit: 2]

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

  @hot_quantity_min 1_000
  @per_run_cap 2_000

  defp fmt_ms(ms) do
    total = div(ms, 1000)
    "#{div(total, 60)}:#{String.pad_leading(Integer.to_string(rem(total, 60)), 2, "0")} mins"
  end

  defp now_ts(), do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  defp mono_ms(), do: System.monotonic_time(:millisecond)

  defp ensure_flags_cache! do
    case :ets.info(@flags_cache_table) do
      :undefined -> :ets.new(@flags_cache_table, [:named_table, :set, :public, read_concurrency: true])
      _ -> :ok
    end
  end

  defp with_retry(fun, attempts \\ @chunk_attempts, backoff \\ @chunk_backoff_ms) do
    :timer.sleep(:rand.uniform(300))
    try do
      case fun.() do
        [] when attempts > 1 ->
          :timer.sleep(backoff)
          with_retry(fun, attempts - 1, backoff * 2)
        [] ->
          []
        res ->
          res
      end
    rescue
      e ->
        if attempts > 1 do
          Logger.warning("retryable error=#{Exception.message(e)}; retrying in #{backoff}ms")
          :timer.sleep(backoff)
          with_retry(fun, attempts - 1, backoff * 2)
        else
          Logger.error("error (final): #{Exception.message(e)}")
          []
        end
    catch
      :exit, reason ->
        if attempts > 1 do
          Logger.warning("exit=#{inspect(reason)}; retrying in #{backoff}ms")
          :timer.sleep(backoff)
          with_retry(fun, attempts - 1, backoff * 2)
        else
          Logger.error("failed after retries: #{inspect(reason)}")
          []
        end
    end
  end

  defp http_json(url) do
    case Finch.request(Finch.build(:get, url), FastApi.Finch) do
      {:ok, %Finch.Response{status: status, body: body}} when status >= 500 ->
        Logger.error("HTTP #{status} from remote; body_snippet=#{inspect(String.slice(to_string(body), 0, 200))}")
        []
      {:ok, %Finch.Response{status: status, body: body}} ->
        case Jason.decode(body) do
          {:ok, list} when is_list(list) ->
            if status != 200, do: Logger.error("HTTP #{status} with list body from remote: #{inspect(Enum.take(list, 1))}")
            list
          {:ok, map} when is_map(map) ->
            if status != 200, do: Logger.error("HTTP #{status} with map body from remote: #{inspect(map)}")
            [map]
          {:ok, _other} ->
            Logger.error("Unexpected JSON shape (status #{status})")
            []
          {:error, err} ->
            Logger.error("Failed to decode JSON (status #{status}): #{inspect(err)} body_snippet=#{inspect(String.slice(to_string(body), 0, 200))}")
            []
        end
      {:error, %Mint.TransportError{reason: :timeout}} ->
        []
      {:error, err} ->
        Logger.error("HTTP request error: #{inspect(err)}")
        []
    end
  end

  defp fetch_json_ids(base_url, ids) do
    http_json("#{base_url}?ids=#{Enum.join(ids, ",")}")
  end

  @spec sync_items() :: :ok
  def sync_items do
    item_ids = Finch.build(:get, @items) |> request_json()
    commerce_item_ids = Finch.build(:get, @prices) |> request_json()
    tradable_set = MapSet.new(commerce_item_ids)

    {tradable_ids, non_tradable_ids} = Enum.split_with(item_ids, &MapSet.member?(tradable_set, &1))
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
    t0 = mono_ms()

    items =
      Fast.Item
      |> where([i], i.tradable == true)
      |> where(
        [i],
        i.buy == 0 or
          i.sell == 0 or
          i.tp_quantity_total >= ^@hot_quantity_min or
          fragment("COALESCE(?, to_timestamp(0)) < now() - interval '60 minutes'", i.updated_at)
      )
      |> select([i], %{
        id: i.id,
        vendor_value: i.vendor_value,
        buy_old: i.buy,
        sell_old: i.sell,
        updated_at: i.updated_at
      })
      |> order_by([i],
        desc: i.tp_quantity_total,
        asc: fragment("COALESCE(?, to_timestamp(0))", i.updated_at),
        asc: i.id
      )
      |> limit(^@per_run_cap)
      |> Repo.all()

    ids = Enum.map(items, & &1.id)

    ensure_flags_cache!()
    flags_by_id = get_flags_for_ids(ids)

    pairs =
      items
      |> Enum.chunk_every(@step)
      |> Task.async_stream(
        fn chunk ->
          with_retry(fn ->
            ids = Enum.map(chunk, & &1.id)
            prices =
              ids
              |> fetch_json_ids(@prices)
              |> Enum.filter(&match?(%{"id" => _}, &1))

            prices_by_id = Map.new(prices, &{&1["id"], &1})

            for item <- chunk,
                price = Map.get(prices_by_id, item.id),
                not is_nil(price) do
              {item, Map.put(price, "flags", Map.get(flags_by_id, item.id, []))}
            end
          end)
        end,
        max_concurrency: @concurrency, timeout: 30_000, on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, xs} -> xs
        {:exit, reason} ->
          Logger.error("concurrent fetch failed (final): #{inspect(reason)}")
          []
      end)

    {price_rows, qty_rows, zeroed_bound_no_vendor, changed_ids} =
      Enum.reduce(pairs, {[], [], 0, MapSet.new()}, fn
        {%{id: id, vendor_value: vendor, buy_old: buy_old, sell_old: sell_old},
         %{"buys" => buys, "sells" => sells, "flags" => flags}},
        {price_rows, qty_rows, z, ids_acc} ->
          buy_qty = Map.fetch!(buys, "quantity")
          sell_qty = Map.fetch!(sells, "quantity")
          total_qty = buy_qty + sell_qty

          {buy, sell, z_inc} =
            if accountbound_only?(flags) do
              cond do
                is_nil(vendor) or vendor == 0 -> {0, 0, 1}
                true -> {vendor, 0, 0}
              end
            else
              buy0 = Map.get(buys, "unit_price")
              sell0 = Map.get(sells, "unit_price")
              {if(is_nil(buy0) or buy0 == 0, do: vendor || 0, else: buy0),
               if(is_nil(sell0), do: 0, else: sell0),
               0}
            end

          qty_row = %{id: id, tp_buys_quantity: buy_qty, tp_sells_quantity: sell_qty, tp_quantity_total: total_qty}

          if buy != buy_old or sell != sell_old do
            price_row = Map.merge(%{id: id, buy: buy, sell: sell}, qty_row)
            {[price_row | price_rows], qty_rows, z + z_inc, MapSet.put(ids_acc, id)}
          else
            {price_rows, [qty_row | qty_rows], z + z_inc, ids_acc}
          end

        _, acc ->
          acc
      end)

    now = now_ts()

    updated_prices =
      upsert_batches(price_rows, [:buy, :sell, :tp_buys_quantity, :tp_sells_quantity, :tp_quantity_total, :updated_at], now)

    _updated_quantities_only =
      upsert_batches(qty_rows, [:tp_buys_quantity, :tp_sells_quantity, :tp_quantity_total], nil)

    dt = mono_ms() - t0
    Logger.info("[job] gw2.sync_prices completed in #{fmt_ms(dt)} updated=#{updated_prices} zeroed_bound_no_vendor=#{zeroed_bound_no_vendor} picked=#{length(items)} cap=#{@per_run_cap}")

    {:ok, %{updated: updated_prices, changed_ids: changed_ids}}
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
    conn = GoogleApi.Sheets.V4.Connection.new(token.token)
    sheet_id = "1WdwWxyP9zeJhcxoQAr-paMX47IuK6l5rqAPYDOA8mho"

    cond do
      MapSet.size(changed_ids) == 0 ->
        dt = mono_ms() - t0
        Logger.info("[job] gw2.sync_sheet completed in #{fmt_ms(dt)} prices_updated=#{updated_prices} rows_written=0")
        :ok

      MapSet.size(changed_ids) > trunc(total_rows * 0.8) ->
        values = Enum.map(items, fn i -> [i.id, i.name, i.buy, i.sell, i.icon, i.rarity, i.vendor_value] end)
        {:ok, _} =
          GoogleApi.Sheets.V4.Api.Spreadsheets.sheets_spreadsheets_values_update(
            conn, sheet_id, "API!A4:G#{4 + total_rows}", body: %{values: values}, valueInputOption: "RAW"
          )
        dt = mono_ms() - t0
        Logger.info("[job] gw2.sync_sheet completed in #{fmt_ms(dt)} prices_updated=#{updated_prices} rows_written=#{total_rows}")
        :ok

      true ->
        idx = items |> Enum.with_index() |> Map.new(fn {%{id: id}, n} -> {id, n} end)

        data =
          items
          |> Stream.filter(fn i -> MapSet.member?(changed_ids, i.id) end)
          |> Stream.map(fn i ->
            row = Map.fetch!(idx, i.id) + 4
            %{range: "API!C#{row}:D#{row}", values: [[i.buy, i.sell]]}
          end)
          |> Enum.to_list()

        if data == [] do
          :ok
        else
          {:ok, _} =
            GoogleApi.Sheets.V4.Api.Spreadsheets.sheets_spreadsheets_values_batch_update(
              conn, sheet_id, body: %{data: data, valueInputOption: "RAW"}
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
      fn chunk ->
        with_retry(fn ->
          res = fetch_json_ids(base_url, chunk)
          if length(res) != length(chunk) do
            missing = chunk -- Enum.map(res, &Map.get(&1, "id"))
            Logger.error("Missing IDs for #{base_url}?ids=...: #{inspect(missing)}")
          end
          res
        end)
      end,
      max_concurrency: @concurrency, timeout: 30_000, on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, list} -> list
      {:exit, reason} ->
        Logger.error("items fetch failed (final): #{inspect(reason)}")
        []
    end)
    |> Enum.map(&Enum.into(&1, %{}, fn {k, v} -> {String.to_atom(k), v} end))
  end

  defp request_json(request, retry \\ 0) do
    case Finch.request(request, FastApi.Finch) do
      {:ok, %Finch.Response{status: status, body: body}} when status >= 500 ->
        Logger.error("HTTP #{status} from remote; body_snippet=#{inspect(String.slice(to_string(body), 0, 200))}")
        []
      {:ok, %Finch.Response{status: status, body: body}} ->
        case Jason.decode(body) do
          {:ok, list} when is_list(list) ->
            if status != 200, do: Logger.error("HTTP #{status} with list body from remote: #{inspect(Enum.take(list, 1))}")
            list
          {:ok, map} when is_map(map) ->
            if status != 200, do: Logger.error("HTTP #{status} with map body from remote: #{inspect(map)}")
            [map]
          {:ok, _} ->
            Logger.error("Unexpected JSON shape (status #{status})")
            []
          {:error, err} ->
            Logger.error("Failed to decode JSON (status #{status}): #{inspect(err)} body_snippet=#{inspect(String.slice(to_string(body), 0, 200))}")
            []
        end
      {:error, %Mint.TransportError{reason: :timeout}} when retry < 5 ->
        request_json(request, retry + 1)
      {:error, err} ->
        Logger.error("HTTP request error: #{inspect(err)}")
        []
    end
  end

  defp to_item(params, tradable \\ false) do
    params |> Map.put(:tradable, tradable) |> then(&struct(Fast.Item, &1))
  end

  defp accountbound_only?(flags) when is_list(flags), do: Enum.any?(flags, &(&1 == "AccountBound"))
  defp accountbound_only?(_), do: false

  defp to_insert_rows(items, now) do
    items
    |> Stream.map(&Map.from_struct/1)
    |> Stream.map(&Map.drop(&1, [:__meta__, :__struct__]))
    |> Stream.map(fn row -> row |> Map.put_new(:inserted_at, now) |> Map.put(:updated_at, now) end)
    |> Enum.to_list()
  end

  defp batch_upsert(rows) do
    rows
    |> Enum.chunk_every(5_000)
    |> Enum.each(fn batch ->
      Repo.insert_all(Fast.Item, batch, on_conflict: :replace_all, conflict_target: [:id])
    end)
  end

  defp upsert_batches(rows, replace_fields, now_or_nil) do
    rows
    |> Enum.chunk_every(5_000)
    |> Enum.reduce(0, fn batch, acc ->
      batch =
        case now_or_nil do
          nil -> batch
          now -> Enum.map(batch, &(&1 |> Map.put_new(:inserted_at, now) |> Map.put(:updated_at, now)))
        end

      {count, _} = Repo.insert_all(Fast.Item, batch, on_conflict: {:replace, replace_fields}, conflict_target: [:id])
      acc + count
    end)
  end

  defp get_flags_for_ids(ids) do
    now = mono_ms()
    ensure_flags_cache!()

    missing =
      Enum.reject(ids, fn id ->
        case :ets.lookup(@flags_cache_table, id) do
          [{^id, _flags, ts}] when now - ts < @flags_cache_ttl_ms -> true
          _ -> false
        end
      end)

    if missing != [] do
      fetched =
        missing
        |> get_details(@items)
        |> Enum.filter(&match?(%{id: _}, &1))
        |> Enum.map(fn %{id: id, flags: flags} -> {id, flags || []} end)

      Enum.each(fetched, fn {id, flags} -> :ets.insert(@flags_cache_table, {id, flags, now}) end)
    end

    Map.new(ids, fn id ->
      case :ets.lookup(@flags_cache_table, id) do
        [{^id, flags, _ts}] -> {id, flags}
        _ -> {id, []}
      end
    end)
  end
end
