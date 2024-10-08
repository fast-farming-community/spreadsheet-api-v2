defmodule FastApiWeb.FeatureController do
  use FastApiWeb, :controller

  alias FastApi.Auth.Restrictions
  alias FastApi.Repo
  alias FastApi.Schemas.Fast

  def get_page(conn, %{"collection" => "overview"}) do
    json(conn, [])
  end

  def get_page(conn, %{"collection" => collection}) do
    :telemetry.execute([:fast_api, :feature, :request], %{count: 1}, %{collection: collection})

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
    claims = Guardian.Plug.current_claims(conn)

    rows = Jason.decode!(json_rows)

    {restricted, available} = Enum.split_with(rows, &Restrictions.restricted?(&1, claims))

    restricted_freqs =
      Enum.frequencies_by(restricted, fn %{"Requires" => requires} -> requires end)

    table
    |> Map.put(:rows, available)
    |> Map.put(:restrictions, restricted_freqs)
  end
end
