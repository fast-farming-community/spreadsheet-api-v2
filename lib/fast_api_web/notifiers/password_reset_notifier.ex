defmodule FastApiWeb.Notifiers.PasswordResetNotifier do
  use Phoenix.Swoosh,
    template_root: "lib/fast_api_web/templates",
    template_path: "email"

  alias Swoosh.Email
  alias FastApi.Schemas.Auth.User

  def reset_request(%User{} = user, plain_token) do
    base = Application.get_env(:fast_api, :frontend_base_url)
    reset_url = "#{base}/auth/reset-password?token=#{plain_token}"

    new()
    |> to(user.email)
    |> from({"[fast] Farming Community", "no-reply@johnson.uberspace.de"})
    |> subject("[fast] Reset your password")
    |> render_body("password_reset.html", %{
      user: user,
      reset_url: reset_url
    })
  end
end
