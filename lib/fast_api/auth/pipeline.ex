defmodule FastApi.Auth.Pipeline do
  use Guardian.Plug.Pipeline,
    otp_app: :fast_api,
    error_handler: FastApi.Auth.ErrorHandler,
    module: FastApi.Auth.Token

  plug Guardian.Plug.VerifyHeader, claims: %{"typ" => "access"}
end
