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
           Token.resource_from_token(token, %{"iss" => "fast_api", "typ" => "access"}),
         true <- Bcrypt.verify_pass(password_params["old_password"] || "", user.password) do
      new_password = password_params["password"] || password_params["new_password"]

      update_params = %{
        "password" => new_password,
        "password_confirmation" => password_params["password_confirmation"],
        "email" => user.email
      }

      case Auth.change_password(user, update_params) do
        {:ok, %User{} = updated_user} ->
          # issue fresh tokens after password change
          {:ok, access, _}  = Auth.Token.access_token(updated_user)
          {:ok, refresh, _} = Auth.Token.refresh_token(updated_user)
          json(conn, %{access: access, refresh: refresh})

        {:error, changeset} ->
          conn
          |> Plug.Conn.put_status(:bad_request)
          |> json(%{errors: EctoUtils.get_errors(changeset)})
      end
    else
      false ->
        conn
        |> Plug.Conn.put_status(:unauthorized)
        |> json(%{errors: ["Old password is incorrect"]})

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
    user = Auth.get_user_by_email(email)

    if not is_nil(user) and Bcrypt.verify_pass(password, user.password) do
      login_success(conn, user)
    else
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

  defp login_success(conn, user) do
    {:ok, access, _} = Auth.Token.access_token(user)
    {:ok, refresh, _} = Auth.Token.refresh_token(user)
    json(conn, %{access: access, refresh: refresh})
  end
end
