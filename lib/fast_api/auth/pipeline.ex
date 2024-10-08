defmodule FastApi.Auth.Pipeline do
  @moduledoc "Authentication pipeline."
  use Guardian.Plug.Pipeline,
    otp_app: :fast_api,
    error_handler: FastApi.Auth.ErrorHandler,
    module: FastApi.Auth.Token

  plug Guardian.Plug.VerifyHeader, claims: %{"iss" => "fast_api", "typ" => "access"}
end
