defmodule FastApiWeb.UserController do
  use FastApiWeb, :controller

  alias FastApi.Auth
  alias FastApi.Auth.Token
  alias FastApi.Utils.Ecto, as: EctoUtils
  alias FastApi.Schemas.Auth.User

  def change_password(conn, password_params) do
    token =
      Guardian.Plug.current_token(conn) ||
        (get_req_header(conn, "authorization")
         |> List.first()
         |> case do
              "Bearer " <> t -> t
              t when is_binary(t) -> t
              _ -> nil
            end)

    with {:ok, user, _claims} <-
           Token.resource_from_token(token, %{"iss" => "fast_api", "typ" => "access"}) do
      cond do
        not is_binary(user.password) or user.password == "" ->
          Bcrypt.no_user_verify()
          conn
          |> Plug.Conn.put_status(:unauthorized)
          |> json(%{errors: ["No password is set for this account. Please complete registration or set a password."]})

        Bcrypt.verify_pass(password_params["old_password"] || "", user.password) ->
          new_password = password_params["password"] || password_params["new_password"]

          update_params = %{
            "password" => new_password,
            "password_confirmation" => password_params["password_confirmation"],
            "email" => user.email
          }

          case Auth.change_password(user, update_params) do
            {:ok, %User{} = updated_user} ->
              {:ok, access, _}  = Auth.Token.access_token(updated_user)
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
        {:ok, _} =
          user
          |> FastApiWeb.Notifiers.PreRegistrationNotifier.pre_register()
          |> FastApi.Mailer.deliver()

        json(conn, %{success: :ok})

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
            |> json(%{error: "This account has no password set yet. Please complete registration or set a password."})
        end

      _ ->
        Bcrypt.no_user_verify()
        conn
        |> Plug.Conn.put_status(:unauthorized)
        |> json(%{error: "Invalid username/password combination"})
    end
  end

  def refresh(conn, %{"token" => refresh}) do
    with {:ok, user, _} <-
           Token.resource_from_token(refresh, %{"iss" => "fast_api", "typ" => "refresh"}),
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

    token =

      Guardian.Plug.current_token(conn) ||

        (get_req_header(conn, "authorization")

         |> List.first()

         |> case do

              "Bearer " <> t -> t

              t when is_binary(t) -> t

              _ -> nil

            end)



    with {:ok, user, _claims} <-

           Token.resource_from_token(token, %{"iss" => "fast_api", "typ" => "access"}) do

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
    token =
      Guardian.Plug.current_token(conn) ||
        (get_req_header(conn, "authorization")
        |> List.first()
        |> case do
              "Bearer " <> t -> t
              t when is_binary(t) -> t
              _ -> nil
            end)

    with {:ok, user, _claims} <-
          Token.resource_from_token(token, %{"iss" => "fast_api", "typ" => "access"}) do
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
          conn |> Plug.Conn.put_status(:unprocessable_entity) |> json(%{errors: [msg]})

        {:error, %Ecto.Changeset{} = changeset} ->
          conn |> Plug.Conn.put_status(:bad_request) |> json(%{errors: EctoUtils.get_errors(changeset)})
      end
    else
      _ ->
        conn |> Plug.Conn.put_status(:unauthorized) |> json(%{error: "Invalid or missing access token"})
    end
  end

  defp sanitize_profile_params(params) when is_map(params) do
    api_keys =
      case Map.get(params, "api_keys") do
        m when is_map(m) ->
          Enum.reduce(m, %{}, fn
            {k, v}, acc when is_binary(k) and is_binary(v) ->
              Map.put(acc, k, v)
            _kv, acc ->
              acc
          end)

        _ ->
          nil
      end

    ingame_name =
      case Map.get(params, "ingame_name") do
        s when is_binary(s) ->
          trimmed = String.trim(s)
          if trimmed == "", do: nil, else: trimmed
        _ ->
          nil
      end

    %{}
    |> maybe_put("api_keys", api_keys)
    |> maybe_put("ingame_name", ingame_name)
  end

defp sanitize_profile_params(_), do: %{}

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp login_success(conn, user) do
    {:ok, access, _} = Auth.Token.access_token(user)
    {:ok, refresh, _} = Auth.Token.refresh_token(user)
    json(conn, %{access: access, refresh: refresh})
  end
end
