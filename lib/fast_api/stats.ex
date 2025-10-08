defmodule FastApi.Stats do
  @moduledoc "Minimal analytics stored in Fast.Metadata (daily aggregates)."
  alias FastApi.Repo
  alias FastApi.Schemas.Fast
  require Logger

  @name "stats"
  @retention_days 30

  # ---------- Public API ----------

  @doc """
  Track an event for today. Supported types:
    - :page_view with %{route: "/path"}
    - :click with %{target: "link:/path" | "out:https://..."}
    - :sequence with %{from: "/from", to: "/to"}  (optional)
  """
  def track(:page_view, %{route: route}) when is_binary(route),
    do: inc_today("page_views", norm_route(route))

  def track(:click, %{target: target}) when is_binary(target),
    do: inc_today("clicks", norm_click(target))

  def track(:sequence, %{from: from, to: to}) when is_binary(from) and is_binary(to),
    do: inc_today("sequences", norm_route(from) <> ">" <> norm_route(to))

  def track(_type, _payload), do: :ok

  @doc """
  Return a summary with top items and percentage deltas vs:
    - yesterday (D-1)
    - last week (sum of last 7 days vs previous 7)
    - last month (sum of last 30 vs previous 30)

  opts: %{limit: 10}
  """
  def summary(opts \\ %{limit: 10}) do
    limit = Map.get(opts, :limit, 10)
    %{daily: daily} = load_stats()

    today = Date.utc_today()
    dkeys = Map.keys(daily) |> Enum.sort(:desc)

    # windows
    d1  = Date.add(today, -1)
    w0  = Date.range(Date.add(today, -6), today)         # last 7
    w1  = Date.range(Date.add(today, -13), Date.add(today, -7))
    m0  = Date.range(Date.add(today, -29), today)        # last 30
    m1  = Date.range(Date.add(today, -59), Date.add(today, -30))

    # build aggregates
    pv = %{
      today: get_day(daily, today, "page_views"),
      d1:    get_day(daily, d1, "page_views"),
      w0:    sum_range(daily, w0, "page_views"),
      w1:    sum_range(daily, w1, "page_views"),
      m0:    sum_range(daily, m0, "page_views"),
      m1:    sum_range(daily, m1, "page_views")
    }

    cl = %{
      today: get_day(daily, today, "clicks"),
      d1:    get_day(daily, d1, "clicks"),
      w0:    sum_range(daily, w0, "clicks"),
      w1:    sum_range(daily, w1, "clicks"),
      m0:    sum_range(daily, m0, "clicks"),
      m1:    sum_range(daily, m1, "clicks")
    }

    %{
      page_views: top_with_deltas(pv, limit),
      clicks:     top_with_deltas(cl, limit),
      days_available: length(dkeys)
    }
  end

  defp norm_route(route) do
    r = String.trim(route)
    if String.starts_with?(r, "/"), do: r, else: "/" <> r
  end

  defp norm_click(s) when is_binary(s) do
    cond do
      String.starts_with?(s, "link:") -> s
      String.starts_with?(s, "out:")  -> s
      String.starts_with?(s, "/")     -> "link:" <> s
      String.starts_with?(s, "http")  -> "out:" <> s
      true                            -> "link:/" <> String.trim(s, "/")
    end
  end

  defp today_key, do: Date.utc_today() |> Date.to_iso8601()

  defp load_stats() do
    case Repo.get_by(Fast.Metadata, name: @name) do
      nil -> %{retention_days: @retention_days, daily: %{}, last_compacted_at: nil}
      %Fast.Metadata{data: nil} -> %{retention_days: @retention_days, daily: %{}, last_compacted_at: nil}
      %Fast.Metadata{data: bin} ->
        case Jason.decode(bin) do
          {:ok, %{} = m} ->
            %{
              retention_days: Map.get(m, "retention_days", @retention_days),
              daily: Map.get(m, "daily", %{}),
              last_compacted_at: Map.get(m, "last_compacted_at")
            }

          _ -> %{retention_days: @retention_days, daily: %{}, last_compacted_at: nil}
        end
    end
  end

  defp save_stats!(%{retention_days: rd, daily: daily} = m) do
    data =
      m
      |> Map.put("retention_days", rd)
      |> Map.put("daily", daily)
      |> Map.put("last_compacted_at", DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())
      |> Jason.encode!()

    case Repo.get_by(Fast.Metadata, name: @name) do
      nil ->
        %Fast.Metadata{name: @name}
        |> Fast.Metadata.changeset(%{data: data})
        |> Repo.insert!()

      row ->
        row
        |> Fast.Metadata.changeset(%{data: data})
        |> Repo.update!()
    end

    :ok
  end

  defp inc_today(bucket, key) do
    Repo.transaction(fn ->
      stats = load_stats()
      day   = today_key()
      daily = stats.daily

      day_map    = Map.get(daily, day, %{})
      bucket_map = Map.get(day_map, bucket, %{})
      new_bucket = Map.update(bucket_map, key, 1, &(&1 + 1))
      new_day    = Map.put(day_map, bucket, new_bucket)

      daily1 = Map.put(daily, day, new_day)
      daily2 = trim_old(daily1, stats.retention_days)

      save_stats!(%{stats | daily: daily2})
    end)

    :ok
  end

  defp trim_old(daily, retention_days) do
    cutoff = Date.add(Date.utc_today(), -retention_days) |> Date.to_iso8601()
    daily
    |> Enum.reject(fn {day, _} -> day < cutoff end)
    |> Map.new()
  end

  defp get_day(daily, %Date{} = d, bucket) do
    key = Date.to_iso8601(d)
    with %{} = day <- Map.get(daily, key),
         %{} = b   <- Map.get(day, bucket) do
      b
    else
      _ -> %{}
    end
  end

  defp sum_range(daily, %Date.Range{} = range, bucket) do
    range
    |> Enum.reduce(%{}, fn d, acc ->
      Map.merge(acc, get_day(daily, d, bucket), fn _k, a, b -> a + b end)
    end)
  end

  defp top_with_deltas(%{today: t, d1: d1, w0: w0, w1: w1, m0: m0, m1: m1}, limit) do
    keys =
      [t, d1, w0, w1, m0, m1]
      |> Enum.flat_map(&Map.keys/1)
      |> MapSet.new()
      |> MapSet.to_list()

    items =
      Enum.map(keys, fn k ->
        today = Map.get(t,  k, 0)
        d1v   = Map.get(d1, k, 0)
        w0v   = Map.get(w0, k, 0)
        w1v   = Map.get(w1, k, 0)
        m0v   = Map.get(m0, k, 0)
        m1v   = Map.get(m1, k, 0)
        %{
          key: k,
          today: today,
          d1_change_pct: pct(today, d1v),
          w_change_pct:  pct(w0v,   w1v),
          m_change_pct:  pct(m0v,   m1v)
        }
      end)
      |> Enum.sort_by(fn %{today: v} -> -v end)

    %{top: Enum.take(items, limit), top50: Enum.take(items, 50)}
  end

  defp pct(cur, prev) do
    cond do
      prev <= 0 and cur > 0 -> 100.0
      prev == 0 and cur == 0 -> 0.0
      true -> Float.round((cur - prev) / prev * 100.0, 1)
    end
  end

  def compact!() do
    %{daily: daily, retention_days: rd} = load_stats()
    save_stats!(%{retention_days: rd, daily: trim_old(daily, rd)})
    end
end
