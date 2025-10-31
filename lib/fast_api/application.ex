defmodule FastApi.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # ─────────────────────────────────────────────────────────────────────────
      # HTTP endpoint
      # ─────────────────────────────────────────────────────────────────────────
      FastApiWeb.Endpoint,

      # ─────────────────────────────────────────────────────────────────────────
      # Lightweight local processes
      # ─────────────────────────────────────────────────────────────────────────
      {PlugAttack.Storage.Ets, name: FastApi.PlugAttack.Storage, clean_period: 60_000},

      # Bounded-concurrency fan-out uses Task.Supervisor
      {Task.Supervisor, name: FastApi.TaskSup},

      # PubSub for health broadcasts (SSE)
      {Phoenix.PubSub, name: FastApi.PubSub},

      # Telemetry (metrics hooks)
      FastApiWeb.Telemetry,

      # ─────────────────────────────────────────────────────────────────────────
      # Core infra
      # ─────────────────────────────────────────────────────────────────────────
      # DB connection pool
      FastApi.Repo,

      # Finch HTTP client for outbound calls (isolated pools)
      {Finch, name: FastApi.Finch, pools: %{
        default:    [size: 16, count: 1],
        gw2_health: [size: 6,  count: 1]
      }},

      # ─────────────────────────────────────────────────────────────────────────
      # App-level background processes
      # ─────────────────────────────────────────────────────────────────────────
      # Backend health state
      FastApi.Health.Server,
      FastApi.Health.Gw2Server,

      # Scheduler
      FastApi.Scheduler,

      # Google token fetcher
      {Goth,
       name: FastApi.Goth,
       source: {
         :default,
         scopes: ["https://www.googleapis.com/auth/spreadsheets"]
       }}
    ]

    opts = [strategy: :one_for_one, name: FastApi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    FastApiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
