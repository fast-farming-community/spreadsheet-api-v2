defmodule FastApi.Schemas.Auth do
  @moduledoc """
  Schemas for user authentication and authorization
  """

  defmodule Role do
    use Ecto.Schema

    schema "roles" do
      field :role, :string

      timestamps()
    end
  end

  defmodule User do
    use Ecto.Schema
    import Ecto.Changeset
    import Bcrypt

    schema "users" do
      field :email, :string
      field :password, :string
      has_one :role, FastApi.Schemas.Auth.Role
      field :token, :string

      timestamps()
    end

    def changeset(user, params) do
      user
      |> cast(params, [:email, :password, :token])
      |> validate_required([:email, :password])
      |> validate_email()
      |> put_hash()
    end

    defp validate_email(%Ecto.Changeset{valid?: true} = changeset) do
      changeset
      |> validate_format(:email, ~r/^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$/,
        message: "must be a valid email address"
      )
      |> unique_constraint(:users_unique_id)
    end

    defp put_hash(%Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset) do
      change(changeset, password: hash_pwd_salt(password))
    end

    defp put_hash(changeset), do: changeset
  end
end
