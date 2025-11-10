defmodule FastApi.Sync.GoogleSheetsDetailed do
  @moduledoc """
  Discover new (Category, Key) from Google Sheets named ranges and auto-insert
  into public.detail_tables. Reads `Name` from main-table JSON (public.tables.rows).
  This module only inserts new rows.

  Error policy (logged as ERROR, no insert):
    - E3: Named range exists in Sheets but no (Category,Key) in main-table rows (Sheets→DB orphan).
    - I1: Unknown category (no matching detail_features.name).
    - I3: Duplicate Sheets mapping (two named ranges → same (Category,Key)).
    - I5: Category empty, Key filled in main-table rows.
    - I6: Category filled (not ALL UPPERCASE), Key empty in main-table rows.
    - R1: DB→Sheets orphan (detail_tables.range missing in Sheets or empty).

  Non-errors (ignored or normal):
    - All-uppercase categories (INTERNAL...) are ignored.
    - Both Category and Key empty in a row are ignored.
    - I4: Duplicates across main-table rows are intentional; first-found is used, no warning.
  """

  alias FastApi.Repo
  alias FastApi.Schemas.Fast
  import Ecto.Query
  require Logger

  @spreadsheet_id "1WdwWxyP9zeJhcxoQAr-paMX47IuK6l5rqAPYDOA8mho"
  @backoff_attempts 5
  @backoff_base_ms 400
  @batch_size 80

  def execute() do
    t0 = System.monotonic_time(:millisecond)

    try do
      {:ok, token} = Goth.fetch(FastApi.Goth)
      conn = GoogleApi.Sheets.V4.Connection.new(token.token)

      # 1) Pull all named ranges once
      named_ranges = fetch_named_ranges!(conn)

      # Build quick lookup set for DB→Sheets reconciliation
      named_set = MapSet.new(Enum.map(named_ranges, & &1.name))

      # 1b) Load existing detail_feature names (lowercased) for multi-word category prefix matching
      df_names = load_detail_feature_names()

      # 2) Parse and filter candidate (category,key,range_name) using longest prefix match
      {candidates, dup_errors} = parse_candidates(named_ranges, df_names)

      # 3) Load main-table rows index and validate human mistakes (I5/I6)
      main_index = build_main_index_and_log_issues()

      # 4) Resolve detail_feature_ids for all categories we’ll touch (case-insensitive)
      df_index = resolve_detail_feature_ids(MapSet.new(Enum.map(candidates, & &1.category)))

      # 5) Verify the ranges actually return data (batch GET)
      valid_ranges = verify_ranges_with_values(conn, Enum.map(candidates, & &1.range), @batch_size)
      valid_set = MapSet.new(valid_ranges)

      # 6) Iterate candidates -> insert when all checks pass; else log specific error
      {inserted, exists, e3_orphans, i1_unknown, missing_values} =
        insert_new_detail_tables(candidates, main_index, df_index, valid_set)

      # 7) Reconciliation DB→Sheets (R1): detail_tables rows whose range is missing from Sheets
      r1_orphans = db_to_sheets_orphans(named_set)

      # Totals
      dt = System.monotonic_time(:millisecond) - t0

      Logger.info(
        "[GoogleSheetsDetailed] inserted=#{inserted} exists=#{exists} " <>
          "errors={E3=#{e3_orphans} I1=#{i1_unknown} I3=#{dup_errors} I5/I6=see above MISSING_VALUES=#{missing_values} R1=#{r1_orphans}} " <>
          "in #{fmt_ms(dt)}"
      )

      :ok
    rescue
      e ->
        Logger.error("[GoogleSheetsDetailed] failed: #{Exception.message(e)}")
        reraise e, __STACKTRACE__
    end
  end

  # ---------- STEP 1: Named ranges ----------

  defp fetch_named_ranges!(conn) do
    case GoogleApi.Sheets.V4.Api.Spreadsheets.sheets_spreadsheets_get(
           conn,
           @spreadsheet_id,
           fields: "namedRanges"
         ) do
      {:ok, %GoogleApi.Sheets.V4.Model.Spreadsheet{namedRanges: list}} when is_list(list) ->
        list

      {:ok, %GoogleApi.Sheets.V4.Model.Spreadsheet{namedRanges: nil}} ->
        []

      {:error, %Tesla.Env{} = env} ->
        raise "GSheets get(namedRanges) failed: #{inspect(env)}"

      other ->
        raise "Unexpected response for namedRanges: #{inspect(other)}"
    end
  end

  # ---------- STEP 1b: Load detail_feature names ----------

  defp load_detail_feature_names() do
    from(df in Fast.DetailFeature, select: fragment("LOWER(?)", df.name))
    |> Repo.all()
    |> MapSet.new()
  end

  # ---------- STEP 2: Parse candidates from named ranges (with prefix matching) ----------

  @doc false
  defp parse_candidates(named_ranges, df_names) do
    {kept, dup_errors} =
      Enum.reduce(named_ranges, {%{}, 0}, fn nr, {acc, dupcnt} ->
        name = nr.name || ""

        case parse_range_name(name, df_names) do
          :ignore ->
            {acc, dupcnt}

          {:error, :malformed} ->
            {acc, dupcnt}

          {:ok, %{category: cat, key: key}} ->
            k = {cat, key}

            if Map.has_key?(acc, k) do
              Logger.error("[GoogleSheetsDetailed] I3 Duplicate Sheets mapping for (category=#{cat}, key=#{key}) name=#{name}")
              {acc, dupcnt + 1}
            else
              Map.put(acc, k, %{category: cat, key: key, range: name})
              |> then(&{&1, dupcnt})
            end
        end
      end)

    {Map.values(kept), dup_errors}
  end

  # Try to find the longest CamelCase prefix that equals some detail_features.name.
  # otherwise first token = category, rest = key.
  defp parse_range_name(name, df_names) when is_binary(name) do
    tokens = camel_tokens(name)

    cond do
      tokens == [] ->
        :ignore

      true ->
        [first | _] = tokens

        if all_upper?(first) do
          :ignore
        else
          to_kebab = fn toks ->
            toks |> Enum.map(&String.downcase/1) |> Enum.join("-")
          end

          prefixes =
            tokens
            |> Enum.with_index(1)
            |> Enum.map(fn {_tok, i} -> Enum.take(tokens, i) end)

          matched_prefix =
            prefixes
            |> Enum.reverse()
            |> Enum.find(fn pref -> MapSet.member?(df_names, to_kebab.(pref)) end)

          if matched_prefix do
            category = to_kebab.(matched_prefix)
            key_tokens = Enum.drop(tokens, length(matched_prefix))

            if key_tokens == [] do
              :ignore
            else
              key = key_tokens |> Enum.map(&String.downcase/1) |> Enum.join("-")
              {:ok, %{category: category, key: key}}
            end
          else
            # Fallback to old behavior
            [cat_token | key_tokens] = tokens

            if key_tokens == [] do
              :ignore
            else
              category = String.downcase(cat_token)
              key = key_tokens |> Enum.map(&String.downcase/1) |> Enum.join("-")
              {:ok, %{category: category, key: key}}
            end
          end
        end
    end
  end

  defp camel_tokens(s) do
    Regex.scan(~r/[A-Z]?[a-z0-9]+|[A-Z]+(?![a-z])/, s)
    |> Enum.map(&hd/1)
  end

  defp all_upper?(s) do
    s != "" and s == String.upcase(s) and String.match?(s, ~r/^[A-Z0-9_]+$/)
  end

  # ---------- STEP 3: Build main-table index & validate rows (I5/I6) ----------

  defp build_main_index_and_log_issues() do
    tables =
      from(t in Fast.Table, select: %{id: t.id, rows: t.rows})
      |> Repo.all()

    Enum.reduce(tables, %{}, fn %{id: tid, rows: json}, acc ->
      rows_list =
        case Jason.decode(json || "[]") do
          {:ok, list} when is_list(list) -> list
          _ -> []
        end

      Enum.reduce(rows_list, acc, fn row, inner ->
        cat0 = to_string(Map.get(row, "Category", "") || "")
        key0 = to_string(Map.get(row, "Key", "") || "")

        category = String.downcase(String.trim(cat0))
        key = String.downcase(String.trim(key0))

        cond do
          category == "" and key != "" ->
            Logger.error("[GoogleSheetsDetailed] I5 Key present but Category empty in main-table row (table_id=#{tid}, key=#{key})")
            inner

          category != "" and not all_upper?(String.trim(cat0)) and key == "" ->
            Logger.error("[GoogleSheetsDetailed] I6 Category present but Key empty in main-table row (table_id=#{tid}, category=#{category})")
            inner

          category == "" and key == "" ->
            inner

          true ->
            name = to_string(Map.get(row, "Name", "") || "")
            k = {category, key}
            if Map.has_key?(inner, k), do: inner, else: Map.put(inner, k, %{name: name, table_id: tid})
        end
      end)
    end)
  end

  # ---------- STEP 4: Resolve detail_feature_id per category (case-insensitive) ----------

  defp resolve_detail_feature_ids(category_set) do
    cats = MapSet.to_list(category_set)
    down = Enum.map(cats, &String.downcase/1)

    q =
      from(df in Fast.DetailFeature,
        where: fragment("LOWER(?)", df.name) in ^down,
        select: {fragment("LOWER(?)", df.name), df.id}
      )

    Repo.all(q) |> Map.new()
  end

  # ---------- STEP 5: Verify ranges return values ----------

  defp verify_ranges_with_values(conn, range_names, batch_size) do
    range_names
    |> Enum.chunk_every(batch_size)
    |> Enum.flat_map(fn chunk ->
      case fetch_values_batch(conn, chunk, 1) do
        {:ok, %GoogleApi.Sheets.V4.Model.BatchGetValuesResponse{valueRanges: vrs}} when is_list(vrs) ->
          # Zip the requested names with the returned valueRanges; if that entry has values, mark the requested name as valid.
          Enum.zip(chunk, vrs)
          |> Enum.flat_map(fn {requested_name, %GoogleApi.Sheets.V4.Model.ValueRange{values: values}} ->
            if is_list(values) and values != [] do
              [requested_name]
            else
              []
            end
          end)

        _ ->
          []
      end
    end)
  end

  defp fetch_values_batch(conn, ranges, attempt) when attempt <= @backoff_attempts do
    case GoogleApi.Sheets.V4.Api.Spreadsheets.sheets_spreadsheets_values_batch_get(
           conn,
           @spreadsheet_id,
           ranges: ranges,
           valueRenderOption: "UNFORMATTED_VALUE",
           dateTimeRenderOption: "FORMATTED_STRING"
         ) do
      {:ok, resp} ->
        {:ok, resp}

      {:error, %Tesla.Env{status: 429}} ->
        wait = trunc(:math.pow(2, attempt - 1) * @backoff_base_ms)
        Logger.warning("[GoogleSheetsDetailed] values batch 429; backing off #{wait}ms (#{attempt}/#{@backoff_attempts})")
        Process.sleep(wait)
        fetch_values_batch(conn, ranges, attempt + 1)

      {:error, %Tesla.Env{status: status}} when status in 500..599 ->
        wait = trunc(:math.pow(2, attempt - 1) * @backoff_base_ms)
        Logger.warning("[GoogleSheetsDetailed] values batch #{status}; backing off #{wait}ms (#{attempt}/#{@backoff_attempts})")
        Process.sleep(wait)
        fetch_values_batch(conn, ranges, attempt + 1)

      {:error, other} ->
        Logger.error("[GoogleSheetsDetailed] values batch error: #{inspect(other)}")
        {:error, other}
    end
  end

  defp fetch_values_batch(_conn, _ranges, _attempt), do: {:error, :backoff_exhausted}

  # ---------- STEP 6: Try inserts ----------

  defp insert_new_detail_tables(candidates, main_index, df_index, valid_set) do
    Enum.reduce(candidates, {0, 0, 0, 0, 0}, fn c, {ins, exist, e3, i1, miss} ->
      %{category: cat, key: key, range: range_name} = c

      case {Map.get(df_index, cat), Map.get(main_index, {cat, key})} do
        {nil, _} ->
          Logger.error("[GoogleSheetsDetailed] I1 Unknown category: detail_features.name missing for category=#{cat}")
          {ins, exist, e3, i1 + 1, miss}

        {_, nil} ->
          Logger.error("[GoogleSheetsDetailed] E3 Sheets orphan: (category=#{cat}, key=#{key}) from range=#{range_name} has no main-table row")
          {ins, exist, e3 + 1, i1, miss}

        {df_id, %{name: name}} ->
          if MapSet.member?(valid_set, range_name) do
            case Repo.get_by(Fast.DetailTable, detail_feature_id: df_id, key: key) do
              %Fast.DetailTable{} ->
                {ins, exist + 1, e3, i1, miss}

              nil ->
                params = %{
                  detail_feature_id: df_id,
                  key: key,
                  name: name,
                  range: compose_range_name(cat, key)
                }

                changeset =
                  %Fast.DetailTable{}
                  |> Ecto.Changeset.cast(params, [:detail_feature_id, :key, :name, :range])

                case Repo.insert(changeset) do
                  {:ok, _} ->
                    {ins + 1, exist, e3, i1, miss}

                  {:error, changeset} ->
                    if has_unique_violation?(changeset) do
                      {ins, exist + 1, e3, i1, miss}
                    else
                      Logger.error("[GoogleSheetsDetailed] Insert failed for (category=#{cat}, key=#{key}): #{inspect(changeset.errors)}")
                      {ins, exist, e3, i1, miss}
                    end
                end
            end
          else
            Logger.error("[GoogleSheetsDetailed] MISSING_VALUES range has no data: range=#{range_name} (category=#{cat}, key=#{key})")
            {ins, exist, e3, i1, miss + 1}
          end
      end
    end)
  end

  defp compose_range_name(category, key) do
    # Handle multi-token categories like "bag-opener" -> "BagOpener"
    cat =
      category
      |> String.split(~r/[-_\s]+/, trim: true)
      |> Enum.map(&titleize_token/1)
      |> Enum.join("")

    key_title =
      key
      |> String.split(~r/[-_\s]+/, trim: true)
      |> Enum.map(&titleize_token/1)
      |> Enum.join("")

    cat <> key_title
  end

  defp titleize_token(s) do
    s = String.downcase(s || "")

    case String.length(s) do
      0 -> s
      _ -> String.upcase(String.first(s)) <> String.slice(s, 1..-1)
    end
  end

  defp has_unique_violation?(changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  # ---------- STEP 7: DB→Sheets reconciliation (R1) ----------

  defp db_to_sheets_orphans(named_set) do
    q = from(dt in Fast.DetailTable, select: %{id: dt.id, range: dt.range})

    Repo.all(q)
    |> Enum.reduce(0, fn %{id: id, range: range}, acc ->
      if is_binary(range) and MapSet.member?(named_set, range) do
        acc
      else
        Logger.error("[GoogleSheetsDetailed] R1 DB orphan: detail_tables.id=#{id} range=#{inspect(range)} missing in Sheets")
        acc + 1
      end
    end)
  end

  # ---------- Utils ----------

  defp fmt_ms(ms) do
    total = div(ms, 1000)
    mins = div(total, 60)
    secs = rem(total, 60)
    "#{mins}:#{String.pad_leading(Integer.to_string(secs), 2, "0")} mins"
  end
end
