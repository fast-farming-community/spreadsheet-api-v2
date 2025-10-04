defmodule FastApi.Search do
  import Ecto.Query
  alias FastApi.Repo
  alias FastApi.Schemas.Fast

  @snippet_json_keys ~w(Name Notes Requires Price Rarity Type)

  def search(q, limit) when is_binary(q) do
    like = "%#{q}%"

    base =
      from t in Fast.Table,
        join: p in Fast.Page,    on: p.id == t.page_id,
        join: f in Fast.Feature, on: f.id == p.feature_id,
        where:
          ilike(f.name, ^like) or
          ilike(p.name, ^like) or
          ilike(t.name, ^like) or
          ilike(t.description, ^like) or
          ilike(fragment("?::text", t.rows), ^like),   # ← cast rows to text
        select: %{
          module: f.name,
          collection: p.name,
          page: p.name,
          table: t.name,
          description: t.description,
          rows: t.rows
        },
        limit: ^(limit * 3)

    Repo.all(base)
    |> Enum.map(&add_score_and_snippet(&1, q))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.uniq_by(fn r -> {r.module, r.collection, r.table} end)
    |> Enum.take(limit)
    |> Enum.map(&to_api/1)
  end

  defp to_api(%{module: m, collection: c, page: page, table: table, snippet: snip}) do
    %{
      route: "#{m}/#{c}",   # no trailing slash
      page: page,
      table: table,
      snippet: snip
    }
  end

  defp add_score_and_snippet(row, q) do
    qd = String.downcase(q)
    f1 = row.page || ""
    f2 = row.table || ""
    f3 = row.description || ""
    f4 = row.rows || ""

    score =
      starts_with(f1, qd) * 8 +
      starts_with(f2, qd) * 6 +
      contains(f1, qd) * 5 +
      contains(f2, qd) * 4 +
      contains(f3, qd) * 3 +
      contains(f4, qd) * 2

    snippet =
      cond do
        contains(f2, qd) -> snippet(f2, q)
        contains(f3, qd) -> snippet(f3, q)
        true             -> snippet_from_rows_user_friendly(f4, q)
      end

    row
    |> Map.put(:score, score)
    |> Map.put(:snippet, snippet)
  end

  defp contains(text, qd), do: is_binary(text) and String.contains?(String.downcase(text), qd)
  defp starts_with(text, qd), do: (is_binary(text) and String.starts_with?(String.downcase(text), qd) && 1) || 0

  defp snippet(text, q, pre \\ 24, len \\ 64) do
    td = String.downcase(text || "")
    qd = String.downcase(q)
    case :binary.match(td, qd) do
      {idx, _} ->
        from = max(idx - pre, 0)
        to   = min(from + len, String.length(text))
        (if from > 0, do: "...", else: "") <>
          String.slice(text, from, to - from) <>
          (if to < String.length(text), do: "...", else: "")
      :nomatch ->
        String.slice(text || "", 0, min(64, String.length(text || "")))
    end
  end

  # Only consider user-facing keys for snippet (no Key/Category)
  defp snippet_from_rows_user_friendly(rows, q) when is_binary(rows) do
    with {:ok, list} <- Jason.decode(rows),
         true <- is_list(list) do
      qd = String.downcase(q)

      best =
        Enum.find_value(list, fn row ->
          if is_map(row) do
            cond do
              is_binary(row["Name"]) and String.contains?(String.downcase(row["Name"]), qd) ->
                row["Name"]
              true ->
                Enum.find_value(@snippet_json_keys, fn k ->
                  v = row[k]
                  if is_binary(v) and String.contains?(String.downcase(v), qd), do: v, else: nil
                end)
            end
          else
            nil
          end
        end)

      if is_binary(best), do: snippet(best, q), else: nil
    else
      _ -> nil
    end
  end
  defp snippet_from_rows_user_friendly(_, _), do: nil
end
