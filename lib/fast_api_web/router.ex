defmodule FastApiWeb.Router do
  use FastApiWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :cms do
    plug :add_authorization_header
  end

  scope "/api/v1/cms" do
    pipe_through :cms

    forward "/", ReverseProxyPlug, upstream: Application.fetch_env!(:fast_api, :cockpit_url)
  end

  scope "/api/v1", FastApiWeb do
    pipe_through :api

    get "/metadata", MetaController, :index
    get "/metadata/indexes", MetaController, :index

    get "/details/:category/:item", DetailController, :index
    get "/details/:module/:collection/:item", DetailController, :get_item_page

    get "/:module/:collection", FeatureController, :get_page
    get "/:module/:collection/:item", FeatureController, :get_item
  end

  defp add_authorization_header(conn, _) do
    Plug.Conn.put_req_header(
      conn,
      "Authorization",
      "Bearer #{Application.fetch_env!(:fast_api, :cockpit_token)}"
    )
  end

  # Enables LiveDashboard only for development
  #
  # If you want to use the LiveDashboard in production, you should put
  # it behind authentication and allow only admins to access it.
  # If your application does not have an admins-only section yet,
  # you can use Plug.BasicAuth to set up some basic authentication
  # as long as you are also using SSL (which you should anyway).
  if Mix.env() in [:dev, :test] do
    import Phoenix.LiveDashboard.Router

    scope "/" do
      pipe_through [:fetch_session, :protect_from_forgery]
      live_dashboard "/dashboard", metrics: FastApiWeb.Telemetry
    end
  end

  # Enables the Swoosh mailbox preview in development.
  #
  # Note that preview only shows emails that were sent by the same
  # node running the Phoenix server.
  if Mix.env() == :dev do
    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
