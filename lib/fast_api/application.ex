defmodule FastApi.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FastApiWeb.Endpoint,
      {PlugAttack.Storage.Ets, name: FastApi.PlugAttack.Storage, clean_period: 60_000},
      {Task.Supervisor, name: FastApi.TaskSup},
      {Phoenix.PubSub, name: FastApi.PubSub},
      FastApiWeb.Telemetry,
      FastApi.Repo,

      # Finch pools
      {Finch, name: FastApi.FinchPublic, pools: %{default: [size: 24, count: 2]}},
      {Finch, name: FastApi.FinchJobs,   pools: %{default: [size: 8,  count: 1]}},
      {Finch, name: FastApi.FinchHealth, pools: %{default: [size: 6,  count: 1]}},

      FastApi.Health.Server,
      FastApi.Health.Gw2Server,
      FastApi.Scheduler,

      {Goth,
       name: FastApi.Goth,
       source: {:default, scopes: ["https://www.googleapis.com/auth/spreadsheets"]}}
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
