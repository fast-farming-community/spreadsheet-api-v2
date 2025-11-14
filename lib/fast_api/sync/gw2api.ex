defmodule FastApi.Sync.GW2API do
  @moduledoc "Synchronize the spreadsheet using GW2 API data."
  import Ecto.Query, only: [where: 3, select: 3, order_by: 3, from: 2]

  alias FastApi.Repo
  alias FastApi.Schemas.Fast
  alias FastApi.Health.Gw2Server

  require Logger

  @items "https://api.guildwars2.com/v2/items"
  @prices "https://api.guildwars2.com/v2/commerce/prices"

  @step 200
  @concurrency 8

  # --- lightweight ETS rate limiter: 2 req/sec per bucket ---
  @rl_table :gw2_rl
  @rl_interval_ms 1_000
  @rl_qps 2

  # timeout log throttling (per-process)
  @timeout_warn_limit 2        # warn for first 2 timeouts, then debug
  @timeout_warn_cooldown_ms 5_000

  # --- MEMORY LOGGING HELPERS -----------------------------------
  defp mem_mb(bytes) when is_integer(bytes),
    do: Float.round(bytes / 1_048_576, 2)

  defp mem_mb(_), do: 0.0

  defp log_mem(tag) do
    m = :erlang.memory() |> Map.new()

    Logger.info(
      "[GW2Api][mem] #{tag} " <>
        "total=#{mem_mb(m[:total])} MB " <>
        "processes=#{mem_mb(m[:processes])} MB " <>
        "binary=#{mem_mb(m[:binary])} MB " <>
        "ets=#{mem_mb(m[:ets])} MB " <>
        "proc_count=#{:erlang.system_info(:process_count)}"
    )
  end

  # --- ETS TABLE INSPECTION -------------------------------------
  defp log_ets_tables(tag) do
    wordsize = :erlang.system_info(:wordsize)

    tables_info =
      :ets.all()
      |> Enum.map(fn tid ->
        try do
          info = :ets.info(tid)

          name = info[:name]
          size = info[:size] || 0
          mem_words = info[:memory] || 0
          mem_bytes = mem_words * wordsize
          owner = info[:owner]

          {name, mem_mb(mem_bytes), size, owner}
        rescue
          _ ->
            {tid, 0.0, 0, :unknown}
        end
      end)
      |> Enum.sort_by(fn {_name, mb, _size, _owner} -> -mb end)
      |> Enum.take(10)

    Logger.info("[GW2Api][mem][ets] #{tag} top=#{inspect(tables_info)}")
  end

  defp ensure_rl_table! do
    case :ets.info(@rl_table) do
      :undefined ->
        try do
          :ets.new(@rl_table, [:named_table, :set, :public, read_concurrency: true])
        catch
          :error, :badarg -> :ok
        end

      _ -> :ok
    end

    :ok
  end

  defp rl_now_ms, do: System.monotonic_time(:millisecond)

  defp rl_wait(bucket) do
    ensure_rl_table!()

    case :ets.lookup(@rl_table, bucket) do
      [{^bucket, last_ms, tokens}] ->
        now = rl_now_ms()
        elapsed = max(now - last_ms, 0)

        tokens_refilled =
          tokens +
            div(elapsed, @rl_interval_ms) * @rl_qps
          |> min(@rl_qps)

        if tokens_refilled >= 1 do
          :ets.insert(@rl_table, {bucket, now, tokens_refilled - 1})
          :ok
        else
          wait = max(@rl_interval_ms - rem(elapsed, @rl_interval_ms), 50)
          Process.sleep(wait)
          rl_wait(bucket)
        end

      _ ->
        :ets.insert(@rl_table, {bucket, rl_now_ms(), @rl_qps - 1})
        :ok
    end
  end

  # detect the maintenance splash so we can stop immediately on 503
  defp api_disabled?(body) when is_binary(body) do
    String.contains?(body, "API Temporarily disabled") or
      String.contains?(body, "Scheduled reactivation")
  end

  defp api_disabled?(_), do: false

  defp halt_if_disabled(:remote_disabled), do: throw(:gw2_disabled)
  defp halt_if_disabled(other), do: other

  defp fmt_ms(ms) do
    total = div(ms, 1000)
    mins = div(total, 60)
    secs = rem(total, 60)
    "#{mins}:#{String.pad_leading(Integer.to_string(secs), 2, "0")} mins"
  end

  defp now_ts(), do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  defp mono_ms(), do: System.monotonic_time(:millisecond)

  # --------- QUIET-SKIP WHEN PUBLIC HEALTH IS DOWN (5xx/maintenance) ----------
  @spec sync_items() :: :ok
  def sync_items do
    if Gw2Server.down?(:public) do
      :ok
    else
      try do
        log_mem("sync_items:start")

        item_ids = get_item_ids() |> halt_if_disabled()
        commerce_item_ids = get_commerce_item_ids() |> halt_if_disabled()

        # Quiet skip on upstream failure to avoid destructive delete
        if item_ids == [] or commerce_item_ids == [] do
          log_mem("sync_items:skip_upstream_empty")
          :ok
        else
          tradable_set = MapSet.new(commerce_item_ids)
          now = now_ts()

          all_rows =
            item_ids
            |> get_details(@items)
            |> Enum.filter(fn item ->
              case item["id"] || item[:id] do
                id when is_integer(id) -> true
                _ -> false
              end
            end)
            |> Enum.map(fn item ->
              id = item["id"] || item[:id]
              tradable? = MapSet.member?(tradable_set, id)
              to_item(item, tradable?)
            end)
            |> to_insert_rows(now)

          log_mem("sync_items:after_fetch_details")

          existing_ids =
            Fast.Item
            |> select([i], i.id)
            |> Repo.all()
            |> MapSet.new()

          new_ids = MapSet.new(item_ids)
          removed_ids = MapSet.difference(existing_ids, new_ids)

          if MapSet.size(removed_ids) > 0 do
            Repo.delete_all(from(i in Fast.Item, where: i.id in ^MapSet.to_list(removed_ids)))
            Logger.info("[GW2Api] Removed #{MapSet.size(removed_ids)} obsolete GW2 items")
          end

          batch_upsert(all_rows)

          Logger.info(
            "[GW2Api] Upserted #{length(all_rows)} GW2 items (#{MapSet.size(removed_ids)} removed)"
          )

          log_mem("sync_items:end")

          :ok
        end
      catch
        :gw2_disabled ->
          log_mem("sync_items:gw2_disabled")
          :ok
      end
    end
  end

  @spec sync_prices() :: {:ok, %{updated: non_neg_integer, changed_ids: MapSet.t()}}
  def sync_prices do
    if Gw2Server.down?(:public) do
      {:ok, %{updated: 0, changed_ids: MapSet.new()}}
    else
      try do
        log_mem("sync_prices:start")

        # IMPORTANT: we now always load tradable flag from DB
        items =
          Fast.Item
          |> select([i], %{
            id: i.id,
            vendor_value: i.vendor_value,
            buy_old: i.buy,
            sell_old: i.sell,
            tradable: i.tradable
          })
          |> Repo.all()

        Logger.info("[GW2Api] sync_prices loaded #{length(items)} items from DB")
        log_mem("sync_prices:after_load_items")

        pairs =
          items
          |> Enum.chunk_every(@step)
          |> Task.async_stream(&fetch_prices_for_chunk/1,
            max_concurrency: @concurrency,
            timeout: 30_000,
            on_timeout: :kill_task,
            ordered: false
          )
          |> Enum.flat_map(fn
            {:ok, pairs} -> pairs
            _ -> []
          end)

        Logger.info("[GW2Api] sync_prices got #{length(pairs)} item/price pairs")
        log_mem("sync_prices:after_fetch_prices")

        {rows_changed, {_zeroed_bound_no_vendor, changed_ids}} =
          pairs
          |> Enum.map_reduce({0, MapSet.new()}, fn
            # accountbound_only (tradable = false)
            {%{id: id, vendor_value: vendor, buy_old: buy_old, sell_old: sell_old, tradable: false},
             _price},
            {acc_zero, acc_ids} ->
              {buy, sell, zero_inc} =
                cond do
                  is_nil(vendor) or vendor == 0 -> {0, 0, 1}
                  true -> {vendor, 0, 0}
                end

              if buy != buy_old or sell != sell_old do
                row = %{id: id, buy: buy, sell: sell}
                {row, {acc_zero + zero_inc, MapSet.put(acc_ids, id)}}
              else
                {nil, {acc_zero + zero_inc, acc_ids}}
              end

            # tradable items with a valid price payload
            {%{id: id, vendor_value: vendor, buy_old: buy_old, sell_old: sell_old, tradable: true},
             %{"buys" => buys, "sells" => sells}},
            {acc_zero, acc_ids} ->
              buy0 = buys && Map.get(buys, "unit_price")
              sell0 = sells && Map.get(sells, "unit_price")

              buy_v = if is_nil(buy0) or buy0 == 0, do: vendor || 0, else: buy0
              sell_v = if is_nil(sell0), do: 0, else: sell0

              buy = buy_v
              sell = sell_v

              if buy != buy_old or sell != sell_old do
                row = %{id: id, buy: buy, sell: sell}
                {row, {acc_zero, MapSet.put(acc_ids, id)}}
              else
                {nil, {acc_zero, acc_ids}}
              end

            # any other case (e.g. tradable=true but no price received) – skip
            _other, acc ->
              {nil, acc}
          end)

        rows_changed = Enum.reject(rows_changed, &is_nil/1)

        Logger.info("[GW2Api] sync_prices rows_changed=#{length(rows_changed)}")
        log_mem("sync_prices:before_insert")

        now = now_ts()

        updated =
          rows_changed
          |> Enum.chunk_every(5_000)
          |> Enum.reduce(0, fn batch, acc ->
            batch_with_ts =
              Enum.map(batch, fn row ->
                row
                |> Map.put(:inserted_at, now)
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

        log_mem("sync_prices:end")

        {:ok, %{updated: updated, changed_ids: changed_ids}}
      catch
        :gw2_disabled ->
          log_mem("sync_prices:gw2_disabled")
          {:ok, %{updated: 0, changed_ids: MapSet.new()}}
      end
    end
  end

  # Sheets updater
  defp sheets_values_update_with_retry(connection, sheet_id, range, values, _attempts \\ 1, _backoff \\ 0) do
    case GoogleApi.Sheets.V4.Api.Spreadsheets.sheets_spreadsheets_values_update(
           connection,
           sheet_id,
           range,
           body: %{values: values},
           valueInputOption: "RAW"
         ) do
      {:ok, resp} -> {:ok, resp}
      {:error, %Tesla.Env{} = env} -> {:error, env}
      other -> other
    end
  end

  def sync_sheet do
    if Gw2Server.down?(:public) do
      :ok
    else
      try do
        log_mem("sync_sheet:start")
        log_ets_tables("sync_sheet:start")

        t0 = mono_ms()

        {:ok, %{updated: updated_prices}} = sync_prices()
        log_mem("sync_sheet:after_sync_prices")
        log_ets_tables("sync_sheet:after_sync_prices")

        items =
          Fast.Item
          |> select([i], %{
            id: i.id,
            name: i.name,
            buy: i.buy,
            sell: i.sell,
            icon: i.icon,
            rarity: i.rarity,
            vendor_value: i.vendor_value
          })
          |> order_by([i], asc: i.id)
          |> Repo.all()

        total_rows = length(items)
        Logger.info("[GW2Api] sync_sheet loaded #{total_rows} items for sheet update")
        log_mem("sync_sheet:after_load_items")
        log_ets_tables("sync_sheet:after_load_items")

        {:ok, token} = Goth.fetch(FastApi.Goth)
        connection = GoogleApi.Sheets.V4.Connection.new(token.token)
        sheet_id = "1WdwWxyP9zeJhcxoQAr-paMX47IuK6l5rqAPYDOA8mho"

        values =
          Enum.map(items, fn i ->
            [i.id, i.name, i.buy, i.sell, i.icon, i.rarity, i.vendor_value]
          end)

        range = "API!A4:G#{4 + total_rows}"

        case sheets_values_update_with_retry(connection, sheet_id, range, values) do
          {:ok, _response} ->
            dt = mono_ms() - t0

            Logger.info(
              "[GW2Api] gw2.sync_sheet completed in #{fmt_ms(dt)} " <>
                "prices_updated=#{updated_prices} rows_written=#{total_rows}"
            )

            log_mem("sync_sheet:end_ok")
            log_ets_tables("sync_sheet:end_ok")

            :erlang.garbage_collect(self())
            log_mem("sync_sheet:after_gc")
            log_ets_tables("sync_sheet:after_gc")

            :ok

          {:error, %Tesla.Env{status: 503}} ->
            Logger.info("[GW2Api] sync_sheet got 503 from Sheets; skipping update")
            log_mem("sync_sheet:503")
            log_ets_tables("sync_sheet:503")
            :ok

          {:error, %Tesla.Env{}} ->
            Logger.info("[GW2Api] sync_sheet Sheets error; skipping update")
            log_mem("sync_sheet:sheets_error")
            log_ets_tables("sync_sheet:sheets_error")
            :ok

          _other ->
            Logger.info("[GW2Api] sync_sheet unexpected response; skipping update")
            log_mem("sync_sheet:unexpected_resp")
            log_ets_tables("sync_sheet:unexpected_resp")
            :ok
        end
      catch
        :gw2_disabled ->
          log_mem("sync_sheet:gw2_disabled")
          log_ets_tables("sync_sheet:gw2_disabled")
          :ok
      end
    end
  end

  defp get_details(ids, base_url) do
    ids
    |> Enum.chunk_every(@step)
    |> Task.async_stream(
      fn chunk -> get_details_chunk(chunk, base_url) end,
      max_concurrency: @concurrency,
      timeout: 30_000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, list} -> list
      _ -> []
    end)
  end

  defp get_item_ids do
    rl_wait("gw2:items")

    case Finch.build(:get, @items) |> request_json() do
      :remote_disabled -> :remote_disabled
      :error -> []
      other -> other
    end
  end

  defp get_commerce_item_ids do
    rl_wait("gw2:prices")

    case Finch.build(:get, @prices) |> request_json() do
      :remote_disabled -> :remote_disabled
      :error -> []
      other -> other
    end
  end

  # Reconstruct a readable URL from Finch.Request for logging
  defp req_url_string(%Finch.Request{} = r) do
    scheme = to_string(r.scheme || "https")
    host = r.host || "?"
    path = r.path || "/"
    query = if is_binary(r.query) and r.query != "", do: "?" <> r.query, else: ""

    port_suffix =
      case {scheme, r.port} do
        {"http", 80} -> ""
        {"https", 443} -> ""
        {_, p} when is_integer(p) -> ":" <> Integer.to_string(p)
        _ -> ""
      end

    scheme <> "://" <> host <> port_suffix <> path <> query
  end

  # ------------- QUIET, THROTTLED TIMEOUT LOGGING ----------------
  defp log_timeout(request) do
    # If health says public is down, always debug
    if Gw2Server.down?(:public) do
      Logger.debug("[GW2Api] timeout #{req_url_string(request)}")
    else
      count = (Process.get(:gw2_timeout_count, 0) + 1)
      last_warn_at = Process.get(:gw2_timeout_last_warn_at, 0)
      now = mono_ms()

      cond do
        count <= @timeout_warn_limit and now - last_warn_at >= @timeout_warn_cooldown_ms ->
          Logger.warning("[GW2Api] timeout")
          Process.put(:gw2_timeout_last_warn_at, now)

        count <= @timeout_warn_limit ->
          # within cooldown window, keep it quiet
          Logger.debug("[GW2Api] timeout (suppressed) #{req_url_string(request)}")

        true ->
          Logger.debug("[GW2Api] timeout #{req_url_string(request)}")
      end

      Process.put(:gw2_timeout_count, count)
    end
  end

  # --- JSON REQUEST (no retry) ---
  defp request_json(request) do
    case Finch.request(request, FastApi.FinchJobs) do
      {:ok, %Finch.Response{status: 503, body: body}} ->
        if api_disabled?(body), do: :remote_disabled, else: :error

      {:ok, %Finch.Response{status: status}} when status >= 500 ->
        :error

      {:ok, %Finch.Response{status: _status, body: body}} ->
        case Jason.decode(body) do
          {:ok, decoded} when is_list(decoded) -> decoded
          {:ok, decoded} when is_map(decoded) -> [decoded]
          _ -> :error
        end

      {:error, %Mint.TransportError{reason: :timeout}} ->
        log_timeout(request)
        :error

      {:error, reason} ->
        Logger.debug("[GW2Api] request failed #{req_url_string(request)}: #{inspect(reason)}")
        :error
    end
  end

  defp to_item(params, tradable) when is_map(params) do
    attrs =
      params
      |> Enum.reduce(%{}, fn
        {k, v}, acc when is_binary(k) ->
          case safe_to_existing_atom(k) do
            nil -> acc
            atom_key -> Map.put(acc, atom_key, v)
          end

        {k, v}, acc when is_atom(k) ->
          Map.put(acc, k, v)

        _other, acc ->
          acc
      end)
      |> Map.put(:tradable, tradable)

    struct(Fast.Item, attrs)
  end

  defp safe_to_existing_atom(k) when is_binary(k) do
    try do
      String.to_existing_atom(k)
    rescue
      ArgumentError -> nil
    end
  end

  defp safe_to_existing_atom(_), do: nil

  defp to_insert_rows(items, now) do
    items
    |> Stream.map(&Map.from_struct/1)
    |> Stream.map(&Map.drop(&1, [:__meta__, :__struct__]))
    |> Stream.map(fn row ->
      row |> Map.put(:inserted_at, now) |> Map.put(:updated_at, now)
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
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: [:id]
      )
    end)
  end

  # --- fetch for a chunk of prices ---
  defp fetch_prices_for_chunk(chunk) do
    :timer.sleep(:rand.uniform(400)) # one-time jitter to de-sync workers

    ids = Enum.map(chunk, & &1.id)

    req_prices = "#{@prices}?ids=#{Enum.map_join(ids, ",", & &1)}"

    rl_wait("gw2:prices")

    prices =
      case Finch.build(:get, req_prices) |> request_json() do
        :remote_disabled -> throw(:gw2_disabled)
        :error -> []
        other -> other
      end

    prices_by_id =
      prices
      |> Enum.reduce(%{}, fn
        %{"id" => id} = m, acc -> Map.put(acc, id, m)
        _other, acc -> acc
      end)

    # we now always return a pair for every item in the chunk
    Enum.map(chunk, fn item ->
      {item, Map.get(prices_by_id, item.id)}
    end)
  end

  # --- items/prices details for a chunk (no retry) ---
  defp get_details_chunk(chunk, base_url) do
    :timer.sleep(:rand.uniform(400))
    req_url = "#{base_url}?ids=#{Enum.join(chunk, ",")}"

    if String.contains?(base_url, "/v2/commerce/prices"),
      do: rl_wait("gw2:prices"),
      else: rl_wait("gw2:items")

    result =
      Finch.build(:get, req_url)
      |> request_json()

    cond do
      result == :remote_disabled -> throw(:gw2_disabled)
      result in [:error, []] -> []
      true -> result
    end
  end
end
