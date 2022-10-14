defmodule FastApiWeb.Router do
  use FastApiWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, {FastApiWeb.LayoutView, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

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

    get "/:module", FeatureController, :get_module
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

  # Enables the Swoosh mailbox preview in development.
  #
  # Note that preview only shows emails that were sent by the same
  # node running the Phoenix server.
  if Mix.env() == :dev do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
