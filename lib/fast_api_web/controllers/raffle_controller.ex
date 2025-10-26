defmodule FastApiWeb.RaffleController do
  use FastApiWeb, :controller
  alias FastApi.Raffle

  defp normalize_items(v) do
    cond do
      is_map(v) -> Map.get(v, "items", Map.get(v, :items, [])) || []
      is_list(v) -> v
      true -> []
    end
  end

  defp normalize_winners(v) do
    cond do
      is_map(v) -> Map.get(v, "winners", Map.get(v, :winners, [])) || []
      is_list(v) -> v
      true -> []
    end
  end

  def public(conn, _params) do
    r = Raffle.current_row()

    items =
      r.items
      |> normalize_items()
      |> Enum.map(&%{item_id: &1["item_id"], quantity: &1["quantity"]})

    winners = normalize_winners(r.winners)

    json(conn, %{month: r.month_key, status: r.status, items: items, winners: winners})
  end

  def signup(conn, _params) do
    user = Guardian.Plug.current_resource(conn)
    case Raffle.signup(user) do
      {:ok, :signed} -> json(conn, %{ok: true})
      _ -> conn |> put_status(:bad_request) |> json(%{ok: false})
    end
  end

  def me(conn, _params) do
    user = Guardian.Plug.current_resource(conn)
    r = Raffle.current_row()
    weight = if user.role_id != "free", do: 5, else: 1

    json(conn, %{
      month: r.month_key,
      signed: user.raffle_signed,
      weight: weight,
      role: user.role_id
    })
  end
end
