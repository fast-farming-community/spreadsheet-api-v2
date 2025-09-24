defmodule FastApi.Auth.Pipeline do
  @moduledoc "Authentication pipeline."
  use Guardian.Plug.Pipeline,
    otp_app: :fast_api,
    error_handler: FastApi.Auth.ErrorHandler,
    module: FastApi.Auth.Token

  plug Guardian.Plug.VerifyHeader,
    scheme: "Bearer",
    claims: %{"iss" => "fast_api", "typ" => "access"}

  plug Guardian.Plug.EnsureAuthenticated

  plug Guardian.Plug.LoadResource, allow_blank: false
end
