defmodule FastApi.Auth do
  @moduledoc "Authentication helper functions."
  alias FastApi.Repo
  alias FastApi.Schemas.Auth.{Role, User}
  alias FastApi.GW2.Client, as: GW2

  import Ecto.Query

  @required_scope "account"

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

  @doc """
  Update profile. If `api_keys` are provided and non-empty, require a key with the
  `account` scope and overwrite `ingame_name` from `/v2/account`. Otherwise behave
  like a normal profile update.
  Returns:
    - {:ok, %User{}}
    - {:error, :unprocessable_entity, reason}
    - {:error, %Ecto.Changeset{}}
  """
  def update_profile(%User{} = user, params) when is_map(params) do
    params =
      case Map.get(params, "api_keys") do
        m when is_map(m) and map_size(m) > 0 ->
          keys =
            m
            |> Map.values()
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          case first_key_with_account(keys) do
            nil ->
              throw({:unprocessable_entity, "API key missing 'account' permission or invalid; cannot read in-game name."})

            key ->
              case GW2.account(key) do
                {:ok, %{"name" => ign}} when is_binary(ign) and ign != "" ->
                  Map.put(params, "ingame_name", ign)

                _ ->
                  throw({:unprocessable_entity, "Could not read account name from GW2 API."})
              end
          end

        _ ->
          params
      end

    case user |> User.changeset(params, :profile) |> Repo.update() do
      {:ok, updated} -> {:ok, updated}
      {:error, cs}   -> {:error, cs}
    end
  catch
    {:unprocessable_entity, msg} -> {:error, :unprocessable_entity, msg}
  end

  def delete_unverified() do
    Repo.delete_all(
      from u in User,
        where: u.verified == false and u.inserted_at < ago(2, "hour")
    )
  end

  defp first_key_with_account(keys) when is_list(keys) do
    Enum.find_value(keys, fn key ->
      case GW2.tokeninfo(key) do
        {:ok, %{permissions: perms}} ->
          perms
          |> Enum.map(&String.downcase/1)
          |> Enum.member?(@required_scope)
          |> case do
               true -> key
               false -> nil
             end

        _ ->
          nil
      end
    end)
  end
end
