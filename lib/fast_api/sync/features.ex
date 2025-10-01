defmodule FastApi.Sync.Features do
  @moduledoc "Synchronize the database using spreadsheet data (tiered)."

  alias FastApi.Repo
  alias FastApi.Schemas.Fast
  alias GoogleApi.Sheets.V4.Model.ValueRange

  require Logger

  @spreadsheet_id "1WdwWxyP9zeJhcxoQAr-paMX47IuK6l5rqAPYDOA8mho"
  @batch_size 80
  @max_retries 3

  @type tier :: :free | :copper | :silver | :gold

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
      nil -> 5
      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, _} when n >= 1 and n <= 10 -> n
          _ -> 5
        end
    end
  end

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
        # keep errors loud
        Logger.error("[features] tier=#{tier_label(tier)} repo=#{repo_tag} failed: #{Exception.message(e)}")
        reraise e, __STACKTRACE__
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

    # Collect triples: {table_struct, field_atom, json_string}
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

    # Update only when value actually changed; count updates
    updated_count =
      triples
      |> Enum.reduce(0, fn {table, field, json}, acc ->
        current = Map.get(table, field)
        if current != json do
          changes = %{field => json}
          cs = repo.changeset(table, changes)
          case Repo.update(cs) do
            {:ok, _}   -> acc + 1
            {:error, _} -> acc
          end
        else
          acc
        end
      end)

    # per-tier metadata timestamp
    update_metadata!(repo, tier)

    # return number updated for outer log
    updated_count
  end

  defp get_spreadsheet_tables({tables, idx}, total, _total_ranges, bearer_token, tier) do
    connection = GoogleApi.Sheets.V4.Connection.new(bearer_token)
    pid_label  = inspect(self())
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
      {:error, error} ->
        Logger.error("Chunk #{idx + 1}/#{total} pid=#{pid_label} API error: #{inspect(error)}")
      _ -> :ok
    end

    result
    |> process_response(tables, tier)
  end

  defp metadata_name(FastApi.Schemas.Fast.Table), do: "main"
  defp metadata_name(FastApi.Schemas.Fast.DetailTable), do: "detail"

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
    Logger.error("Spreadsheet sync failed: #{reason} table=#{label} context=#{inspect(context, pretty: true, limit: :infinity, printable_limit: :infinity)}")
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
