defmodule FastApiWeb.DetailTableController do
  use FastApiWeb, :controller
  import Ecto.Query
  alias FastApi.Repo
  alias FastApi.Schemas.Fast.DetailTable
  alias FastApiWeb.TierRows

  def index_by_page(conn, %{"page_id" => page_id}) do
    tier = conn.assigns.tier || :free

    q =
      from t in DetailTable,
        where: t.page_id == ^page_id and t.published == true,
        order_by: [asc: t.order, asc: t.id],
        select: %{
          id: t.id,
          key: t.key,
          name: t.name,
          description: t.description,
          rows: TierRows.rows_expr(tier, t)
        }

    rows = Repo.all(q)
    json(conn, %{tables: rows})
  end
end
