defmodule FastApiWeb.RaffleController do
  use FastApiWeb, :controller
  alias FastApi.Raffle
  alias FastApi.Repo
  alias FastApi.Schemas.Raffle, as: RaffleRow
  import Ecto.Query

  def public(conn, _params) do
    r = Raffle.current_row()

    items =
      case r.items do
        %{"items" => list} when is_list(list) -> list
        list when is_list(list) -> list
        _ -> []
      end
      |> Enum.map(fn it ->
        %{
          item_id: it["item_id"],
          quantity: it["quantity"],
          name: it["name"],
          icon: it["icon"],
          rarity: it["rarity"],
          tp_buy: it["tp_buy"],
          tp_sell: it["tp_sell"]
        }
      end)

    winners =
      case r.winners do
        %{"winners" => list} when is_list(list) -> list
        list when is_list(list) -> list
        _ -> []
      end

    stats = Raffle.current_stats()

    json(conn, %{
      month: r.month_key,
      status: r.status,
      items: items,
      winners: winners,
      entries_count: stats.entrants,
      tickets_pool: stats.tickets
    })
  end

  def history(conn, _params) do
    %Date{year: y, month: m} = Date.utc_today()
    current_key = Date.new!(y, m, 1)

    rows =
      from(r in RaffleRow,
        where: r.month_key < ^current_key,
        order_by: [desc: r.month_key],
        limit: 12
      )
      |> Repo.all()

    payload =
      Enum.map(rows, fn r ->
        %{
          month: r.month_key,
          status: r.status,
          items:
            case r.items do
              %{"items" => _} = m -> m
              list when is_list(list) -> %{"items" => list}
              _ -> %{"items" => []}
            end,
          winners:
            case r.winners do
              %{"winners" => _} = m -> m
              list when is_list(list) -> %{"winners" => list}
              _ -> %{"winners" => []}
            end
        }
      end)

    json(conn, payload)
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

    weight =
      case user.role_id do
        "premium" -> 50
        "gold"    -> 25
        "silver"  -> 10
        "copper"  -> 5
        _         -> 1
      end

    json(conn, %{
      month: r.month_key,
      signed: user.raffle_signed,
      weight: weight,
      role: user.role_id
    })
  end
end
