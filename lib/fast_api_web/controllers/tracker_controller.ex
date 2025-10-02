defmodule FastApiWeb.TrackerController do
  use FastApiWeb, :controller

  @required_perms ~w(characters wallet inventories)

  defp encodable(term)
  defp encodable(term) when is_binary(term) or is_map(term) or is_list(term) or
                            is_integer(term) or is_float(term) or is_boolean(term) or is_nil(term),
    do: term
  defp encodable(%{__struct__: _} = struct) do
    try do
      Exception.message(struct)
    rescue
      _ -> inspect(struct, limit: 200)
    end
  end
  defp encodable(term), do: inspect(term, limit: 200)

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

      {:error, {:unexpected_status, status, body}} ->
        conn |> put_status(:bad_gateway) |> json(%{ok: false, error: "GW2 API error", status: status, upstream: encodable(body)})

      {:error, {:transport, info}} ->
        conn |> put_status(:bad_gateway) |> json(%{ok: false, error: "Upstream unreachable", reason: encodable(info)})
    end
  end

  def validate_key(conn, _),
    do: conn |> put_status(:bad_request) |> json(%{ok: false, error: "Missing key"})

  def characters(conn, %{"key" => key}) when is_binary(key) do
    case FastApi.GW2.Client.characters(key) do
      {:ok, names} -> json(conn, names)
      {:error, {:unexpected_status, status, body}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "GW2 API error", status: status, upstream: encodable(body)})
      {:error, {:transport, info}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "Upstream unreachable", reason: encodable(info)})
    end
  end

  def characters(conn, _),
    do: conn |> put_status(:bad_request) |> json(%{error: "Missing key"})

  def account_bank(conn, %{"key" => key}) when is_binary(key) do
    case FastApi.GW2.Client.account_bank(key) do
      {:ok, items} -> json(conn, items)
      {:error, {:unexpected_status, status, body}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "GW2 API error", status: status, upstream: encodable(body)})
      {:error, {:transport, info}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "Upstream unreachable", reason: encodable(info)})
    end
  end

  def account_bank(conn, _),
    do: conn |> put_status(:bad_request) |> json(%{error: "Missing key"})

  def account_materials(conn, %{"key" => key}) when is_binary(key) do
    case FastApi.GW2.Client.account_materials(key) do
      {:ok, materials} -> json(conn, materials)
      {:error, {:unexpected_status, status, body}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "GW2 API error", status: status, upstream: encodable(body)})
      {:error, {:transport, info}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "Upstream unreachable", reason: encodable(info)})
    end
  end

  def account_materials(conn, _),
    do: conn |> put_status(:bad_request) |> json(%{error: "Missing key"})

  def account_inventory(conn, %{"key" => key}) when is_binary(key) do
    case FastApi.GW2.Client.account_inventory(key) do
      {:ok, shared} -> json(conn, shared)
      {:error, {:unexpected_status, status, body}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "GW2 API error", status: status, upstream: encodable(body)})
      {:error, {:transport, info}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "Upstream unreachable", reason: encodable(info)})
    end
  end

  def account_inventory(conn, _),
    do: conn |> put_status(:bad_request) |> json(%{error: "Missing key"})

  def account_wallet(conn, %{"key" => key}) when is_binary(key) do
    case FastApi.GW2.Client.account_wallet(key) do
      {:ok, wallet} -> json(conn, wallet)
      {:error, {:unexpected_status, status, body}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "GW2 API error", status: status, upstream: encodable(body)})
      {:error, {:transport, info}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "Upstream unreachable", reason: encodable(info)})
    end
  end

  def account_wallet(conn, _),
    do: conn |> put_status(:bad_request) |> json(%{error: "Missing key"})

  def character_inventory(conn, %{"key" => key, "character" => character})
      when is_binary(key) and is_binary(character) do
    case FastApi.GW2.Client.character_inventory(key, character) do
      {:ok, inv} -> json(conn, inv)
      {:error, {:unexpected_status, status, body}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "GW2 API error", status: status, upstream: encodable(body)})
      {:error, {:transport, info}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "Upstream unreachable", reason: encodable(info)})
    end
  end

  def character_inventory(conn, _),
    do: conn |> put_status(:bad_request) |> json(%{error: "Missing key/character"})

  def characters_inventories(conn, %{"key" => key, "names" => names}) when is_binary(key) and is_list(names) do
    names =
      names
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if names == [] do
      return_bad_request(conn, "No character names provided")
    else
      max_concurrency = 6
      per_call_timeout = 25_000

      stream =
        Task.async_stream(
          names,
          fn name ->
            FastApi.GW2.Client.character_inventory(key, name, receive_timeout: per_call_timeout)
          end,
          max_concurrency: max_concurrency,
          timeout: per_call_timeout + 2_000,
          on_timeout: :kill_task
        )

      {ok_inventories, _errors} =
        Enum.zip(names, stream)
        |> Enum.reduce({[], []}, fn {name, result}, {oks, errs} ->
          case result do
            {:ok, {:ok, inv}} ->
              {[Map.put(inv, "character", name) | oks], errs}

            {:ok, {:error, reason}} ->
              {oks, [%{character: name, error: encodable(reason)} | errs]}

            {:exit, _} ->
              {oks, [%{character: name, error: "timeout"} | errs]}
          end
        end)

      json(conn, Enum.reverse(ok_inventories))
    end
  end

  def characters_inventories(conn, _),
    do: return_bad_request(conn, "Missing key or names")

  def items(conn, %{"ids" => ids}) do
    ids = normalize_ids(ids)

    case FastApi.GW2.Client.items(ids) do
      {:ok, list} -> json(conn, list)
      {:error, {:unexpected_status, status, body}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "GW2 API error", status: status, upstream: encodable(body)})
      {:error, {:transport, info}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "Upstream unreachable", reason: encodable(info)})
    end
  end
  def items(conn, _),
    do: return_bad_request(conn, "Missing ids")

  def prices(conn, %{"ids" => ids}) do
    ids = normalize_ids(ids)

    case FastApi.GW2.Client.prices(ids) do
      {:ok, list} -> json(conn, list)
      {:error, {:unexpected_status, status, body}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "GW2 API error", status: status, upstream: encodable(body)})
      {:error, {:transport, info}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "Upstream unreachable", reason: encodable(info)})
    end
  end
  def prices(conn, _),
    do: return_bad_request(conn, "Missing ids")

  def currencies(conn, %{"ids" => ids}) do
    ids = normalize_ids(ids)

    case FastApi.GW2.Client.currencies(ids) do
      {:ok, list} -> json(conn, list)
      {:error, {:unexpected_status, status, body}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "GW2 API error", status: status, upstream: encodable(body)})
      {:error, {:transport, info}} ->
        conn |> put_status(:bad_gateway) |> json(%{error: "Upstream unreachable", reason: encodable(info)})
    end
  end
  def currencies(conn, _),
    do: return_bad_request(conn, "Missing ids")

  defp normalize_ids(ids) when is_list(ids),    do: Enum.map(ids, &to_string/1)
  defp normalize_ids(ids) when is_binary(ids),  do: String.split(ids, ",", trim: true)
  defp normalize_ids(%{"ids" => ids}),          do: normalize_ids(ids)
  defp normalize_ids(_),                         do: []

  defp return_bad_request(conn, msg),
    do: conn |> put_status(:bad_request) |> json(%{error: msg})
end
