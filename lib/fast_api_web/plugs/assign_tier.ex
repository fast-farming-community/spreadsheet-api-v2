defmodule FastApiWeb.Plugs.AssignTier do
  @moduledoc "Reads Guardian claims and assigns :role and :tier on the conn."
  import Plug.Conn
  alias Guardian.Plug, as: GPlug

  def init(opts), do: opts

  def call(conn, _opts) do
    claims = GPlug.current_claims(conn) || %{}
    role   = Map.get(claims, "role", "free")

    tier =
      case role do
        "gold"   -> :gold
        "silver" -> :silver
        "copper" -> :copper
        _        -> :free
      end

    conn
    |> assign(:role, role)
    |> assign(:tier, tier)
  end
end
