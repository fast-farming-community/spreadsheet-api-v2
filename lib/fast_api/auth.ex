defmodule FastApi.Auth do
  alias FastApi.Repo
  alias FastApi.Schemas.Auth.{Role, User}

  def get_user!(id), do: Repo.get!(User, id)
  def get_user_by_email(email), do: Repo.get_by(User, email: email)

  def get_user_role(%User{} = user) do
    %User{role: %Role{name: name}} = Repo.preload(user, :role)
    name
  end

  def init_user(params), do: %User{} |> User.changeset(params, :init) |> Repo.insert()

  def create_user(%{"email" => email, "token" => token} = params) when token != "" do
    case Repo.get_by(User, email: email, token: token, verified: false) do
      nil ->
        {:error, :invalid_token}

      user ->
        user
        |> User.changeset(params, :create)
        |> Repo.update()
    end
  end

  # TODO: Better error handling?
  def create_user(_) do
    {:error, :invalid_token}
  end

  def change_password(%User{} = user, params) do
    user |> User.changeset(params, :update) |> Repo.update()
  end
end
