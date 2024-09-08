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

  pipeline :throttle do
    plug FastApi.PlugAttack
  end

  pipeline :secured do
    plug FastApi.Auth.Pipeline
  end

  scope "/api/v1/auth", FastApiWeb do
    pipe_through [:api, :throttle]

    post "/login", UserController, :login
    post "/pre-register", UserController, :pre_register
    post "/refresh", UserController, :refresh
    post "/register", UserController, :register

    pipe_through :secured
    post "/change-password", UserController, :change_password
  end

  scope "/api/v1", FastApiWeb do
    pipe_through :secured

    get "/about", ContentController, :index
    get "/builds", ContentController, :builds
    get "/changelog", ContentController, :changelog
    get "/content-updates", ContentController, :content_updates
    get "/contributors", ContentController, :contributors
    get "/guides", ContentController, :guides

    get "/metadata", MetaController, :index
    get "/metadata/indexes", MetaController, :index

    get "/details/:module/:collection/:item", DetailController, :get_item_page
    get "/:module/:collection", FeatureController, :get_page
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
