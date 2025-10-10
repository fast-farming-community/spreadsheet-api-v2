defmodule FastApi.Health.Gw2Server do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def get(key), do: GenServer.call(__MODULE__, {:get, key})

  @impl true
  def init(:ok) do
    cfg = Application.get_env(:fast_api, __MODULE__, [])
    endpoints = cfg[:endpoints] || %{
      items: "/v2/items",
      currencies: "/v2/currencies",
      commerce_listings: "/v2/commerce/listings",
      commerce_prices: "/v2/commerce/prices",
      exchange_gems: "/v2/commerce/exchange/gems"
    }

    state = %{
      cfg: %{
        base_url: cfg[:base_url] || "https://api.guildwars2.com",
        endpoints: endpoints,
        interval_ms: cfg[:interval_ms] || 30_000,
        request_timeout_ms: cfg[:request_timeout_ms] || 6_000,
        stale_after_ms: cfg[:stale_after_ms] || 90_000
      },
      probes:
        endpoints
        |> Map.keys()
        |> Enum.into(%{}, fn k -> {k, %{up: false, since: nil, updated_at: now(), reason: "init", last_ok_at: nil}} end)
    }

    Process.send_after(self(), :probe, 0)
    {:ok, state}
  end

  @impl true
  def handle_call({:get, key}, _from, s) do
    probe = s.probes[key] || %{}
    resp = Map.take(probe, [:up, :since, :updated_at, :reason])
    {:reply, resp, s}
  end

  @impl true
  def handle_info(:probe, s) do
    {probes2, broadcasts} =
      Enum.reduce(s.cfg.endpoints, {s.probes, []}, fn {key, path}, {acc, bcasts} ->
        prev = acc[key]
        case do_probe(s.cfg.base_url <> path, s.cfg.request_timeout_ms) do
          :ok ->
            since = if prev.up == false, do: now(), else: (prev.since || now())
            cur = %{prev | up: true, since: since, updated_at: now(), reason: nil, last_ok_at: now()}
            {Map.put(acc, key, cur), [{key, to_public(cur)} | bcasts]}
          {:error, reason} ->
            staleness = if prev.last_ok_at, do: now() - prev.last_ok_at, else: s.cfg.stale_after_ms + 1
            cur =
              if staleness > s.cfg.stale_after_ms do
                %{prev | up: false, updated_at: now(), reason: to_string(reason)}
              else
                %{prev | updated_at: now()}
              end
            {Map.put(acc, key, cur), [{key, to_public(cur)} | bcasts]}
        end
      end)

    Enum.each(broadcasts, fn {key, payload} ->
      Phoenix.PubSub.broadcast(FastApi.PubSub, topic(key), {:health, payload})
    end)

    Process.send_after(self(), :probe, s.cfg.interval_ms)
    {:noreply, %{s | probes: probes2}}
  end

  defp do_probe(url, tmo) do
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

  defp topic(key), do: "health:gw2:" <> to_string(key)
  defp now(), do: System.system_time(:second)
  defp to_public(%{up: up, since: since, updated_at: updated_at, reason: reason}), do: %{up: up, since: since, updated_at: updated_at, reason: reason}
end
