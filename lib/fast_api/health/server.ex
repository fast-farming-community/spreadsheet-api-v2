defmodule FastApi.Health.Server do
  @moduledoc false
  use GenServer

  @topic "health"
  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def get(), do: GenServer.call(__MODULE__, :get)
  def set_up(), do: GenServer.cast(__MODULE__, {:set, %{up: true, reason: nil}})
  def set_down(reason \\ "unknown"), do: GenServer.cast(__MODULE__, {:set, %{up: false, reason: to_string(reason)}})

  @impl true
  def init(:ok) do
    state = %{up: true, since: System.system_time(:second), updated_at: System.system_time(:second), reason: nil}
    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast({:set, %{up: up, reason: reason}}, state) do
    new_state =
      %{up: up, reason: reason, since: (state.since || System.system_time(:second))}
      |> then(fn s ->
        s = if up and state.up == false, do: %{s | since: System.system_time(:second)}, else: s
        Map.put(s, :updated_at, System.system_time(:second))
      end)

    Phoenix.PubSub.broadcast(FastApi.PubSub, @topic, {:health, new_state})
    {:noreply, new_state}
  end
end
