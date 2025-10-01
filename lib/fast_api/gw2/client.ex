defmodule FastApi.GW2.Client do
  @moduledoc false
  @base "https://api.guildwars2.com"

  # tune these once here
  @connect_timeout 5_000
  @pool_timeout    5_000
  @receive_timeout 15_000   # > 5s to avoid the 5s cutoff

  def get(path, opts \\ []) do
    url = @base <> path

    headers =
      case Keyword.get(opts, :token) do
        nil   -> []
        token -> [{"authorization", "Bearer " <> String.trim(token)}]
      end

    req = Finch.build(:get, url, headers)

    # IMPORTANT: pass timeouts to Finch.request/3
    finch_opts = [
      connect_timeout: @connect_timeout,
      pool_timeout: @pool_timeout,
      receive_timeout: @receive_timeout
    ]

    case Finch.request(req, FastApi.Finch, finch_opts) do
      {:ok, %Finch.Response{status: status, body: body}} ->
        case Jason.decode(body) do
          {:ok, json} -> {:ok, status, json}
          _           -> {:ok, status, body}
        end

      {:error, reason} ->
        # Normalize to help controllers return a clean 502
        {:error, {:transport, reason}}
    end
  end

  @doc """
  Validate a GW2 API key by calling /v2/tokeninfo.
  Returns {:ok, %{name: ..., permissions: [...]}} or {:error, reason}
  """
  def tokeninfo(key) when is_binary(key) do
    case get("/v2/tokeninfo", token: key) do
      {:ok, 200, %{"name" => name, "permissions" => perms}} ->
        {:ok, %{name: name, permissions: perms}}

      {:ok, status, body} when status in [401, 403] ->
        {:error, {:unauthorized, body}}

      {:ok, status, body} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def characters(key) when is_binary(key) do
    case get("/v2/characters", token: key) do
      {:ok, 200, json} when is_list(json) -> {:ok, json}
      {:ok, status, body}                 -> {:error, {:unexpected_status, status, body}}
      {:error, reason}                    -> {:error, reason}
    end
  end

  def account_bank(key) when is_binary(key) do
    case get("/v2/account/bank", token: key) do
      {:ok, 200, json} when is_list(json) -> {:ok, json}
      {:ok, status, body}                 -> {:error, {:unexpected_status, status, body}}
      {:error, reason}                    -> {:error, reason}
    end
  end

  def account_materials(key) when is_binary(key) do
    case get("/v2/account/materials", token: key) do
      {:ok, 200, json} when is_list(json) -> {:ok, json}
      {:ok, status, body}                 -> {:error, {:unexpected_status, status, body}}
      {:error, reason}                    -> {:error, reason}
    end
  end

  def account_inventory(key) when is_binary(key) do
    case get("/v2/account/inventory", token: key) do
      {:ok, 200, json} when is_list(json) -> {:ok, json}
      {:ok, status, body}                 -> {:error, {:unexpected_status, status, body}}
      {:error, reason}                    -> {:error, reason}
    end
  end

  def account_wallet(key) when is_binary(key) do
    case get("/v2/account/wallet", token: key) do
      {:ok, 200, json} when is_list(json) -> {:ok, json}
      {:ok, status, body}                 -> {:error, {:unexpected_status, status, body}}
      {:error, reason}                    -> {:error, reason}
    end
  end

  def character_inventory(key, character_name) when is_binary(key) and is_binary(character_name) do
    encoded =
      character_name
      |> String.trim()
      |> URI.encode(&URI.char_unreserved?/1)

    case get("/v2/characters/#{encoded}/inventory", token: key) do
      {:ok, 200, json} when is_map(json) -> {:ok, json}
      {:ok, status, body}                -> {:error, {:unexpected_status, status, body}}
      {:error, reason}                   -> {:error, reason}
    end
  end

  def items(ids) when is_list(ids) do
    qs = URI.encode_query(%{ids: Enum.join(ids, ",")})
    case get("/v2/items?" <> qs) do
      {:ok, 200, json} when is_list(json) -> {:ok, json}
      {:ok, status, body}                 -> {:error, {:unexpected_status, status, body}}
      {:error, reason}                    -> {:error, reason}
    end
  end

  def prices(ids) when is_list(ids) do
    qs = URI.encode_query(%{ids: Enum.join(ids, ",")})
    case get("/v2/commerce/prices?" <> qs) do
      {:ok, 200, json} when is_list(json) -> {:ok, json}
      {:ok, status, body}                 -> {:error, {:unexpected_status, status, body}}
      {:error, reason}                    -> {:error, reason}
    end
  end

  def currencies(ids) when is_list(ids) do
    qs = URI.encode_query(%{ids: Enum.join(ids, ",")})
    case get("/v2/currencies?" <> qs) do
      {:ok, 200, json} when is_list(json) -> {:ok, json}
      {:ok, status, body}                 -> {:error, {:unexpected_status, status, body}}
      {:error, reason}                    -> {:error, reason}
    end
  end
end
