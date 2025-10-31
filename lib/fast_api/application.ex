defmodule FastApi.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # HTTP endpoint
      FastApiWeb.Endpoint,

      # Lightweight local processes
      {PlugAttack.Storage.Ets, name: FastApi.PlugAttack.Storage, clean_period: 60_000},
      {Task.Supervisor, name: FastApi.TaskSup},
      {Phoenix.PubSub, name: FastApi.PubSub},
      FastApiWeb.Telemetry,

      # Core infra
      FastApi.Repo,

      # Finch HTTP clients
      {Finch, name: FastApi.Finch, pools: %{
        default: [size: 16, count: 1]
      }},
      {Finch, name: FastApi.FinchHealth, pools: %{
        default: [size: 6, count: 1]
      }},

      # App-level background processes
      FastApi.Health.Server,
      FastApi.Health.Gw2Server,
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
