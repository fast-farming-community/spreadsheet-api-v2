defmodule FastApi.Sync.Features do
  @moduledoc "Synchronize the database using spreadsheet data (tiered)."

  alias FastApi.Repo
  alias FastApi.Schemas.Fast
  alias GoogleApi.Sheets.V4.Model.ValueRange

  require Logger

  @spreadsheet_id "1WdwWxyP9zeJhcxoQAr-paMX47IuK6l5rqAPYDOA8mho"
  @batch_size 80

  # retry/timeouts
  @max_retries 3               # task timeout/retry
  @backoff_attempts 5          # 429 backoff attempts
  @backoff_base_ms 400         # ~0.4s, then exponential

  # cycle persistence (once per 5m run)
  @cycle_meta_key "features_cycle"
  @cycle_field "run_counter"

  @type tier :: :free | :copper | :silver | :gold

  @doc """
  Run every 5 minutes via Quantum.

  Tiers per run (n = 1-based counter persisted in `metadata`):
    - every run: gold
    - every 2nd: + silver
    - every 4th: + copper
    - every 12th: + free
  """
  def execute_cycle() do
    n = next_cycle_number()

    tiers =
      [:gold]
      |> then(fn acc -> if rem(n, 2)  == 0, do: [:silver | acc], else: acc end)
      |> then(fn acc -> if rem(n, 4)  == 0, do: [:copper | acc], else: acc end)
      |> then(fn acc -> if rem(n, 12) == 0, do: [:free   | acc], else: acc end)
      |> Enum.reverse() # gold, silver, copper, free in that order

    for tier <- tiers do
      execute(Fast.Table, tier)
      Process.sleep(800)
      execute(Fast.DetailTable, tier)
      Process.sleep(800)
    end

    :ok
  end

  @doc """
  Execute a single tier sync for a given schema (Fast.Table or Fast.DetailTable).
  """
  def execute(repo, tier \\ :free) do
    repo_tag = metadata_name(repo)
    t0 = System.monotonic_time(:millisecond)

    try do
      updated = retry_execute(repo, tier, 1)
      dt = System.monotonic_time(:millisecond) - t0
      total = Repo.aggregate(repo, :count, :id)
      Logger.info("[features] tier=#{tier_label(tier)} repo=#{repo_tag} updated=#{updated}/#{total} in #{fmt_ms(dt)}")
    rescue
      e ->
        Logger.error("[features] tier=#{tier_label(tier)} repo=#{repo_tag} failed: #{Exception.message(e)}")
        reraise e, __STACKTRACE__
    end
  end

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

  defp retry_execute(repo, tier, attempt) when attempt <= @max_retries do
    try do
      do_execute(repo, tier)
    rescue
      e in RuntimeError ->
        reraise e, __STACKTRACE__
    catch
      :exit, {:timeout, _} ->
        Logger.warning("GSheets fetch timeout (#{attempt}/#{@max_retries}); retrying…")
        Process.sleep(:timer.seconds(attempt * 2))
        retry_execute(repo, tier, attempt + 1)

      :exit, _reason ->
        :erlang.raise(:exit, :error, __STACKTRACE__)
    end
  end

  defp retry_execute(repo, tier, _attempt) do
    Logger.error("GSheets fetch timeout after #{@max_retries} attempts; giving up.")
    do_execute(repo, tier)
  end

  defp do_execute(repo, tier) do
    list = Repo.all(repo)
    len  = length(list)

    chunks = list |> Enum.chunk_every(@batch_size) |> Enum.with_index()
    total  = length(chunks)

    {:ok, token} = Goth.fetch(FastApi.Goth)

    triples =
      chunks
      |> Task.async_stream(
        fn chunk -> get_spreadsheet_tables(chunk, total, len, token.token, tier) end,
        max_concurrency: concurrency(),
        timeout: 120_000,
        ordered: false,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, res} -> res
        {:exit, reason} ->
          Logger.error("Spreadsheet chunk failed (task exit): #{inspect(reason)}")
          []
      end)

    updated_count =
      triples
      |> Enum.reduce(0, fn {table, field, json}, acc ->
        current = Map.get(table, field)
        if current != json do
          cs = repo.changeset(table, %{field => json})
          case Repo.update(cs) do
            {:ok, _}    -> acc + 1
            {:error, _} -> acc
          end
        else
          acc
        end
      end)

    update_metadata!(repo, tier)
    updated_count
  end

  defp get_spreadsheet_tables({tables, idx}, total, _total_ranges, bearer_token, tier) do
    connection = GoogleApi.Sheets.V4.Connection.new(bearer_token)
    pid_label  = inspect(self())
    Process.sleep(200)

    ranges = Enum.map(tables, & &1.range)

    result = fetch_batch_with_backoff(connection, ranges, idx + 1, total, pid_label)

    result
    |> process_response(tables, tier)
  end

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

      {:error, %Tesla.Env{status: 429} = env} ->
        wait = trunc(:math.pow(2, attempt - 1) * @backoff_base_ms)
        Logger.warning(
          "Chunk #{idx}/#{total} pid=#{pid_label} 429 RATE_LIMIT_EXCEEDED; backing off #{wait}ms (#{attempt}/#{@backoff_attempts})"
        )

        Process.sleep(wait)
        fetch_batch_with_backoff(connection, ranges, idx, total, pid_label, attempt + 1)

      {:error, other} ->
        Logger.error("Chunk #{idx}/#{total} pid=#{pid_label} API error: #{inspect(other)}")
        {:error, other}
    end
  end

  defp fetch_batch_with_backoff(_connection, _ranges, idx, total, pid_label, _attempt) do
    Logger.error("Chunk #{idx}/#{total} pid=#{pid_label} 429 backoff exhausted")
    {:error, :rate_limited}
  end

  defp metadata_name(Fast.Table),       do: "main"
  defp metadata_name(Fast.DetailTable), do: "detail"

  defp process_response({:ok, response}, tables, tier) do
    value_ranges = response.valueRanges || []
    field = target_field(tier)

    tables
    |> Enum.zip(value_ranges)
    |> Enum.map(fn
      {%_{} = table, %ValueRange{values: [headers | rows]}} when is_list(headers) ->
        headers_clean =
          headers
          |> Enum.map(&(to_string(&1) |> String.replace(~r/[\W_]+/, "")))

        json =
          rows
          |> Enum.map(fn row -> headers_clean |> Enum.zip(row) |> Enum.into(%{}) end)
          |> Jason.encode!()

        {table, field, json}

      {table, %ValueRange{values: []}} ->
        log_and_raise(table, "empty values (no header row)", %{values: []})

      {table, %ValueRange{values: nil}} ->
        log_and_raise(table, "nil values (no data returned by API)", %{})

      {table, %ValueRange{values: other}} ->
        log_and_raise(table, "unexpected values shape", %{values: other})

      {table, nil} ->
        log_and_raise(table, "missing ValueRange for table (no response for this range)", %{})
    end)
  end

  defp process_response({:error, %{body: error}}, _tables, _tier) do
    Logger.error("Error while fetching spreadsheet data: #{inspect(error)}")
    []
  end

  defp update_metadata!(repo, tier) do
    updated_at =
      DateTime.utc_now()
      |> DateTime.truncate(:millisecond)
      |> DateTime.to_iso8601()

    name = metadata_name(repo)
    tier_key = tier_label(tier)

    new_data =
      case Repo.get_by(Fast.Metadata, name: name) do
        nil -> %{"updated_at" => %{}}
        %Fast.Metadata{data: nil} -> %{"updated_at" => %{}}
        %Fast.Metadata{data: json} ->
          case Jason.decode(json) do
            {:ok, m} -> m
            _ -> %{"updated_at" => %{}}
          end
      end
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
            Logger.error("metadata(#{name}) insert failed: #{inspect(changeset.errors)}")
        end

      %Fast.Metadata{} = row ->
        row
        |> Fast.Metadata.changeset(%{data: new_data})
        |> Repo.update()
        |> case do
          {:ok, _} -> :ok
          {:error, changeset} ->
            Logger.error("metadata(#{name}) update failed: #{inspect(changeset.errors)}")
        end
    end
  end

  defp log_and_raise(table, reason, context) do
    label = table_label(table)
    Logger.error(
      "Spreadsheet sync failed: #{reason} table=#{label} context=#{inspect(context, pretty: true, limit: :infinity, printable_limit: :infinity)}"
    )

    raise RuntimeError, "Spreadsheet sync failed: #{reason} (#{label})"
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

  defp next_cycle_number() do
    Repo.transaction(fn ->
      case Repo.get_by(Fast.Metadata, name: @cycle_meta_key) do
        nil ->
          data = %{@cycle_field => 1} |> Jason.encode!()
          %Fast.Metadata{name: @cycle_meta_key}
          |> Fast.Metadata.changeset(%{data: data})
          |> Repo.insert!()
          1

        %Fast.Metadata{} = row ->
          current =
            case row.data && Jason.decode(row.data) do
              {:ok, %{@cycle_field => n}} when is_integer(n) -> n
              _ -> 0
            end

          next = current + 1
          new_data = %{@cycle_field => next} |> Jason.encode!()

          row
          |> Fast.Metadata.changeset(%{data: new_data})
          |> Repo.update!()

          next
      end
    end)
  end
end
