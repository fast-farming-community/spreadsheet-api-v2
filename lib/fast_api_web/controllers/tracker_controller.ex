defmodule FastApiWeb.TrackerController do
  use FastApiWeb, :controller

  @required_perms ~w(characters wallet inventories)

  def validate_key(conn, %{"key" => key}) when is_binary(key) do
    case FastApi.GW2.Client.tokeninfo(key) do
      {:ok, %{name: name, permissions: perms}} ->
        missing = Enum.reject(@required_perms, &(&1 in perms))

        if missing == [] do
          json(conn, %{ok: true, name: name, permissions: perms})
        else
          conn
          |> put_status(:bad_request)
          |> json(%{ok: false, error: "Missing required permissions", missing: missing, permissions: perms})
        end

      {:error, {:unauthorized, _}} ->
        conn |> put_status(:bad_request) |> json(%{ok: false, error: "Invalid API key"})

      {:error, {:unexpected_status, status, _body}} ->
        conn |> put_status(:bad_gateway) |> json(%{ok: false, error: "GW2 API error", status: status})

      {:error, {:transport, reason}} ->
        conn |> put_status(:bad_gateway) |> json(%{ok: false, error: "Upstream unreachable", reason: inspect(reason)})
    end
  end

  def characters(conn, %{"key" => key}) when is_binary(key) do
    case FastApi.GW2.Client.characters(key) do
        {:ok, names} -> json(conn, names)
        {:error, {:unexpected_status, status, _}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "GW2 API error", status: status})
        {:error, {:transport, reason}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "Upstream unreachable", reason: inspect(reason)})
    end
    end

    def account_bank(conn, %{"key" => key}) when is_binary(key) do
    case FastApi.GW2.Client.account_bank(key) do
        {:ok, items} -> json(conn, items)
        {:error, {:unexpected_status, status, _}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "GW2 API error", status: status})
        {:error, {:transport, reason}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "Upstream unreachable", reason: inspect(reason)})
    end
    end

    def characters(conn, _),    do: conn |> put_status(:bad_request) |> json(%{error: "Missing key"})
    def account_bank(conn, _),  do: conn |> put_status(:bad_request) |> json(%{error: "Missing key"})

    def account_materials(conn, %{"key" => key}) when is_binary(key) do
  case FastApi.GW2.Client.account_materials(key) do
    {:ok, materials} -> json(conn, materials)
    {:error, {:unexpected_status, status, _}} ->
      conn |> put_status(:bad_gateway) |> json(%{error: "GW2 API error", status: status})
    {:error, {:transport, reason}} ->
      conn |> put_status(:bad_gateway) |> json(%{error: "Upstream unreachable", reason: inspect(reason)})
  end
end

    def account_inventory(conn, %{"key" => key}) when is_binary(key) do
    case FastApi.GW2.Client.account_inventory(key) do
        {:ok, shared} -> json(conn, shared)
        {:error, {:unexpected_status, status, _}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "GW2 API error", status: status})
        {:error, {:transport, reason}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "Upstream unreachable", reason: inspect(reason)})
    end
    end

    def account_wallet(conn, %{"key" => key}) when is_binary(key) do
    case FastApi.GW2.Client.account_wallet(key) do
        {:ok, wallet} -> json(conn, wallet)
        {:error, {:unexpected_status, status, _}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "GW2 API error", status: status})
        {:error, {:transport, reason}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "Upstream unreachable", reason: inspect(reason)})
    end
    end

    def character_inventory(conn, %{"key" => key, "character" => character}) when is_binary(key) and is_binary(character) do
    case FastApi.GW2.Client.character_inventory(key, character) do
        {:ok, inv} -> json(conn, inv)
        {:error, {:unexpected_status, status, _}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "GW2 API error", status: status})
        {:error, {:transport, reason}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "Upstream unreachable", reason: inspect(reason)})
    end
    end

    def account_materials(conn, _), do: conn |> put_status(:bad_request) |> json(%{error: "Missing key"})
    def account_inventory(conn, _), do: conn |> put_status(:bad_request) |> json(%{error: "Missing key"})
    def account_wallet(conn, _),    do: conn |> put_status(:bad_request) |> json(%{error: "Missing key"})
    def character_inventory(conn, _), do: conn |> put_status(:bad_request) |> json(%{error: "Missing key/character"})

    def items(conn, %{"ids" => ids}) do
    ids = normalize_ids(ids)
    case FastApi.GW2.Client.items(ids) do
        {:ok, list} -> json(conn, list)
        {:error, {:unexpected_status, status, _}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "GW2 API error", status: status})
        {:error, {:transport, reason}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "Upstream unreachable", reason: inspect(reason)})
    end
    end

    def prices(conn, %{"ids" => ids}) do
    ids = normalize_ids(ids)
    case FastApi.GW2.Client.prices(ids) do
        {:ok, list} -> json(conn, list)
        {:error, {:unexpected_status, status, _}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "GW2 API error", status: status})
        {:error, {:transport, reason}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "Upstream unreachable", reason: inspect(reason)})
    end
    end

    def currencies(conn, %{"ids" => ids}) do
    ids = normalize_ids(ids)
    case FastApi.GW2.Client.currencies(ids) do
        {:ok, list} -> json(conn, list)
        {:error, {:unexpected_status, status, _}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "GW2 API error", status: status})
        {:error, {:transport, reason}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "Upstream unreachable", reason: inspect(reason)})
    end
    end

    def items(conn, _),      do: conn |> put_status(:bad_request) |> json(%{error: "Missing ids"})
    def prices(conn, _),     do: conn |> put_status(:bad_request) |> json(%{error: "Missing ids"})
    def currencies(conn, _), do: conn |> put_status(:bad_request) |> json(%{error: "Missing ids"})

    defp normalize_ids(ids) when is_list(ids), do: Enum.map(ids, &to_string/1)
    defp normalize_ids(ids) when is_binary(ids), do: String.split(ids, ",", trim: true)
    defp normalize_ids(%{"ids" => ids}), do: normalize_ids(ids)
    defp normalize_ids(_), do: []


  def validate_key(conn, _),
    do: conn |> put_status(:bad_request) |> json(%{ok: false, error: "Missing key"})
end
