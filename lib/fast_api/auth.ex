defmodule FastApi.Auth do
  @moduledoc "Authentication helper functions."
  alias FastApi.Repo
  alias FastApi.Schemas.Auth.{Role, User}

  import Ecto.Query

  def all_users(), do: Repo.all(from u in User, where: u.verified == true)

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

  def create_user(_) do
    {:error, :invalid_token}
  end

  def change_password(%User{} = user, params) do
    user |> User.changeset(params, :update) |> Repo.update()
  end

  def set_role(%User{} = user, role) do
    user |> Repo.preload(:role) |> User.changeset(role, :role) |> Repo.update()
  end

  def update_profile(%User{} = user, params) do
    user |> User.changeset(params, :profile) |> Repo.update()
  end

  def delete_unverified() do
    Repo.delete_all(
      from u in User,
        where: u.verified == false and u.inserted_at < ago(2, "hour")
    )
  end
end
