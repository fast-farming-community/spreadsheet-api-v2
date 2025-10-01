defmodule FastApi.Schemas.Auth do
  @moduledoc "Schemas for user authentication and authorization."

  defmodule Role do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:name, :string, []}
    schema "roles" do
      timestamps()
    end
  end

  defmodule User do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset
    import Bcrypt

    schema "users" do
      field :email, :string
      field :password, :string
      field :password_confirmation, :string, virtual: true
      belongs_to :role, FastApi.Schemas.Auth.Role, references: :name, type: :string
      field :token, :string, default: Ecto.UUID.generate()
      field :verified, :boolean, default: false

      field :api_keys, :map, default: %{}
      field :ingame_name, :string

      timestamps()
    end

    def changeset(user, params, :init) do
      user
      |> cast(params, [:email])
      |> put_change(:role_id, "free")
      |> validate_required([:email])
      |> validate_email()
    end

    def changeset(user, params, :create) do
      user
      |> cast(params, [:email, :password, :password_confirmation])
      |> put_change(:token, "")
      |> put_change(:verified, true)
      |> validate_required([:email, :password])
      |> validate_email()
      |> validate_password()
      |> put_hash()
    end

    def changeset(user, params, :update) do
      user
      |> cast(params, [:password, :password_confirmation])
      |> delete_change(:email)
      |> validate_required([:email, :password])
      |> validate_email()
      |> validate_password()
      |> put_hash()
    end

    def changeset(user, params, :profile) do
      user
      |> cast(params, [:api_keys, :ingame_name])
      |> validate_api_keys()
    end

    def changeset(user, role, :role) do
      user
      |> cast(%{}, [])
      |> put_change(:role_id, role)
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

    defp validate_api_keys(%Ecto.Changeset{} = changeset) do
      validate_change(changeset, :api_keys, fn :api_keys, value ->
        cond do
          value == nil ->
            []

          is_map(value) ->
            regex = ~r/^[A-Za-z0-9-]{20,128}$/

            invalid =
              Enum.filter(value, fn
                {_k, v} when is_binary(v) ->
                  not Regex.match?(regex, v)
                _ ->
                  true
              end)

            if invalid == [] do
              []
            else
              [{:api_keys, "All API keys must be strings that look like valid keys"}]
            end

          true ->
            [{:api_keys, "must be a map of strings"}]
        end
      end)
    end

    defp put_hash(%Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset) do
      change(changeset, password: hash_pwd_salt(password))
    end

    defp put_hash(changeset), do: changeset
  end
end
