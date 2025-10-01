defmodule FastApiWeb.MetaController do
  use FastApiWeb, :controller

  alias FastApi.Repo
  alias FastApi.Schemas.Fast

  def index(conn, _params) do
    tier_key =
      conn.assigns[:tier]
      |> case do
        nil -> "free"
        a when is_atom(a) -> Atom.to_string(a)
        b when is_binary(b) -> b
        _ -> "free"
      end

    Fast.Metadata
    |> Repo.all()
    |> Enum.map(fn
      %Fast.Metadata{name: name, data: nil} ->
        %{name: name, data: %{}, updated_at: nil}

      %Fast.Metadata{name: name, data: ""} ->
        %{name: name, data: %{}, updated_at: nil}

      %Fast.Metadata{name: name, data: json} ->
        case Jason.decode(json) do
          {:ok, decoded} ->
            updated_at =
              decoded
              |> Map.get("updated_at", %{})
              |> case do
                m when is_map(m) -> Map.get(m, tier_key)
                _ -> nil
              end

            %{name: name, data: decoded, updated_at: updated_at}

          _ ->
            %{name: name, data: %{}, updated_at: nil}
        end
    end)
    |> then(&json(conn, &1))
  end
end
