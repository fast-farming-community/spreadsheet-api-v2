defmodule FastApi.Health.Gw2Server do
  @moduledoc false
  use GenServer

  @topic "health:gw2"

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def get(), do: GenServer.call(__MODULE__, :get)

  @impl true
  def init(:ok) do
    cfg = Application.get_env(:fast_api, __MODULE__, [])
    state = %{
      up: false,
      since: nil,
      updated_at: now(),
      reason: "init",
      cfg: %{
        base_url: cfg[:base_url] || "https://api.guildwars2.com",
        probe_path: cfg[:probe_path] || "/v2/build",
        interval_ms: cfg[:interval_ms] || 30_000,
        request_timeout_ms: cfg[:request_timeout_ms] || 6_000,
        stale_after_ms: cfg[:stale_after_ms] || 90_000
      },
      last_ok_at: nil
    }

    Process.send_after(self(), :probe, 0)
    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, s), do: {:reply, Map.drop(s, [:cfg]), s}

  @impl true
  def handle_info(:probe, s) do
    s2 =
      case do_probe(s.cfg) do
        :ok ->
          s
          |> put_new_state(true, nil)
          |> Map.put(:last_ok_at, now())
        {:error, reason} ->
          staleness = if s.last_ok_at, do: now() - s.last_ok_at, else: s.cfg.stale_after_ms + 1
          if staleness > s.cfg.stale_after_ms do
            put_new_state(s, false, reason)
          else
            put_updated_at(s)
          end
      end

    Phoenix.PubSub.broadcast(FastApi.PubSub, @topic, {:health, to_public(s2)})

    Process.send_after(self(), :probe, s2.cfg.interval_ms)
    {:noreply, s2}
  end

  defp do_probe(%{base_url: base, probe_path: path, request_timeout_ms: tmo}) do
    url = base <> path
    req = Finch.build(:get, url, [{"user-agent", "fast-api-health/1.0"}])

    try do
      case Finch.request(req, FastApi.Finch, receive_timeout: tmo) do
        {:ok, %Finch.Response{status: code}} when code in 200..299 -> :ok
        {:ok, %Finch.Response{status: code}} -> {:error, "http_#{code}"}
        {:error, %Mint.TransportError{reason: r}} -> {:error, "transport_#{inspect(r)}"}
        {:error, other} -> {:error, "error_#{inspect(other)}"}
      end
    rescue
      e -> {:error, "exception_#{Exception.message(e)}"}
    end
  end

  defp put_new_state(s, up, reason) do
    since = if up and (s.up == false), do: now(), else: (s.since || now())
    %{s | up: up, reason: reason, since: since, updated_at: now()}
  end

  defp put_updated_at(s), do: %{s | updated_at: now()}
  defp now(), do: System.system_time(:second)

  defp to_public(%{up: up, since: since, updated_at: updated_at, reason: reason}) do
    %{up: up, since: since, updated_at: updated_at, reason: reason}
  end
end
