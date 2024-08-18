defmodule FastApi.Auth.ErrorHandler do
  @moduledoc "Error handling for ueberauth/guardian."
  use FastApiWeb, :controller

  @behaviour Guardian.Plug.ErrorHandler

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {type, _reason}, _opts) do
    conn
    |> Plug.Conn.put_status(:unauthorized)
    |> json(%{error: to_string(type)})
  end
end
