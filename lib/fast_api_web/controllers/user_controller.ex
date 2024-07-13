defmodule FastApiWeb.UserController do
  use FastApiWeb, :controller

  alias FastApi.Auth
  alias FastApi.Utils.Ecto, as: EctoUtils
  alias FastApi.Schemas.Auth.User

  def create(conn, user_params) do
    case Auth.create_user(user_params) do
      {:ok, %User{} = user} ->
        {:ok, token, _} = Auth.Token.encode_and_sign(user)

        json(conn, %{token: token})

      {:error, changeset} ->
        conn
        |> Plug.Conn.put_status(400)
        |> json(%{errors: EctoUtils.get_errors(changeset)})
    end
  end

  def login(conn, %{"user" => %{"email" => email, "password" => password}}) do
    user = Auth.get_user_by_email(email)

    case Bcrypt.verify_pass(password, user.password) do
      {:error, msg} ->
        send_resp(conn, :unauthorized, msg)

      _ ->
        {:ok, token, _} = Auth.Token.encode_and_sign(user)
        json(conn, %{token: token})
    end
  end
end
