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
      field :password_confirmation, :string, virtual: true
      field :old_password, :string, virtual: true
      has_one :role, FastApi.Schemas.Auth.Role
      field :token, :string

      timestamps()
    end

    def changeset(user, params, :insert) do
      user
      |> cast(params, [:email, :password, :password_confirmation])
      |> validate_required([:email, :password])
      |> validate_email()
      |> validate_password()
      |> put_hash()
    end

    def changeset(user, params, :update) do
      user
      |> cast(params, [:old_password, :password, :password_confirmation])
      |> delete_change(:email)
      |> validate_required([:email, :old_password, :password])
      |> validate_email()
      |> validate_password()
      |> put_hash()
    end

    defp validate_email(%Ecto.Changeset{} = changeset) do
      changeset
      |> validate_format(:email, ~r/^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$/,
        message: "Must be a valid email address"
      )
      |> unique_constraint(:email, name: :users_unique_id)
    end

    defp validate_password(%Ecto.Changeset{} = changeset) do
      changeset
      |> validate_length(:password, min: 12)
      |> validate_format(:password, ~r/[0-9]+/, message: "Password must contain a number")
      |> validate_format(:password, ~r/[A-Z]+/,
        message: "Password must contain an upper-case letter"
      )
      |> validate_format(:password, ~r/[a-z]+/,
        message: "Password must contain a lower-case letter"
      )
      |> validate_format(:password, ~r/[#\!\?&@\$%^&*\(\)]+/,
        message: "Password must contain a symbol"
      )
      |> validate_confirmation(:password, required: true)
    end

    defp put_hash(%Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset) do
      change(changeset, password: hash_pwd_salt(password))
    end

    defp put_hash(changeset), do: changeset
  end
end
