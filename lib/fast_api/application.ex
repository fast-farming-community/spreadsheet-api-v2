defmodule FastApi.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Goth, name: FastApi.Goth, source: {
          :default,
          scopes: ["https://www.googleapis.com/auth/spreadsheets"]
       }},
      {Finch, name: FastApi.Finch},
      FastApi.Repo,
      FastApi.Scheduler,
      # Start the Telemetry supervisor
      FastApiWeb.Telemetry,
      # Start the PubSub system
      # {Phoenix.PubSub, name: FastApi.PubSub},
      # Start the Endpoint (http/https)
      FastApiWeb.Endpoint
      # Start a worker by calling: FastApi.Worker.start_link(arg)
      # {FastApi.Worker, arg}
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
