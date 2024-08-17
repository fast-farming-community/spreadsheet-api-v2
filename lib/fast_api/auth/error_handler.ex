defmodule FastApi.Auth.ErrorHandler do
  use FastApiWeb, :controller

  @behaviour Guardian.Plug.ErrorHandler

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {type, reason}, _opts) do
    conn
    |> Plug.Conn.put_status(:unauthorized)
    |> json(%{error: to_string(type)})
  end
end
