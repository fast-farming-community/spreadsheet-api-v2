defmodule FastApi.Auth do
  @moduledoc "Authentication helper functions."
  alias FastApi.Repo
  alias FastApi.Schemas.Auth.{Role, User}
  alias FastApi.Schemas.PasswordReset
  alias FastApi.GW2.Client, as: GW2

  import Ecto.Query
  require Logger

  @required_scope "account"
  @reset_ttl_minutes 60
  @reset_min_interval 30  # seconds between emails per user

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

  def create_user(_), do: {:error, :invalid_token}

  def change_password(%User{} = user, params),
    do: user |> User.changeset(params, :update) |> Repo.update()

  def set_role(%User{} = user, role),
    do: user |> Repo.preload(:role) |> User.changeset(role, :role) |> Repo.update()

  @doc """
  Update profile. If `api_keys` are provided and non-empty, require a key with the
  `account` scope and overwrite `ingame_name` from `/v2/account`. Otherwise behave
  like a normal profile update.
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

  def request_password_reset(email) when is_binary(email) do
    case get_user_by_email(email) do
      %User{verified: true} = user ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        recent_sent_at =
          from(r in PasswordReset,
            where: r.user_id == ^user.id,
            order_by: [desc: r.sent_at],
            limit: 1,
            select: r.sent_at
          )
          |> Repo.one()

        if recent_sent_at && DateTime.diff(now, recent_sent_at, :second) < @reset_min_interval do
          {:error, :rate_limited}
        else
          token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
          token_hash = :crypto.hash(:sha256, token)
          expires_at = DateTime.add(now, @reset_ttl_minutes * 60, :second)

          cs =
            %PasswordReset{}
            |> PasswordReset.insert_changeset(%{
              user_id: user.id,
              token_hash: token_hash,
              sent_at: now,
              expires_at: expires_at
            })

          case Repo.insert(cs) do
            {:ok, _} ->
              _ =
                try do
                  email_struct =
                    FastApiWeb.Notifiers.PasswordResetNotifier.reset_request(user, token)

                  FastApi.Mailer.deliver(email_struct)
                rescue
                  e ->
                    Logger.error("password reset email render/send failed: #{Exception.format(:error, e, __STACKTRACE__)}")
                    :ok
                end

              :ok

            {:error, changeset} ->
              Logger.error("password reset insert failed email=#{email} errors=#{inspect(changeset.errors)}")
              :ok
          end
        end

      _ ->
        # Do not disclose existence of account
        :ok
    end
  end

  def reset_password(plain_token, params) when is_binary(plain_token) and is_map(params) do
    token_hash = :crypto.hash(:sha256, plain_token)

    with %PasswordReset{} = pr <- Repo.get_by(PasswordReset, token_hash: token_hash),
         true <- pr.used_at == nil,
         true <- DateTime.compare(pr.expires_at, DateTime.utc_now()) == :gt,
         %User{} = user <- Repo.get(User, pr.user_id) do
      update_params = %{
        "password" => params["password"],
        "password_confirmation" => params["password_confirmation"],
        "email" => user.email
      }

      case change_password(user, update_params) do
        {:ok, %User{} = updated} ->
          pr |> PasswordReset.mark_used_changeset() |> Repo.update()
          Repo.delete_all(from r in PasswordReset, where: r.user_id == ^updated.id and is_nil(r.used_at) and r.id != ^pr.id)
          {:ok, updated}

        {:error, %Ecto.Changeset{} = cs} ->
          {:error, cs}
      end
    else
      nil -> {:error, :invalid_or_expired}
      false -> {:error, :invalid_or_expired}
      _ -> {:error, :invalid_or_expired}
    end
  end

  def purge_expired_password_resets() do
    now = DateTime.utc_now()
    {count, _} =
      Repo.delete_all(
        from r in PasswordReset,
          where: not is_nil(r.used_at) or r.expires_at <= ^now
      )
    count
  end
end
