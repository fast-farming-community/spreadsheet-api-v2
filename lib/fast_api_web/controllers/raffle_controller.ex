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
    totals = Raffle.current_totals()

    json(conn, %{
      month: r.month_key,
      status: r.status,
      items: items,
      winners: winners,
      entries_count: stats.entrants,
      tickets_pool: stats.tickets,
      tp_buy_total: totals.buy,
      tp_sell_total: totals.sell
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
        items_map =
          case r.items do
            %{"items" => _} = m -> m
            list when is_list(list) -> %{"items" => list}
            _ -> %{"items" => []}
          end

        winners_map =
          case r.winners do
            %{"winners" => _} = m -> m
            list when is_list(list) -> %{"winners" => list}
            _ -> %{"winners" => []}
          end

        items_list =
          case items_map["items"] do
            l when is_list(l) -> l
            _ -> []
          end

        %{buy: buy_total_fallback, sell: sell_total_fallback} = Raffle.totals_for_items(items_list)

        summary = Map.get(winners_map, "summary", %{})
        entrants_frozen = summary["entrants"]
        tickets_frozen  = summary["tickets"]
        tp_buy_total    = summary["tp_buy_total"] || buy_total_fallback
        tp_sell_total   = summary["tp_sell_total"] || sell_total_fallback

        %{
          month: r.month_key,
          status: r.status,
          items: items_map,
          winners: winners_map,
          entries_count: entrants_frozen,
          tickets_pool: tickets_frozen,
          tp_buy_total: tp_buy_total,
          tp_sell_total: tp_sell_total
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
        "silver"  -> 15
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
