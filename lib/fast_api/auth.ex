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

  defp key_has_account?(key) when is_binary(key) do
    case GW2.tokeninfo(key) do
      {:ok, %{permissions: perms}} ->
        has =
          perms
          |> Enum.map(&String.downcase/1)
          |> Enum.member?(@required_scope)

        if has, do: :ok, else: :invalid

      {:error, {:unauthorized, _}} -> :invalid
      {:error, :remote_disabled} -> :unavailable
      {:error, {:transport, _}} -> :unavailable
      _ -> :unavailable
    end
  end

  defp pick_account_key(keys) when is_list(keys) do
    saw_unavailable? =
      Enum.reduce_while(keys, false, fn k, saw_unavail ->
        case key_has_account?(k) do
          :ok -> throw({:found, k})
          :invalid -> {:cont, saw_unavail}
          :unavailable -> {:cont, true}
        end
      end)

    if saw_unavailable?, do: {:error, :unavailable}, else: {:error, :invalid}
  catch
    {:found, key} -> {:ok, key}
  end

  @doc """
  Strict profile update.

  - Only saves keys if changed AND at least one key is confirmed valid (has 'account' perm).
  - On success, fetches `/v2/account` and persists ingame_name.
  - On invalid keys → 422, on GW2 down → 503.
  - Empty map clears keys and ingame_name.
  """
  def update_profile(%User{} = user, params) when is_map(params) do
    incoming_keys_map =
      case Map.get(params, "api_keys") do
        m when is_map(m) -> m
        _ -> nil
      end

    incoming_keys_list =
      case incoming_keys_map do
        nil -> []
        m ->
          m
          |> Map.values()
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
      end

    existing_keys_map = user.api_keys || %{}
    existing_keys_list =
      existing_keys_map
      |> Map.values()
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    keys_changed? = MapSet.new(incoming_keys_list) != MapSet.new(existing_keys_list)

    params =
      cond do
        incoming_keys_map == nil ->
          params

        map_size(incoming_keys_map) == 0 ->
          params
          |> Map.put("api_keys", %{})
          |> Map.put("ingame_name", nil)

        not keys_changed? ->
          params

        true ->
          case pick_account_key(incoming_keys_list) do
            {:ok, account_key} ->
              case GW2.account(account_key) do
                {:ok, %{"name" => ign}} when is_binary(ign) and ign != "" ->
                  Map.put(params, "ingame_name", ign)

                {:error, :remote_disabled} ->
                  throw({:upstream_unavailable, "GW2 API maintenance; try again later."})

                {:error, {:transport, _}} ->
                  throw({:upstream_unavailable, "GW2 API unreachable; try again later."})

                _ ->
                  throw({:unprocessable_entity, "Could not read account name from GW2 API."})
              end

            {:error, :invalid} ->
              throw({:unprocessable_entity, "API key invalid or missing required 'account' permission."})

            {:error, :unavailable} ->
              throw({:upstream_unavailable, "GW2 validation unavailable; please try again later."})
          end
      end

    case user |> User.changeset(params, :profile) |> Repo.update() do
      {:ok, updated} -> {:ok, updated}
      {:error, cs} -> {:error, cs}
    end
  catch
    {:unprocessable_entity, msg} -> {:error, :unprocessable_entity, msg}
    {:upstream_unavailable, msg} -> {:error, :upstream_unavailable, msg}
  end

  def delete_unverified() do
    Repo.delete_all(
      from u in User,
        where: u.verified == false and u.inserted_at < ago(2, "hour")
    )
  end

  def request_password_reset(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()

    case get_user_by_email(normalized) do
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
          :ok
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
                  email_struct = FastApiWeb.Notifiers.PasswordResetNotifier.reset_request(user, token)
                  FastApi.Mailer.deliver(email_struct)
                rescue
                  e ->
                    Logger.error("password reset email failed: #{Exception.format(:error, e, __STACKTRACE__)}")
                    :ok
                end

              :ok

            {:error, changeset} ->
              Logger.error("password reset insert failed email=#{normalized} errors=#{inspect(changeset.errors)}")
              :ok
          end
        end

      _ -> :ok
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
