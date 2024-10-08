defmodule FastApiWeb.Notifiers.PreRegistrationNotifier do
  @moduledoc "Email template for user pre-registration."
  use Phoenix.Swoosh,
    template_root: "lib/fast_api_web/templates",
    template_path: "email"

  alias FastApi.Schemas.Auth.User

  def pre_register(%User{} = user) do
    new()
    |> to(user.email)
    |> from({"[fast] Farming Community", "no-reply@johnson.uberspace.de"})
    |> subject("[fast] Farming Community Account Registration")
    |> render_body("pre_registration.html", %{user: user})
  end
end
