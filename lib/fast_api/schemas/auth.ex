defmodule FastApi.Schemas.Auth do
  @moduledoc """
  Schemas for user authentication and authorization
  """

  defmodule User do
    use Ecto.Schema
    import Ecto.Changeset
    import Bcrypt

    schema "users" do
      field :email, :string
      field :password, :string
      field :token, :string

      timestamps()
    end

    def changeset(user, params) do
      user
      |> cast(params, [:email, :password, :token])
      |> validate_required([:email, :username])
      |> validate_email()
      |> put_hash()
    end

    defp validate_email(%Ecto.Changeset{valid?: true, changes: %{email: email}} = changeset) do
      changeset
      |> validate_format(:email, ~r/^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$/,
        message: "must be a valid email address"
      )
      |> change(add_hash(email, hash_key: :email_hash))
      |> unique_constraint(:users_unique_id)
    end

    defp put_hash(%Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset) do
      change(changeset, add_hash(password, hash_key: :password_hash))
    end

    defp put_hash(changeset), do: changeset
  end
end
