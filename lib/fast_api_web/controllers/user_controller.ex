defmodule FastApiWeb.UserController do
  use FastApiWeb, :controller

  alias FastApi.Auth

  def create(conn, %{"user" => user_params}) do
    with {:ok, %User{} = user} <- Auth.create_user(user_params) do
      {:ok, token, _} = encode_and_sign(user)

      json(conn, %{token: token})
    end
  end

  def login(conn, %{"user" => %{"email" => email, "password" => password}}) do
    user = Auth.get_user_by_email(email)

    case Bcrypt.check_pass(user, password, hash_key: :password) do
      {:error, msg} ->
        send_resp(conn, :unauthorized, msg)

      _ ->
        {:ok, token, _} = encode_and_sign(user)
        json(conn, %{token: token})
    end
  end
end
