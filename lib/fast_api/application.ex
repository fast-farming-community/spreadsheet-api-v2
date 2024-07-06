defmodule FastApi.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Goth, name: FastApi.Goth},
      {Finch, name: FastApi.Finch},
      FastApi.Repos.Fast,
      FastApi.Scheduler,
      # Start the Telemetry supervisor
      FastApiWeb.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: FastApi.PubSub},
      # Start the Endpoint (http/https)
      FastApiWeb.Endpoint
      # Start a worker by calling: FastApi.Worker.start_link(arg)
      # {FastApi.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FastApi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp prod_only_processes(true), do: []
  defp prod_only_processes(_), do: []

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FastApiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
