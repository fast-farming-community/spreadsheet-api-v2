defmodule FastApi.Debug.Memory do
  @moduledoc "Helpers to inspect BEAM memory usage in production."
  require Logger

  # ---- high-level snapshot: what kind of memory is growing? ----
  def snapshot(label \\ "") do
    mem = :erlang.memory()
    to_mb = fn bytes -> Float.round(bytes / 1_048_576, 2) end

    total  = to_mb.(mem[:total])
    procs  = to_mb.(mem[:processes_used])
    ets    = to_mb.(mem[:ets])
    binary = to_mb.(mem[:binary])
    code   = to_mb.(mem[:code])
    atom   = to_mb.(mem[:atom_used])

    Logger.info(
      "[mem] #{label} " <>
        "total=#{total} MB " <>
        "procs=#{procs} MB " <>
        "ets=#{ets} MB " <>
        "bin=#{binary} MB " <>
        "code=#{code} MB " <>
        "atom=#{atom} MB"
    )

    :ok
  end

  # ---- biggest ETS tables (for when ets is the problem) ----
  def top_ets(n \\ 10) do
    tables =
      :ets.all()
      |> Enum.map(fn tid ->
        info = :ets.info(tid)
        name = info[:name]
        size = info[:size]
        memory_words = info[:memory] || 0
        wordsize = :erlang.system_info(:wordsize)
        mem_mb = Float.round(memory_words * wordsize / 1_048_576, 2)
        {name, size, mem_mb}
      end)
      |> Enum.sort_by(fn {_name, _size, mem_mb} -> -mem_mb end)
      |> Enum.take(n)

    Logger.info("[mem] top ets tables: #{inspect(tables, pretty: true, limit: :infinity)}")
    tables
  end

  # ---- biggest processes (for when process heaps are the problem) ----
  def top_processes(n \\ 20) do
    procs =
      :erlang.processes()
      |> Enum.map(fn pid ->
        case :erlang.process_info(pid, [:memory, :current_function, :registered_name]) do
          :undefined -> nil
          info ->
            mem = Keyword.fetch!(info, :memory)
            {pid, mem, info}
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(fn {_pid, mem, _info} -> -mem end)
      |> Enum.take(n)

    pretty =
      Enum.map(procs, fn {pid, mem, info} ->
        name = Keyword.get(info, :registered_name, :undefined)
        fun  = Keyword.get(info, :current_function)
        {pid, Float.round(mem / 1_048_576, 2), name, fun}
      end)

    Logger.info("[mem] top processes: #{inspect(pretty, pretty: true, limit: :infinity)}")
    pretty
  end
end
