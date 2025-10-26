defmodule FastApiWeb.UserController do
  use FastApiWeb, :controller

  alias FastApi.Auth
  alias FastApi.Auth.Token
  alias FastApi.Utils.Ecto, as: EctoUtils
  alias FastApi.Schemas.Auth.User

  @access_claims %{"iss" => "fast_api", "typ" => "access"}
  @refresh_claims %{"iss" => "fast_api", "typ" => "refresh"}

  defp bearer_token(conn) do
    Guardian.Plug.current_token(conn) ||
      (get_req_header(conn, "authorization")
       |> List.first()
       |> case do
         "Bearer " <> t -> t
         t when is_binary(t) -> t
         _ -> nil
       end)
  end

  def forgot_password(conn, %{"email" => email}) do
    case Auth.request_password_reset(email) do
      :ok ->
        json(conn, %{success: :ok, throttled: false})

      {:error, :rate_limited} ->
        json(conn, %{success: :ok, throttled: true})

      _ ->
        json(conn, %{success: :ok, throttled: false})
    end
  end

  def reset_password(conn, %{"token" => token} = params) do
    case Auth.reset_password(token, params) do
      {:ok, %User{} = user} ->
        {:ok, access, _} = Auth.Token.access_token(user)
        {:ok, refresh, _} = Auth.Token.refresh_token(user)
        json(conn, %{access: access, refresh: refresh})

      {:error, :invalid_or_expired} ->
        conn
        |> Plug.Conn.put_status(:unauthorized)
        |> json(%{errors: ["Invalid or expired reset link"]})

      {:error, %Ecto.Changeset{} = cs} ->
        conn
        |> Plug.Conn.put_status(:bad_request)
        |> json(%{errors: EctoUtils.get_errors(cs)})
    end
  end

  def change_password(conn, password_params) do
    token = bearer_token(conn)

    with {:ok, user, _claims} <- Token.resource_from_token(token, @access_claims) do
      cond do
        not is_binary(user.password) or user.password == "" ->
          Bcrypt.no_user_verify()

          conn
          |> Plug.Conn.put_status(:unauthorized)
          |> json(%{
            errors: [
              "No password is set for this account. Please complete registration or set a password."
            ]
          })

        Bcrypt.verify_pass(password_params["old_password"] || "", user.password) ->
          new_password = password_params["password"] || password_params["new_password"]

          update_params = %{
            "password" => new_password,
            "password_confirmation" => password_params["password_confirmation"],
            "email" => user.email
          }

          case Auth.change_password(user, update_params) do
            {:ok, %User{} = updated_user} ->
              {:ok, access, _} = Auth.Token.access_token(updated_user)
              {:ok, refresh, _} = Auth.Token.refresh_token(updated_user)
              json(conn, %{access: access, refresh: refresh})

            {:error, changeset} ->
              conn
              |> Plug.Conn.put_status(:bad_request)
              |> json(%{errors: EctoUtils.get_errors(changeset)})
          end

        true ->
          conn
          |> Plug.Conn.put_status(:unauthorized)
          |> json(%{errors: ["Old password is incorrect"]})
      end
    else
      _ ->
        conn
        |> Plug.Conn.put_status(:unauthorized)
        |> json(%{errors: ["Invalid or missing access token"]})
    end
  end

  def pre_register(conn, user_params) do
    case Auth.init_user(user_params) do
      {:ok, %User{} = user} ->
        email =
          user
          |> FastApiWeb.Notifiers.PreRegistrationNotifier.pre_register()

        case FastApi.Mailer.deliver(email) do
          {:ok, _} ->
            json(conn, %{success: :ok})

          {:error, reason} ->
            require Logger
            Logger.error("pre_register mail FAILED to=#{user.email} reason=#{inspect(reason)}")
            json(conn, %{success: :ok})
        end

      {:error, changeset} ->
        conn
        |> Plug.Conn.put_status(400)
        |> json(%{errors: EctoUtils.get_errors(changeset)})
    end
  end

  def register(conn, user_params) do
    case Auth.create_user(user_params) do
      {:ok, %User{} = user} ->
        login_success(conn, user)

      {:error, :invalid_token} ->
        json(conn, %{errors: ["Registration token is no longer valid."]})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> Plug.Conn.put_status(400)
        |> json(%{errors: EctoUtils.get_errors(changeset)})
    end
  end

  def login(conn, %{"email" => email, "password" => password}) do
    case Auth.get_user_by_email(email) do
      %User{} = user ->
        case user.password do
          hashed when is_binary(hashed) and hashed != "" ->
            if Bcrypt.verify_pass(password || "", hashed) do
              login_success(conn, user)
            else
              Bcrypt.no_user_verify()

              conn
              |> Plug.Conn.put_status(:unauthorized)
              |> json(%{error: "Invalid username/password combination"})
            end

          _ ->
            Bcrypt.no_user_verify()

            conn
            |> Plug.Conn.put_status(:unauthorized)
            |> json(%{
              error:
                "This account has no password set yet. Please complete registration or set a password."
            })
        end

      _ ->
        Bcrypt.no_user_verify()

        conn
        |> Plug.Conn.put_status(:unauthorized)
        |> json(%{error: "Invalid username/password combination"})
    end
  end

  def refresh(conn, %{"token" => refresh}) do
    with {:ok, user, _} <- Token.resource_from_token(refresh, @refresh_claims),
         {:ok, access, _} <- Auth.Token.access_token(user) do
      json(conn, %{access: access})
    else
      _ ->
        conn
        |> Plug.Conn.put_status(:unauthorized)
        |> json(%{error: "Invalid or Expired Refresh Token"})
    end
  end

  def me(conn, _params) do
    token = bearer_token(conn)

    with {:ok, user, _claims} <- Token.resource_from_token(token, @access_claims) do
      role = Auth.get_user_role(user)

      json(conn, %{
        email: user.email,
        role: role,
        api_keys: user.api_keys || %{},
        ingame_name: user.ingame_name || nil
      })
    else
      _ ->
        conn
        |> Plug.Conn.put_status(:unauthorized)
        |> json(%{error: "Invalid or missing access token"})
    end
  end

  def update_profile(conn, params) do
    token = bearer_token(conn)

    with {:ok, user, _claims} <- Token.resource_from_token(token, @access_claims) do
      case Auth.update_profile(user, sanitize_profile_params(params)) do
        {:ok, %User{} = updated} ->
          role = Auth.get_user_role(updated)

          json(conn, %{
            email: updated.email,
            role: role,
            api_keys: updated.api_keys || %{},
            ingame_name: updated.ingame_name || nil
          })

        {:error, :unprocessable_entity, msg} ->
          conn
          |> Plug.Conn.put_status(:unprocessable_entity)
          |> json(%{errors: [msg]})

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> Plug.Conn.put_status(:bad_request)
          |> json(%{errors: EctoUtils.get_errors(changeset)})
      end
    else
      _ ->
        conn
        |> Plug.Conn.put_status(:unauthorized)
        |> json(%{error: "Invalid or missing access token"})
    end
  end

  defp sanitize_profile_params(params) when is_map(params) do
    api_keys =
      case Map.get(params, "api_keys") do
        m when is_map(m) ->
          Enum.reduce(m, %{}, fn
            {k, v}, acc when is_binary(k) and is_binary(v) -> Map.put(acc, k, v)
            _kv, acc -> acc
          end)

        _ ->
          nil
      end

    ingame_name =
      case Map.fetch(params, "ingame_name") do
        {:ok, s} when is_binary(s) ->
          trimmed = String.trim(s)
          if trimmed == "", do: :__clear__, else: trimmed

        _ ->
          :__absent__
      end

    out = %{}
    out = if api_keys != nil, do: Map.put(out, "api_keys", api_keys), else: out

    out =
      case ingame_name do
        :__absent__ -> out
        :__clear__ -> Map.put(out, "ingame_name", nil)
        v -> Map.put(out, "ingame_name", v)
      end

    out
  end

  defp sanitize_profile_params(_), do: %{}

  defp login_success(conn, user) do
    {:ok, access, _} = Auth.Token.access_token(user)
    {:ok, refresh, _} = Auth.Token.refresh_token(user)
    json(conn, %{access: access, refresh: refresh})
  end
end
