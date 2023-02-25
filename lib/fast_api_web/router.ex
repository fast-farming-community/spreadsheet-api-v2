defmodule FastApiWeb.Router do
  use FastApiWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/v1", FastApiWeb do
    pipe_through :api

    get "/about", ContentController, :index
    get "/builds", ContentController, :builds
    get "/contributors", ContentController, :contributors
    get "/guides", ContentController, :guides

    get "/metadata", MetaController, :index
    get "/metadata/indexes", MetaController, :index

    get "/details/:category/:item", DetailController, :index
    get "/details/:module/:collection/:item", DetailController, :get_item_page

    get "/:module", FeatureController, :get_module
    get "/:module/:collection", FeatureController, :get_page
    get "/:module/:collection/:item", FeatureController, :get_item
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
