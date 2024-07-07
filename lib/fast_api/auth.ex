defmodule FastApi.Auth do
  alias FastApi.Repo
  alias FastApi.Schemas.Auth.User

  def get_user!(id), do: Repo.get!(User, id)

  def get_user_by_email(email), do: Repo.get_by(User, email: email)

  def create_user(params), do: %User{} |> User.changeset(params) |> Repo.insert()
  def update_user(params), do: %User{} |> User.changeset(params) |> Repo.update()
end
