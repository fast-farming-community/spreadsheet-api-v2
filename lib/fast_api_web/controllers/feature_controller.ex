defmodule FastApiWeb.FeatureController do
  use FastApiWeb, :controller

  alias FastApi.Repo
  alias FastApi.Schemas.Fast

  def get_page(conn, %{"collection" => "overview"}) do
    json(conn, [])
  end

  def get_page(conn, %{"collection" => collection}) do
    Fast.Page
    |> Repo.get_by(name: collection)
    |> Repo.preload(:tables)
    |> then(fn page ->
      page.tables
      |> Enum.map(&build_table(&1, conn))
      |> Enum.sort_by(& &1.order)
    end)
    |> then(&json(conn, &1))
  end

  defp build_table(%Fast.Table{rows: json_rows} = table, conn) do
    %{"role" => role} = Guardian.Plug.current_claims(conn) || %{"role" => "soldier"}

    rows = Jason.decode!(json_rows)

    {restricted, available} =
      Enum.split_with(rows, fn
        %{"Requires" => requires} when role == "soldier" -> requires == "Heart of Thorns"
        _ -> true
      end)

    table
    |> Map.put(:rows, available)
    |> Map.put(:restricted_count, Enum.count(restricted))
  end
end
