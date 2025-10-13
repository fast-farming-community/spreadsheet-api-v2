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
    plug :accepts, ["json", "event-stream"]
  end

  pipeline :secured do
    plug FastApi.Auth.Pipeline
    plug Guardian.Plug.LoadResource, allow_blank: false
    plug FastApiWeb.Plugs.AssignTier
  end

  pipeline :optional_auth do
    plug FastApiWeb.Plugs.OptionalAuth
  end

  scope "/api/v1/auth", FastApiWeb do
    pipe_through [:api]
    post "/login", UserController, :login
    post "/pre-register", UserController, :pre_register
    post "/refresh", UserController, :refresh
    post "/register", UserController, :register

    pipe_through :secured
    post "/change-password", UserController, :change_password
    get  "/me", UserController, :me
    post "/profile", UserController, :update_profile
  end

  scope "/api/v1/tracker", FastApiWeb do
    pipe_through [:api]

    post "/validate-key",           TrackerController, :validate_key
    post "/characters",             TrackerController, :characters
    post "/characters/inventory",   TrackerController, :character_inventory
    post "/characters/inventories", TrackerController, :characters_inventories
    post "/account/info",           TrackerController, :account
    post "/account/bank",           TrackerController, :account_bank
    post "/account/materials",      TrackerController, :account_materials
    post "/account/inventory",      TrackerController, :account_inventory
    post "/account/wallet",         TrackerController, :account_wallet
    post "/items",                  TrackerController, :items
    post "/prices",                 TrackerController, :prices
    post "/currencies",             TrackerController, :currencies
  end

  scope "/api/v1", FastApiWeb do
    pipe_through [:api, :optional_auth]

    get "/about", ContentController, :index
    get "/builds", ContentController, :builds
    get "/changelog", ContentController, :changelog
    get "/website-content-updates", ContentController, :content_updates
    get "/website-todos", ContentController, :todos
    get "/guides", ContentController, :guides
    get "/health", HealthController, :show
    get "/health/stream", HealthController, :stream
    get "/health-gw2/:endpoint", HealthGw2Controller, :show
    get "/health-gw2/:endpoint/stream", HealthGw2Controller, :stream
    get "/metadata", MetaController, :index
    get "/search", SearchController, :search
    get "/details/:module/:collection/:item", DetailController, :get_item_page
    get "/:module/:collection", FeatureController, :get_page
  end

  if Mix.env() == :dev do
    scope "/dev" do
      pipe_through :browser
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
