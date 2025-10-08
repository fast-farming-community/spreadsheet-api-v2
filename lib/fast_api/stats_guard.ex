defmodule FastApi.StatsGuard do
  @moduledoc false
  @table __MODULE__
  @debounce_ms 1_000
  @per_minute 60
  @per_day 500

  def child_spec(_arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}, type: :worker}
  end

  def start_link(_) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true, write_concurrency: true])
    {:ok, self()}
  end

  # true = allow; false = drop
  def allow?(fp, type, key) when is_binary(fp) do
    now = System.system_time(:millisecond)
    minute = div(now, 60_000)
    day = Date.utc_today() |> Date.to_iso8601()
    hit_key = {:hit, fp, type, key}
    min_key = {:min, fp, minute}
    day_key = {:day, fp, day}

    last =
      case :ets.lookup(@table, hit_key) do
        [{^hit_key, t}] -> t
        _ -> 0
      end

    cond do
      now - last < @debounce_ms -> false
      bump(min_key) > @per_minute -> false
      bump(day_key) > @per_day -> false
      true ->
        :ets.insert(@table, {hit_key, now})
        true
    end
  end

  defp bump(k) do
    try do
      :ets.update_counter(@table, k, {2, 1}, {k, 0})
    catch
      _, _ -> 0
    end
  end
end
