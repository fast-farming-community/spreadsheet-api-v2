defmodule FastApiWeb.Plugs.OptionalAuth do
  import Plug.Conn
  alias FastApi.Auth
  alias FastApi.Auth.Token

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> t] -> try_token(conn, t)
      [t] when is_binary(t) and byte_size(t) > 7 and binary_part(t, 0, 7) == "Bearer " ->
        try_token(conn, binary_part(t, 7, byte_size(t) - 7))
      _ ->
        assign_free(conn)
    end
  end

  defp try_token(conn, token) do
    case Token.decode_and_verify(token, %{"iss" => "fast_api"}) do
      {:ok, claims} ->
        case Token.resource_from_claims(claims) do
          {:ok, user} ->
            role = Auth.get_user_role(user)
            tier =
              case role do
                "gold"   -> :gold
                "silver" -> :silver
                "copper" -> :copper
                "premium"-> :gold
                "admin"  -> :gold
                _        -> :free
              end

            conn
            |> assign(:current_user, user)
            |> assign(:role, role)
            |> assign(:tier, tier)

          _ ->
            assign_free(conn)
        end

      _ ->
        assign_free(conn)
    end
  end

  defp assign_free(conn) do
    conn
    |> assign(:role, "free")
    |> assign(:tier, :free)
  end
end
