defmodule FastApi.Health.Gw2Server do
  @moduledoc false
  use GenServer

  @typedoc "internal probe record"
  @type probe_t :: %{
          up: boolean(),
          since: integer() | nil,
          updated_at: integer() | nil,
          reason: String.t() | nil,
          last_ok_at: integer() | nil
        }

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def get(key), do: GenServer.call(__MODULE__, {:get, key})

  @impl true
  def init(:ok) do
    cfg = Application.get_env(:fast_api, __MODULE__, [])

    endpoints =
      cfg[:endpoints] ||
        %{
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
        request_timeout_ms: cfg[:request_timeout_ms] || 3_000,   # ↓ was 6_000
        stale_after_ms: cfg[:stale_after_ms] || 90_000,
        probe_grace_ms: cfg[:probe_grace_ms] || 1_000            # extra over request_timeout_ms
      },
      probes:
        Map.new(endpoints, fn {k, _} ->
          {k, %{up: false, since: nil, updated_at: now(), reason: "init", last_ok_at: nil}}
        end),
      pending: %{} # key => started_at
    }

    Process.send_after(self(), :probe, 0)
    {:ok, state}
  end

  @impl true
  def handle_call({:get, :global}, _from, s) do
    {:reply, global_state(s.probes), s}
  end

  @impl true
  def handle_call({:get, key}, _from, s) do
    probe = s.probes[key] || %{}
    {:reply, Map.take(probe, [:up, :since, :updated_at, :reason]), s}
  end

  # Kick off async probes; never block here
  @impl true
  def handle_info(:probe, s) do
    started_at = now()

    s.cfg.endpoints
    |> Enum.each(fn {key, path} ->
      # mark as pending
      send(self(), {:probe_start, key, started_at})

      # spawn unlinked, very cheap process to do IO
      _pid =
        spawn(fn ->
          result = do_probe(s.cfg.base_url <> path, s.cfg.request_timeout_ms)
          send(self(), {:probe_result, key, result, started_at})
        end)

      # fallback timeout to unstick pending
      Process.send_after(
        self(),
        {:probe_timeout, key, started_at},
        s.cfg.request_timeout_ms + s.cfg.probe_grace_ms
      )
    end)

    # schedule next sweep regardless of how long the above take
    Process.send_after(self(), :probe, s.cfg.interval_ms)
    {:noreply, s}
  end

  # mark pending
  @impl true
  def handle_info({:probe_start, key, started_at}, s) do
    {:noreply, put_in(s.pending[key], started_at)}
  end

  # normal completion
  @impl true
  def handle_info({:probe_result, key, result, started_at}, s) do
    # ignore late/stale result from a previous cycle
    s =
      case s.pending[key] do
        ^started_at -> update_probe(s, key, result)
        _other -> s
      end

    {:noreply, %{s | pending: Map.delete(s.pending, key)}}
  end

  # deadline hit → mark as temporarily degraded
  @impl true
  def handle_info({:probe_timeout, key, started_at}, s) do
    s =
      case s.pending[key] do
        ^started_at ->
          prev = s.probes[key]
          staleness =
            if prev.last_ok_at, do: now() - prev.last_ok_at, else: s.cfg.stale_after_ms + 1

          cur =
            if staleness > s.cfg.stale_after_ms do
              %{prev | up: false, updated_at: now(), reason: "timeout"}
            else
              %{prev | updated_at: now()}
            end

          broadcast(key, cur, s.probes)
          put_in(%{s | probes: Map.put(s.probes, key, cur)}, [:pending, key], nil)

        _other ->
          s
      end

    {:noreply, s}
  end

  defp update_probe(s, key, result) do
    prev = s.probes[key] || %{}
    {cur, bcast?} =
      case result do
        :ok ->
          since = if prev.up == false, do: now(), else: (prev.since || now())
          cur = %{prev | up: true, since: since, updated_at: now(), reason: nil, last_ok_at: now()}
          {cur, true}

        :maintenance ->
          cur = %{prev | up: false, since: prev.since || now(), updated_at: now(), reason: "maintenance"}
          {cur, true}

        {:error, reason} ->
          staleness =
            if prev.last_ok_at, do: now() - prev.last_ok_at, else: s.cfg.stale_after_ms + 1

          cur =
            if staleness > s.cfg.stale_after_ms do
              %{prev | up: false, updated_at: now(), reason: to_string(reason)}
            else
              %{prev | updated_at: now()}
            end

          {cur, true}
      end

    probes2 = Map.put(s.probes, key, cur)
    if bcast?, do: broadcast(key, cur, probes2)
    %{s | probes: probes2}
  end

  defp broadcast(key, probe, probes) do
    Phoenix.PubSub.broadcast(FastApi.PubSub, topic(key), {:health, to_public(probe)})
    Phoenix.PubSub.broadcast(FastApi.PubSub, topic(:global), {:health, global_state(probes)})
  end

  defp do_probe(url, tmo) do
    req = Finch.build(:get, url, [{"user-agent", "fast-api-health/1.0"}])

    try do
      # isolate via dedicated pool
      case Finch.request(req, FastApi.Finch, pool: :gw2_health, receive_timeout: tmo) do
        {:ok, %Finch.Response{status: 503, body: body}} when is_binary(body) ->
          if maintenance_html?(body), do: :maintenance, else: {:error, "http_503"}

        {:ok, %Finch.Response{status: code}} when code in 200..299 ->
          :ok

        {:ok, %Finch.Response{status: code}} ->
          {:error, "http_#{code}"}

        {:error, %Mint.TransportError{reason: r}} ->
          {:error, "transport_#{inspect(r)}"}

        {:error, other} ->
          {:error, "error_#{inspect(other)}"}
      end
    rescue
      e -> {:error, "exception_#{Exception.message(e)}"}
    end
  end

  defp maintenance_html?(body) do
    String.contains?(body, "API Temporarily disabled") or
      String.contains?(body, "Scheduled reactivation")
  end

  defp global_state(probes) do
    list = Map.values(probes)
    any_maint? = Enum.any?(list, &(&1.reason == "maintenance"))

    up =
      if any_maint?, do: false, else: Enum.all?(list, &(&1.up == true))

    since =
      if any_maint? do
        list
        |> Enum.filter(&(&1.reason == "maintenance"))
        |> Enum.map(&(&1.since || now()))
        |> Enum.min(fn -> nil end)
      else
        case Enum.find(list, &(&1.up == false and &1.reason)) do
          nil -> Enum.min(Enum.map(list, &(&1.since || now())), fn -> nil end)
          _ -> nil
        end
      end

    updated_at = Enum.max(Enum.map(list, &(&1.updated_at || now())), fn -> now() end)
    reason = if any_maint?, do: "maintenance", else: nil
    %{up: up, since: since, updated_at: updated_at, reason: reason}
  end

  defp topic(key), do: "health:gw2:" <> to_string(key)
  defp now(), do: System.system_time(:second)
  defp to_public(%{up: up, since: since, updated_at: updated_at, reason: reason}),
    do: %{up: up, since: since, updated_at: updated_at, reason: reason}
end
