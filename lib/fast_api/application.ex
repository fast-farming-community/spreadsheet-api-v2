defmodule FastApi.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Goth,
       name: FastApi.Goth,
       source: {
         :default,
         scopes: ["https://www.googleapis.com/auth/spreadsheets"]
       }},
      {PlugAttack.Storage.Ets, name: FastApi.PlugAttack.Storage, clean_period: 60_000},

      # Finch HTTP client for outbound calls (GW2 API etc.)
      # You can tune pool size if you expect higher concurrency.
      {Finch, name: FastApi.Finch, pools: %{default: [size: 10]}},

      FastApi.Repo,
      FastApi.Scheduler,
      FastApiWeb.Telemetry,
      FastApiWeb.Endpoint
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
