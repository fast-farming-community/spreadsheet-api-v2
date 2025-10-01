defmodule FastApiWeb.TableController do
  use FastApiWeb, :controller
  import Ecto.Query
  alias FastApi.Repo
  alias FastApi.Schemas.Fast.Table
  alias FastApiWeb.TierRows

  def index_by_page(conn, %{"page_id" => page_id}) do
    tier = conn.assigns.tier || :free
    rows_dyn = TierRows.rows_dynamic(tier)

    q =
      from t in Table,
        where: t.page_id == ^page_id and t.published == true,
        order_by: [asc: t.order, asc: t.id],
        select: %{
          id: t.id,
          name: t.name,
          description: t.description,
          rows: ^rows_dyn
        }

    tables = Repo.all(q)
    json(conn, %{tables: tables})
  end
end
