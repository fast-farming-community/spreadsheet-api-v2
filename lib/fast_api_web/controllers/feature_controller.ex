defmodule FastApiWeb.FeatureController do
  use FastApiWeb, :controller

  alias FastApi.Auth.Restrictions
  alias FastApi.Repo
  alias FastApi.Schemas.Fast

  def get_page(conn, %{"collection" => "overview"}), do: json(conn, [])

  def get_page(conn, %{"collection" => collection}) do
    :telemetry.execute([:fast_api, :feature, :request], %{count: 1}, %{collection: collection})

    case Repo.get_by(Fast.Page, name: collection) |> maybe_preload_tables() do
      %Fast.Page{} = page ->
        page.tables
        |> Enum.map(&build_table(&1, conn))
        |> Enum.sort_by(& &1.order)
        |> then(&json(conn, &1))

      _ ->
        conn |> Plug.Conn.put_status(:not_found) |> json(%{error: "Page not found"})
    end
  end

  defp maybe_preload_tables(nil), do: nil
  defp maybe_preload_tables(%Fast.Page{} = page), do: Repo.preload(page, :tables)

  defp build_table(%Fast.Table{} = table, conn) do
    claims = Guardian.Plug.current_claims(conn)
    tier   = conn.assigns[:tier] || :free

    {_field_used, json_rows} =
      case tier do
        :gold   -> {:rows_gold,   table.rows_gold   || table.rows}
        :silver -> {:rows_silver, table.rows_silver || table.rows}
        :copper -> {:rows_copper, table.rows_copper || table.rows}
        _       -> {:rows,        table.rows}
      end

    rows =
      case Jason.decode(json_rows || "[]") do
        {:ok, decoded} when is_list(decoded) -> decoded
        _ -> []
      end

    {restricted, available} = Enum.split_with(rows, &Restrictions.restricted?(&1, claims))

    restricted_freqs =
      Enum.frequencies_by(restricted, fn
        %{"Requires" => requires} -> requires
        _ -> "unknown"
      end)

    table
    |> Map.put(:rows, available)
    |> Map.put(:restrictions, restricted_freqs)
  end
end
