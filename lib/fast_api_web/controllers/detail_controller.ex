defmodule FastApiWeb.DetailController do
  use FastApiWeb, :controller

  alias FastApi.Auth.Restrictions
  alias FastApi.Repo
  alias FastApi.Schemas.Fast

  import Ecto.Query

  def get_item_page(conn, %{"module" => module, "collection" => collection, "item" => item}) do
    claims = Guardian.Plug.current_claims(conn)
    %{"Category" => category} = detail = get_detail(module, collection, item)

    if Restrictions.is_restricted(detail, claims) do
      # TODO: better
      conn
      |> Plug.Conn.put_status(:unauthorized)
      |> json(%{error: "Invalid or Expired Access Token"})
    else
      {list, description} =
        from(t in Fast.DetailTable,
          where: t.key == ^item,
          join: f in Fast.DetailFeature,
          on: t.detail_feature_id == f.id,
          where: f.name == ^category,
          select: %{rows: t.rows, description: t.description}
        )
        |> Repo.one()
        |> then(&{Jason.decode!(&1.rows), &1.description})

      json(conn, %{description: description, detail: detail, list: list})
    end
  end

  defp get_detail(module, collection, item) do
    # TODO: Clean this up
    if String.contains?(module, "details") do
      module = String.replace(module, "-details", "")

      from(t in Fast.DetailTable,
        join: f in Fast.DetailFeature,
        on: t.detail_feature_id == f.id,
        where: f.name == ^module and t.key == ^collection,
        select: t.rows
      )
      |> Repo.one()
      |> Jason.decode!()
      |> Enum.find(fn
        %{"Key" => ^item} -> true
        _ -> false
      end)
    else
      Fast.Page
      |> Repo.get_by(name: collection)
      |> Repo.preload(:tables)
      |> then(fn page -> Enum.flat_map(page.tables, &Jason.decode!(&1.rows)) end)
      |> Enum.find(fn
        %{"Key" => ^item} -> true
        _ -> false
      end)
    end
  end
end
