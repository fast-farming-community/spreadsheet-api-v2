defmodule FastApiWeb.RaffleController do
  use FastApiWeb, :controller
  alias FastApi.Raffle

  def public(conn, _params) do
    r = Raffle.current_row()
    items = (r.items || []) |> case do
      %{"items" => list} when is_list(list) -> list
      list when is_list(list) -> list
      _ -> []
    end
    |> Enum.map(&%{item_id: &1["item_id"], quantity: &1["quantity"]})

    json(conn, %{month: r.month_key, status: r.status, items: items, winners: r.winners || []})
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
