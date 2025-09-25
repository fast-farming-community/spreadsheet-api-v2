defmodule FastApiWeb.DetailController do
  use FastApiWeb, :controller

  alias FastApi.Auth.Restrictions
  alias FastApi.Repo
  alias FastApi.Schemas.Fast

  import Ecto.Query
  require Logger

  # ─────────────────────────────
  # Small JSON helpers

  defp json_404(conn), do: send_resp(conn, 404, ~s({"error":"not_found"}))
  defp json_400(conn), do: send_resp(conn, 400, ~s({"error":"bad_request"}))

  defp present?(v) when is_binary(v), do: String.trim(v) != ""
  defp present?(_), do: false

  # Safe JSON decode; never raises
  defp decode_json(nil), do: {:ok, nil}
  defp decode_json(""),  do: {:ok, nil}
  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, err}  -> {:error, err}
    end
  end

  # Decode rows expected to be a JSON array; returns [] on problems (with logging)
  defp decode_rows_list(rows_json, context) do
    case decode_json(rows_json) do
      {:ok, list} when is_list(list) ->
        list

      {:ok, nil} ->
        Logger.error("decode_rows_list: nil JSON for #{context}")
        []

      {:ok, other} ->
        Logger.error("decode_rows_list: non-list JSON for #{context}: #{inspect(other)}")
        []

      {:error, err} ->
        Logger.error("decode_rows_list: decode error for #{context}: #{inspect(err)}")
        []
    end
  end

  # ─────────────────────────────
  # PUBLIC

  # Defensive version: validates params, handles not found, no crashes on nil JSON.
  def get_item_page(conn, params) do
    module     = Map.get(params, "module")
    collection = Map.get(params, "collection")
    item       = Map.get(params, "item")

    # Guard against nil/blank params (prevents MatchError)
    if not (present?(module) and present?(collection) and present?(item)) do
      return_bad_request(conn)
    else
      :telemetry.execute([:fast_api, :feature, :request], %{count: 1}, %{
        collection: collection,
        item: item
      })

      claims = Guardian.Plug.current_claims(conn)

      # Find the detail record safely (may be nil)
      detail = get_detail_safe(module, collection, item)

      # If nothing found → 404
      if is_nil(detail) do
        json_404(conn)
      else
        category = Map.get(detail, "Category")

        if Restrictions.restricted?(detail, claims) do
          conn
          |> Plug.Conn.put_status(:unauthorized)
          |> json(%{error: "Invalid or Expired Access Token"})
        else
          # Load the rows/description for this detail key; handle nils safely
          rec =
            from(t in Fast.DetailTable,
              where: t.key == ^item,
              join: f in Fast.DetailFeature,
              on: t.detail_feature_id == f.id,
              where: f.name == ^category,
              select: %{rows: t.rows, description: t.description}
            )
            |> Repo.one()

          # If no DB row matched, return 404
          if is_nil(rec) do
            json_404(conn)
          else
            list = decode_rows_list(rec.rows, "DetailTable rows for key=#{item} category=#{category}")
            json(conn, %{description: rec.description, detail: detail, list: list})
          end
        end
      end
    end
  end

  # ─────────────────────────────
  # PRIVATE

  # Safe version of your original get_detail/3:
  #  - Never Jason.decode!/1 on nil
  #  - Works for both "*-details" and "page with tables" branches
  defp get_detail_safe(module, collection, item) do
    if String.contains?(module, "details") do
      feature = String.replace(module, "-details", "")

      rows_json =
        from(t in Fast.DetailTable,
          join: f in Fast.DetailFeature,
          on: t.detail_feature_id == f.id,
          where: f.name == ^feature and t.key == ^collection,
          select: t.rows
        )
        |> Repo.one()

      rows = decode_rows_list(rows_json, "DetailTable feature=#{feature} key=#{collection}")

      Enum.find(rows, fn
        %{"Key" => ^item} -> true
        _ -> false
      end)
    else
      page =
        Fast.Page
        |> Repo.get_by(name: collection)
        |> Repo.preload(:tables)

      case page do
        nil ->
          nil

        %{tables: tables} when is_list(tables) ->
          tables
          |> Enum.flat_map(fn t -> decode_rows_list(t.rows, "Page #{collection} table_id=#{t.id || "?"}") end)
          |> Enum.find(fn
            %{"Key" => ^item} -> true
            _ -> false
          end)

        _ ->
          nil
      end
    end
  end

  defp return_bad_request(conn), do: json_400(conn)
end
