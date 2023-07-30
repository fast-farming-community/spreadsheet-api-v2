defmodule FastApi.Auth do
  import Bcrypt

  alias FastApi.Repo
  alias FastApi.Schemas.Auth.User

  def get_user!(id), do: Repo.get!(User, id)

  def get_user_by_email(email),
    do: Repo.get_by(User, email: add_hash(email, hash_key: :email_hash))

  def create_user(params), do: %User{} |> User.changeset(params) |> Repo.insert()
end
