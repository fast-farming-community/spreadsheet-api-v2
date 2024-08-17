defmodule FastApiWeb.UserController do
  use FastApiWeb, :controller

  alias FastApi.Auth
  alias FastApi.Auth.Token
  alias FastApi.Utils.Ecto, as: EctoUtils
  alias FastApi.Schemas.Auth.User

  def change_password(_conn, _password_params) do
    # token = conn.assigns[:access_token]
    # # TODO:
    # # - verify access_token
    # # - get username from access token
    # # - verify old_password
    # # - change password
    # case Auth.change_password(user, password_params) do
    #   {:ok, %User{} = user} ->
    #     login_success(conn, user)

    #   {:error, changeset} ->
    #     conn
    #     |> Plug.Conn.put_status(400)
    #     |> json(%{errors: EctoUtils.get_errors(changeset)})
    # end
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
    case Token.exchange(refresh, "refresh", "access",
           ttl: Application.fetch_env!(:fast_api, :access_token_ttl)
         ) do
      {:ok, {refresh, _}, {access, _}} ->
        json(conn, %{access: access, refresh: refresh})

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
