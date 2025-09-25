defmodule FastApi.Sync.Features do
  @moduledoc "Synchronize the database using spreadsheet data."

  alias FastApi.Repo
  alias FastApi.Schemas.Fast
  alias GoogleApi.Sheets.V4.Model.ValueRange

  require Logger

  @spreadsheet_id "1WdwWxyP9zeJhcxoQAr-paMX47IuK6l5rqAPYDOA8mho"
  @batch_size 80
  @max_retries 3

  defp concurrency() do
    case System.get_env("GSHEETS_CONCURRENCY") do
      nil -> 5
      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, _} when n >= 1 and n <= 10 -> n
          _ -> 5
        end
    end
  end

  # public entrypoint with retry wrapper
  def execute(repo) do
    repo_tag = metadata_name(repo)
    t0 = System.monotonic_time(:millisecond)
    Logger.info("[job] features.execute(#{repo_tag}) — started")

    try do
      retry_execute(repo, 1)
    after
      dt = System.monotonic_time(:millisecond) - t0
      Logger.info("[job] features.execute(#{repo_tag}) — completed in #{dt}ms")
    end
  end

  defp retry_execute(repo, attempt) when attempt <= @max_retries do
    try do
      do_execute(repo)
    rescue
      e in RuntimeError ->
        # business errors bubble as before
        reraise e, __STACKTRACE__
    catch
      :exit, {:timeout, _} ->
        Logger.warning("GSheets fetch timeout (#{attempt}/#{@max_retries}); retrying…")
        Process.sleep(:timer.seconds(attempt * 2))
        retry_execute(repo, attempt + 1)

      :exit, _reason ->
        # propagate other exits
        :erlang.raise(:exit, :error, __STACKTRACE__)
    end
  end

  defp retry_execute(repo, _attempt) do
    Logger.error("GSheets fetch timeout after #{@max_retries} attempts; giving up.")
    do_execute(repo)
  end

  # --- actual work unchanged below ---
  defp do_execute(repo) do
    list = Repo.all(repo)
    len  = length(list)

    Logger.info("Started fetching #{len} tables from Google Sheets API.")

    chunks = list |> Enum.chunk_every(@batch_size) |> Enum.with_index()
    total  = length(chunks)

    Logger.info("GSheets fetch: batch_size=#{@batch_size}, concurrency=#{concurrency()}, chunks=#{total}, total_ranges=#{len}")

    {:ok, token} = Goth.fetch(FastApi.Goth)

    results =
      chunks
      |> Task.async_stream(
        fn chunk -> get_spreadsheet_tables(chunk, total, len, token.token) end,
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

    results
    |> Enum.map(fn {table, changes} -> repo.changeset(table, changes) end)
    |> Enum.each(&Repo.update/1)

    json_data = Jason.encode!(%{updated_at: DateTime.utc_now() |> DateTime.to_iso8601()})

    Fast.Metadata
    |> Repo.get_by(name: metadata_name(repo))
    |> Fast.Metadata.changeset(%{data: json_data})
    |> Repo.update()

    Logger.info("Finished fetching #{len} tables from Google Sheets API.")
  end

  defp get_spreadsheet_tables({tables, idx}, total, total_ranges, bearer_token) do
    connection = GoogleApi.Sheets.V4.Connection.new(bearer_token)
    pid_label  = inspect(self())
    count      = length(tables)
    planned_after = min(idx * @batch_size + count, total_ranges)

    Logger.info("Fetching chunk #{idx + 1}/#{total} pid=#{pid_label} ranges=#{count} progress=#{planned_after}/#{total_ranges}")

    Process.sleep(200)

    result =
      connection
      |> GoogleApi.Sheets.V4.Api.Spreadsheets.sheets_spreadsheets_values_batch_get(
        @spreadsheet_id,
        ranges: Enum.map(tables, & &1.range),
        valueRenderOption: "UNFORMATTED_VALUE",
        dateTimeRenderOption: "FORMATTED_STRING"
      )

    case result do
      {:ok, %{valueRanges: vrs}} ->
        returned = length(vrs || [])
        planned_after = min(idx * @batch_size + returned, total_ranges)
        Logger.info("Fetched chunk #{idx + 1}/#{total} pid=#{pid_label} returned=#{returned} progress=#{planned_after}/#{total_ranges}")

      {:error, error} ->
        Logger.error("Chunk #{idx + 1}/#{total} pid=#{pid_label} API error: #{inspect(error)}")
    end

    result
    |> process_response(tables)
  end

  defp metadata_name(FastApi.Schemas.Fast.Table), do: "main"
  defp metadata_name(FastApi.Schemas.Fast.DetailTable), do: "detail"

  defp process_response({:ok, response}, tables) do
    value_ranges = response.valueRanges || []

    tables
    |> Enum.zip(value_ranges)
    |> Enum.map(fn
      {%_{} = table, %ValueRange{values: [headers | rows]}} when is_list(headers) ->
        headers_clean =
          headers
          |> Enum.map(fn h ->
            h
            |> to_string()
            |> String.replace(~r/[\W_]+/, "")
          end)

        rows
        |> Enum.map(fn row ->
          headers_clean
          |> Enum.zip(row)
          |> Enum.into(%{})
        end)
        |> Jason.encode!()
        |> then(&{table, %{rows: &1}})

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

  defp process_response({:error, %{body: error}}, _) do
    Logger.error("Error while fetching spreadsheet data: #{inspect(error)}")
    []
  end

  defp log_and_raise(table, reason, context) do
    label = table_label(table)

    Logger.error("""
    Spreadsheet sync failed: #{reason}
    table=#{label}
    context=#{inspect(context, pretty: true, limit: :infinity, printable_limit: :infinity)}
    """)

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
end
