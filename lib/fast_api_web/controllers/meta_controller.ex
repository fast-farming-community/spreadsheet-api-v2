defmodule FastApiWeb.MetaController do
  use FastApiWeb, :controller

  alias FastApi.Repo
  alias FastApi.Schemas.Fast

  def index(conn, _params) do
    tier_key =
      case conn.assigns[:tier] do
        nil -> "free"
        a when is_atom(a) -> Atom.to_string(a)
        b when is_binary(b) -> b
        _ -> "free"
      end

    metas =
      Fast.Metadata
      |> Repo.all()
      |> Enum.map(&safe_encode(&1, tier_key))

    json(conn, metas)
  end

  defp safe_encode(%Fast.Metadata{name: name, data: data}, tier_key) do
    decoded =
      case data do
        nil -> %{}
        "" -> %{}
        bin when is_binary(bin) ->
          case Jason.decode(bin) do
            {:ok, m} when is_map(m) -> m
            _ -> %{}
          end
        _ -> %{}
      end

    updated_at =
      decoded
      |> Map.get("updated_at", %{})
      |> case do
        m when is_map(m) -> Map.get(m, tier_key)
        _ -> nil
      end

    %{
      name: name,
      data: decoded,
      updated_at: updated_at
    }
  end
end
