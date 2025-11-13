defmodule FastApi.Sync.GoogleSheetsUpdater do
  @moduledoc "Synchronize the database using spreadsheet data (tiered)."

  alias FastApi.Repo
  alias FastApi.Schemas.Fast
  alias GoogleApi.Sheets.V4.Model.ValueRange

  import Ecto.Query
  require Logger

  @spreadsheet_id "1WdwWxyP9zeJhcxoQAr-paMX47IuK6l5rqAPYDOA8mho"
  @batch_size 80

  @max_retries 3
  @backoff_attempts 5
  @backoff_base_ms 400

  @type tier :: :free | :copper | :silver | :gold

  # ----------------------------- PUBLIC API -----------------------------

  def execute_cycle() do
    now = DateTime.utc_now()
    minute = now.minute

    tiers =
      [:gold]
      |> then(fn acc -> if rem(minute, 10) == 0, do: [:silver | acc], else: acc end)
      |> then(fn acc -> if rem(minute, 20) == 0, do: [:copper | acc], else: acc end)
      |> then(fn acc -> if minute == 0,          do: [:free   | acc], else: acc end)
      |> Enum.reverse()

    for tier <- tiers do
      execute(Fast.Table, tier)
      Process.sleep(800)
      execute(Fast.DetailTable, tier)
      Process.sleep(800)
    end

    :ok
  end

  def execute(repo, tier \\ :free) do
    repo_tag = metadata_name(repo)
    t0 = System.monotonic_time(:millisecond)

    updated =
      try do
        retry_execute(repo, tier, 1)
      rescue
        e ->
          Logger.error(
            "[GoogleSheetsUpdater] tier=#{tier_label(tier)} repo=#{repo_tag} failed with exception: #{inspect(e)}"
          )

          0
      catch
        kind, reason ->
          Logger.error(
            "[GoogleSheetsUpdater] tier=#{tier_label(tier)} repo=#{repo_tag} failed with #{inspect(kind)}: #{inspect(reason)}"
          )

          0
      end

    dt = System.monotonic_time(:millisecond) - t0
    total = Repo.aggregate(repo, :count, :id)

    Logger.info(
      "[GoogleSheetsUpdater] tier=#{tier_label(tier)} repo=#{repo_tag} updated=#{updated}/#{total} in #{fmt_ms(dt)}"
    )

    updated
  end

  # ----------------------------- CONFIG HELPERS -----------------------------

  defp target_field(:gold),   do: :rows_gold
  defp target_field(:silver), do: :rows_silver
  defp target_field(:copper), do: :rows_copper
  defp target_field(:free),   do: :rows

  defp tier_label(:gold),   do: "gold"
  defp tier_label(:silver), do: "silver"
  defp tier_label(:copper), do: "copper"
  defp tier_label(:free),   do: "free"

  defp fmt_ms(ms) do
    total = div(ms, 1000)
    mins = div(total, 60)
    secs = rem(total, 60)
    "#{mins}:#{String.pad_leading(Integer.to_string(secs), 2, "0")} mins"
  end

  defp concurrency() do
    case System.get_env("GSHEETS_CONCURRENCY") do
      nil -> 3
      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, _} when n >= 1 and n <= 10 -> n
          _ -> 3
        end
    end
  end

  # ----------------------------- RETRY WRAPPER -----------------------------

  defp retry_execute(repo, tier, attempt) when attempt <= @max_retries do
    try do
      do_execute(repo, tier)
    rescue
      e ->
        Logger.error(
          "[GoogleSheetsUpdater] unexpected exception on attempt #{attempt}: #{inspect(e)}"
        )

        0
    catch
      :exit, {:timeout, _} ->
        Logger.warning(
          "[GoogleSheetsUpdater] fetch timeout (#{attempt}/#{@max_retries}); retrying…"
        )

        Process.sleep(:timer.seconds(attempt * 2))
        retry_execute(repo, tier, attempt + 1)

      :exit, reason ->
        Logger.error(
          "[GoogleSheetsUpdater] unexpected exit on attempt #{attempt}: #{inspect(reason)}"
        )

        0
    end
  end

  defp retry_execute(_repo, _tier, _attempt) do
    Logger.error(
      "[GoogleSheetsUpdater] fetch timeout after #{@max_retries} attempts; giving up for this cycle."
    )

    0
  end

  # ----------------------------- CORE EXECUTION -----------------------------

  defp do_execute(repo, tier) do
    field = target_field(tier)

    base_query =
      from t in repo,
        select: %{
          id: t.id,
          range: t.range,
          name: t.name,
          current: field(t, ^field)
        }

    rows = Repo.all(base_query)
    _len = length(rows)

    # Keep memory bounded: chunk, fetch, compare, write, drop.
    chunks = rows |> Enum.chunk_every(@batch_size) |> Enum.with_index()
    total  = length(chunks)

    {:ok, token} = Goth.fetch(FastApi.Goth)

    updated_total =
      chunks
      |> Task.async_stream(
        fn {tables, idx} ->
          process_chunk(repo, field, tables, idx, total, token.token, tier)
        end,
        max_concurrency: concurrency(),
        timeout: 120_000,
        ordered: false,
        on_timeout: :kill_task
      )
      |> Enum.reduce(0, fn
        {:ok, n}, acc when is_integer(n) ->
          acc + n

        {:ok, other}, acc ->
          Logger.error(
            "[GoogleSheetsUpdater] Unexpected task result payload: #{inspect(other)}"
          )

          acc

        {:exit, reason}, acc ->
          Logger.error(
            "[GoogleSheetsUpdater] Spreadsheet chunk failed (task exit): #{inspect(reason)}"
          )

          acc

        other, acc ->
          Logger.error(
            "[GoogleSheetsUpdater] Unexpected task result tuple: #{inspect(other)}"
          )

          acc
      end)

    update_metadata!(repo, tier)
    updated_total
  end

  defp process_chunk(repo, field, tables, idx, total, bearer_token, tier) do
    connection = GoogleApi.Sheets.V4.Connection.new(bearer_token)
    pid_label  = inspect(self())
    Process.sleep(200)

    ranges = Enum.map(tables, & &1.range)

    case fetch_batch_with_backoff(connection, ranges, idx + 1, total, pid_label) do
      {:ok, response} ->
        to_update = tables_vs_values_to_updates(response, tables, tier)
        n = write_updates(repo, field, to_update)
        # aggressively drop references held by this task
        :erlang.garbage_collect(self())
        n

      {:error, {:invalid_ranges, bad_ranges}} ->
        _ = bad_ranges
        0

      {:error, {:gsheets_error, status}} ->
        Logger.error(
          "[GoogleSheetsUpdater] Sheets error (status=#{inspect(status)}); skipping this chunk for this cycle."
        )

        0

      {:error, :rate_limited} ->
        Logger.warning(
          "[GoogleSheetsUpdater] Rate limit/backoff exhausted for a chunk; skipping this chunk this cycle."
        )

        0
    end
  end

  # Build updates *only for changed rows* to keep memory and writes small.
  # Input `tables` are maps: %{id, range, name, current}
  # Returns list of {id, json_string}
  defp tables_vs_values_to_updates(%{valueRanges: value_ranges} = _resp, tables, tier) do
    _field = target_field(tier) # intent marker; not used directly

    tables
    |> Enum.zip(value_ranges || [])
    |> Enum.reduce([], fn
      {%{id: id, name: _name, range: _range, current: current_json},
       %ValueRange{values: [headers | rows]}}, acc when is_list(headers) ->
        headers_clean =
          headers
          |> Enum.map(&(to_string(&1) |> String.replace(~r/[\W_]+/, "")))

        # Encode to binary immediately so we can compare strictly and GC iodata sooner
        new_json =
          rows
          |> Enum.map(fn row ->
            headers_clean |> Enum.zip(row) |> Enum.into(%{})
          end)
          |> Jason.encode!()

        if current_json != new_json do
          [{id, new_json} | acc]
        else
          acc
        end

      {%{id: _id} = table, %ValueRange{values: []}}, acc ->
        log_table_error(table, "empty values (no header row)", %{values: []})
        acc

      {%{id: _id} = table, %ValueRange{values: nil}}, acc ->
        log_table_error(table, "nil values (no data returned by API)", %{})
        acc

      {%{id: _id} = table, %ValueRange{values: other}}, acc ->
        log_table_error(table, "unexpected values shape", %{values: other})
        acc

      {%{id: _id} = table, nil}, acc ->
        log_table_error(table, "missing ValueRange for table (no response for this range)", %{})
        acc
    end)
    |> Enum.reverse()
  end

  # ----------------------------- SHEETS CALLS -----------------------------

  defp fetch_batch_with_backoff(connection, ranges, idx, total, pid_label, attempt \\ 1)
  defp fetch_batch_with_backoff(connection, ranges, idx, total, pid_label, attempt)
       when attempt <= @backoff_attempts do
    case GoogleApi.Sheets.V4.Api.Spreadsheets.sheets_spreadsheets_values_batch_get(
           connection,
           @spreadsheet_id,
           ranges: ranges,
           valueRenderOption: "UNFORMATTED_VALUE",
           dateTimeRenderOption: "FORMATTED_STRING"
         ) do
      {:ok, resp} ->
        {:ok, resp}

      # 400 -> bad ranges. Do NOT log body; isolate and log minimal names.
      {:error, %Tesla.Env{status: 400}} ->
        bad = isolate_invalid_ranges(connection, ranges)

        case bad do
          [] ->
            Logger.error(
              "[GoogleSheetsUpdater] Sheets 400 BAD_REQUEST; could not isolate invalid ranges (chunk #{idx}/#{total})"
            )

            {:error, {:gsheets_error, :bad_request}}

          bad_ranges ->
            Logger.error(
              "[GoogleSheetsUpdater] Missing/invalid named ranges (#{length(bad_ranges)}): #{inspect(bad_ranges)}"
            )

            {:error, {:invalid_ranges, bad_ranges}}
        end

      {:error, %Tesla.Env{status: 429}} ->
        wait = trunc(:math.pow(2, attempt - 1) * @backoff_base_ms)

        Logger.warning(
          "[GoogleSheetsUpdater] Chunk #{idx}/#{total} pid=#{pid_label} 429 RATE_LIMIT; backoff #{wait}ms (#{attempt}/#{@backoff_attempts})"
        )

        Process.sleep(wait)
        fetch_batch_with_backoff(connection, ranges, idx, total, pid_label, attempt + 1)

      {:error, %Tesla.Env{status: status}} when status in 500..599 ->
        wait = trunc(:math.pow(2, attempt - 1) * @backoff_base_ms)

        Logger.warning(
          "[GoogleSheetsUpdater] Chunk #{idx}/#{total} pid=#{pid_label} #{status} SERVER_ERROR; backoff #{wait}ms (#{attempt}/#{@backoff_attempts})"
        )

        Process.sleep(wait)
        fetch_batch_with_backoff(connection, ranges, idx, total, pid_label, attempt + 1)

      {:error, %Tesla.Env{} = env} ->
        Logger.error(
          "[GoogleSheetsUpdater] API error status=#{env.status} on chunk #{idx}/#{total} pid=#{pid_label}"
        )

        {:error, {:gsheets_error, env.status}}

      {:error, other} ->
        Logger.error(
          "[GoogleSheetsUpdater] API error on chunk #{idx}/#{total} pid=#{pid_label}: #{inspect(other)}"
        )

        {:error, {:gsheets_error, :unknown}}
    end
  end

  defp fetch_batch_with_backoff(_connection, _ranges, idx, total, pid_label, _attempt) do
    Logger.error(
      "[GoogleSheetsUpdater] Chunk #{idx}/#{total} pid=#{pid_label} backoff exhausted; treating as rate limited"
    )

    {:error, :rate_limited}
  end

  defp call_batch(connection, ranges) do
    GoogleApi.Sheets.V4.Api.Spreadsheets.sheets_spreadsheets_values_batch_get(
      connection,
      @spreadsheet_id,
      ranges: ranges,
      valueRenderOption: "UNFORMATTED_VALUE",
      dateTimeRenderOption: "FORMATTED_STRING"
    )
  end

  defp isolate_invalid_ranges(_connection, []), do: []

  defp isolate_invalid_ranges(connection, [single]) do
    case call_batch(connection, [single]) do
      {:ok, _} -> []
      {:error, %Tesla.Env{status: 400}} -> [single]
      {:error, _} -> [single] # conservative — prefer surfacing the suspect
    end
  end

  defp isolate_invalid_ranges(connection, ranges) do
    case call_batch(connection, ranges) do
      {:ok, _} ->
        []

      {:error, %Tesla.Env{status: 400}} ->
        {left, right} = Enum.split(ranges, div(length(ranges) + 1, 2))
        isolate_invalid_ranges(connection, left) ++ isolate_invalid_ranges(connection, right)

      {:error, _} ->
        ranges
    end
  end

  # ----------------------------- DB WRITES -----------------------------

  defp write_updates(_repo, _field, []), do: 0

  defp write_updates(repo, field, pairs) when is_list(pairs) do
    Enum.reduce(pairs, 0, fn {id, json}, acc ->
      # Direct update without loading the struct; 1 row per call with small payload.
      {count, _} =
        from(r in repo, where: r.id == ^id)
        |> Repo.update_all(set: [{field, json}])

      acc + count
    end)
  end

  defp update_metadata!(repo, tier) do
    updated_at =
      DateTime.utc_now()
      |> DateTime.truncate(:millisecond)
      |> DateTime.to_iso8601()

    name = metadata_name(repo)
    tier_key = tier_label(tier)

    base_map =
      case Repo.get_by(Fast.Metadata, name: name) do
        nil -> %{}
        %Fast.Metadata{data: nil} -> %{}
        %Fast.Metadata{data: json} ->
          case Jason.decode(json) do
            {:ok, %{} = m} -> m
            _ -> %{}
          end
      end

    data_map =
      Map.update(base_map, "updated_at", %{}, fn v ->
        if is_map(v), do: v, else: %{}
      end)

    new_data =
      data_map
      |> put_in(["updated_at", tier_key], updated_at)
      |> Jason.encode!()

    case Repo.get_by(Fast.Metadata, name: name) do
      nil ->
        %Fast.Metadata{name: name}
        |> Fast.Metadata.changeset(%{data: new_data})
        |> Repo.insert()
        |> case do
          {:ok, _} -> :ok
          {:error, changeset} ->
            Logger.error(
              "[GoogleSheetsUpdater] metadata(#{name}) insert failed: #{inspect(changeset.errors)}"
            )
        end

      %Fast.Metadata{} = row ->
        row
        |> Fast.Metadata.changeset(%{data: new_data})
        |> Repo.update()
        |> case do
          {:ok, _} -> :ok
          {:error, changeset} ->
            Logger.error(
              "[GoogleSheetsUpdater] metadata(#{name}) update failed: #{inspect(changeset.errors)}"
            )
        end
    end
  end

  # ----------------------------- LOGGING HELPERS -----------------------------

  defp metadata_name(Fast.Table),       do: "main"
  defp metadata_name(Fast.DetailTable), do: "detail"

  defp log_table_error(table_like, reason, context) do
    label = table_label(table_like)

    Logger.error(
      "[GoogleSheetsUpdater] failed: #{reason} table=#{label} context=#{inspect(context, pretty: true, limit: :infinity, printable_limit: :infinity)}"
    )
  end

  # Accepts either a schema struct or our slim map
  defp table_label(%{range: range, name: name, id: id}) do
    parts =
      []
      |> then(fn acc -> if name,  do: ["name=#{name}"  | acc], else: acc end)
      |> then(fn acc -> if id,    do: ["id=#{id}"      | acc], else: acc end)
      |> then(fn acc -> if range, do: ["range=#{range}"| acc], else: acc end)
      |> Enum.reverse()

    if parts == [], do: inspect(%{id: id, name: name, range: range}), else: Enum.join(parts, " ")
  end

  defp table_label(table) do
    range = Map.get(table, :range)
    name  = Map.get(table, :name)
    id    = Map.get(table, :id)

    parts =
      []
      |> then(fn acc -> if name,  do: ["name=#{name}"  | acc], else: acc end)
      |> then(fn acc -> if id,    do: ["id=#{id}"      | acc], else: acc end)
      |> then(fn acc -> if range, do: ["range=#{range}"| acc], else: acc end)
      |> Enum.reverse()

    if parts == [], do: inspect(table), else: Enum.join(parts, " ")
  end
end
