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
    - I4: Duplicates across main-table rows are **intentional**; first-found is used, no warning.
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

      # 2) Parse and filter candidate (category,key,range_name)
      {candidates, dup_errors} = parse_candidates(named_ranges)

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

  # ---------- STEP 2: Parse candidates from named ranges ----------

  @doc false
  defp parse_candidates(named_ranges) do
    # We allow multiple named ranges overall, but if **two names** parse to the **same** (category,key),
    # it’s I3. We record the first and log errors for duplicates; duplicates are skipped.
    {kept, dup_errors} =
      Enum.reduce(named_ranges, {%{}, 0}, fn nr, {acc, dupcnt} ->
        name = nr.name || ""

        case parse_range_name(name) do
          :ignore ->
            {acc, dupcnt}

          {:error, :malformed} ->
            # Malformed names are simply ignored (not part of our naming convention).
            {acc, dupcnt}

          {:ok, %{category: cat, key: key}} ->
            k = {cat, key}

            if Map.has_key?(acc, k) do
              # I3 – duplicate mapping from Sheets
              Logger.error(
                "[GoogleSheetsDetailed] I3 Duplicate Sheets mapping for (category=#{cat}, key=#{key}) name=#{name}"
              )

              {acc, dupcnt + 1}
            else
              Map.put(acc, k, %{category: cat, key: key, range: name})
              |> then(&{&1, dupcnt})
            end
        end
      end)

    {Map.values(kept), dup_errors}
  end

  # Rules:
  #  - Name form: CategoryWord + KeyCamel
  #  - Ignore ALL UPPERCASE CategoryWord (INTERNAL/...)
  #  - Return {:ok, %{category, key}} with lowercase `category` and kebab-case `key`.
  defp parse_range_name(name) when is_binary(name) do
    # Split CamelCase into tokens
    tokens = camel_tokens(name)

    case tokens do
      [] ->
        :ignore

      [cat_token | key_tokens] ->
        cond do
          # If no remainder, there is no key part => malformed
          key_tokens == [] ->
            :ignore

          all_upper?(cat_token) ->
            # INTERNAL, NEGATIVE etc. are ignored
            :ignore

          true ->
            category = String.downcase(cat_token)
            key =
              key_tokens
              |> Enum.map(&String.downcase/1)
              |> Enum.join("-")

            if key == "" do
              :ignore
            else
              {:ok, %{category: category, key: key}}
            end
        end
    end
  end

  defp camel_tokens(s) do
    # Split CamelCase and also break on non-alphanumeric
    # Example: "BagNewBag" -> ["Bag","New","Bag"]
    # Fallback: if it contains non-camel, we still try to keep alnum sequences.
    Regex.scan(~r/[A-Z]?[a-z0-9]+|[A-Z]+(?![a-z])/, s)
    |> Enum.map(&hd/1)
  end

  defp all_upper?(s) do
    s != "" and s == String.upcase(s) and String.match?(s, ~r/^[A-Z0-9_]+$/)
  end

  # ---------- STEP 3: Build main-table index & validate rows (I5/I6) ----------

  defp build_main_index_and_log_issues() do
    # index: %{ {cat,key} => %{name: Name, table_id: id} } ; first-wins (lowest id)
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

        # Normalize like our parser
        category = String.downcase(String.trim(cat0))
        key = String.downcase(String.trim(key0))

        # I5/I6 validations on human mistakes in main-table rows
        cond do
          category == "" and key != "" ->
            Logger.error("[GoogleSheetsDetailed] I5 Key present but Category empty in main-table row (table_id=#{tid}, key=#{key})")
            inner

          category != "" and not all_upper?(String.trim(cat0)) and key == "" ->
            Logger.error("[GoogleSheetsDetailed] I6 Category present but Key empty in main-table row (table_id=#{tid}, category=#{category})")
            inner

          # both empty → ignore silently
          category == "" and key == "" ->
            inner

          true ->
            # First wins; no warning on duplicates across tables (intended)
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
        {:ok, %GoogleApi.Sheets.V4.Model.BatchGetValuesResponse{valueRanges: vrs}}
            when is_list(vrs) ->
          Enum.flat_map(vrs, fn
            %GoogleApi.Sheets.V4.Model.ValueRange{range: name, values: values} ->
              if is_list(values) and values != [] do
                [normalize_range_name(name)]
              else
                []
              end

            _ ->
              []
          end)

        _ ->
          []
      end
    end)
  end

  defp fetch_values_batch(conn, ranges, attempt)
       when attempt <= @backoff_attempts do
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

  defp normalize_range_name(range) when is_binary(range) do
    # ValueRange.range can be like 'SheetName!A1:B' or NamedRange. We prefer the NamedRange.
    case String.split(range, "!", parts: 2) do
      [single] -> single
      [maybe_name, _] -> maybe_name
    end
  end

  # ---------- STEP 6: Try inserts ----------

  defp insert_new_detail_tables(candidates, main_index, df_index, valid_set) do
    Enum.reduce(candidates, {0, 0, 0, 0, 0}, fn c, {ins, exist, e3, i1, miss} ->
      %{category: cat, key: key, range: range_name} = c

      case {Map.get(df_index, cat), Map.get(main_index, {cat, key})} do
        {nil, _} ->
          # I1: Unknown category
          Logger.error("[GoogleSheetsDetailed] I1 Unknown category: detail_features.name missing for category=#{cat}")
          {ins, exist, e3, i1 + 1, miss}

        {_, nil} ->
          # E3: Sheets→DB orphan (no main-table row)
          Logger.error("[GoogleSheetsDetailed] E3 Sheets orphan: (category=#{cat}, key=#{key}) from range=#{range_name} has no main-table row")
          {ins, exist, e3 + 1, i1, miss}

        {df_id, %{name: name}} ->
          # Verify the range has values
          if MapSet.member?(valid_set, range_name) do
            # Check existence in detail_tables
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
                    # Unique constraint races will land here; treat as exists
                    if has_unique_violation?(changeset) do
                      {ins, exist + 1, e3, i1, miss}
                    else
                      Logger.error("[GoogleSheetsDetailed] Insert failed for (category=#{cat}, key=#{key}): #{inspect(changeset.errors)}")
                      {ins, exist, e3, i1, miss}
                    end
                end
            end
          else
            # Missing/empty values for that named range
            Logger.error("[GoogleSheetsDetailed] MISSING_VALUES range has no data: range=#{range_name} (category=#{cat}, key=#{key})")
            {ins, exist, e3, i1, miss + 1}
          end
      end
    end)
  end

  defp compose_range_name(category, key) do
    # category "bag" + key "new-bag" → "BagNewBag"
    cat = titleize_token(category)
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
      {_field, {_, [constraint: :unique, _ | _]}} -> true
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
