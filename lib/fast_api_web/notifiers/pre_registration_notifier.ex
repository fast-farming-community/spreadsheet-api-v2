defmodule FastApiWeb.Notifiers.PreRegistrationNotifier do
  use Phoenix.Swoosh,
    template_root: "lib/fast_api_web/templates",
    template_path: "email"

  alias FastApi.Schemas.Auth.User

  def pre_register(%User{} = user) do
    new()
    |> to(user.email)
    |> from({"[fast] Farming Community", "no-reply@fast.farming-community.eu"})
    |> subject("[fast] Farming Community Account Registration")
    |> render_body("pre_registration.html", %{user: user})
  end
end
