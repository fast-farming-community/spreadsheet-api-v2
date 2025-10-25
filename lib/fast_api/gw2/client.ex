defmodule FastApi.GW2.Client do
  @moduledoc false
  @base "https://api.guildwars2.com"

  # Slightly higher network timeouts (safer for GW2 spikes)
  @connect_timeout 10_000
  @pool_timeout    10_000
  @receive_timeout 30_000

  @chunk_size_items      25
  @chunk_size_prices     25
  @chunk_size_currencies 50

  @max_concurrency 4
  @retry_attempts  3
  @retry_base_ms   200

  # Stream timeout ~= worst-case (receive_timeout * retries) + small buffer
  @stream_buffer_ms 5_000
  @stream_timeout (@receive_timeout * @retry_attempts) + @stream_buffer_ms

  defp finch_opts(extra) do
    Keyword.merge(
      [
        connect_timeout: @connect_timeout,
        pool_timeout:    @pool_timeout,
        receive_timeout: @receive_timeout
      ],
      extra
    )
  end

  # detect the maintenance splash so we can stop immediately on 503
  defp api_disabled?(body) when is_binary(body) do
    String.contains?(body, "API Temporarily disabled") or
      String.contains?(body, "Scheduled reactivation")
  end
  defp api_disabled?(_), do: false

  def get(path, opts \\ []) do
    url = @base <> path

    headers =
      case Keyword.get(opts, :token) do
        nil   -> []
        token -> [{"authorization", "Bearer " <> String.trim(token)}]
      end

    http_opts = Keyword.drop(opts, [:token])
    req = Finch.build(:get, url, headers)

    case Finch.request(req, FastApi.Finch, finch_opts(http_opts)) do
      {:ok, %Finch.Response{status: status, body: body}} ->
        case Jason.decode(body) do
          {:ok, json} -> {:ok, status, json}
          _           -> {:ok, status, body}
        end

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp with_retry(fun, attempts \\ @retry_attempts)
  defp with_retry(fun, attempts) when attempts > 1 do
    case fun.() do
      {:ok, 503, body} ->
        if api_disabled?(body) do
          {:error, :remote_disabled}
        else
          backoff(attempts)
          with_retry(fun, attempts - 1)
        end

      {:ok, status, _} when status in 500..599 ->
        backoff(attempts)
        with_retry(fun, attempts - 1)

      {:error, {:transport, _}} ->
        backoff(attempts)
        with_retry(fun, attempts - 1)

      other ->
        other
    end
  end

  defp with_retry(fun, _attempts), do: fun.()

  defp backoff(attempts_left) do
    step = @retry_attempts - attempts_left + 1
    :timer.sleep(@retry_base_ms * step)
  end

  defp chunked_get_list(path_base, ids, chunk_size) when is_list(ids) do
    ids
    |> Enum.map(&to_string/1)
    |> Enum.chunk_every(chunk_size)
    |> Task.async_stream(
      fn chunk ->
        qs = URI.encode_query(%{ids: Enum.join(chunk, ",")})
        with_retry(fn -> get(path_base <> "?" <> qs) end)
      end,
      max_concurrency: @max_concurrency,
      timeout: @stream_timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce({:ok, []}, fn
      {:ok, {:ok, 200, list}}, {:ok, acc} when is_list(list) -> {:ok, acc ++ list}
      {:ok, {:ok, 206, list}}, {:ok, acc} when is_list(list) -> {:ok, acc ++ list}
      {:ok, {:error, :remote_disabled}}, acc -> acc
      {:exit, _}, acc -> acc
      {:ok, _}, acc -> acc
      _, acc -> acc
    end)
    |> case do
      {:ok, list} -> {:ok, list}
      other -> other
    end
  end

  @doc """
  Validate a GW2 API key by calling /v2/tokeninfo.
  Returns {:ok, %{name: ..., permissions: [...]}} or {:error, reason}
  """
  def tokeninfo(key) when is_binary(key) do
    with_retry(fn -> get("/v2/tokeninfo", token: key) end)
    |> case do
      {:ok, 200, %{"name" => name, "permissions" => perms}} ->
        {:ok, %{name: name, permissions: perms}}

      {:ok, status, body} when status in [401, 403] ->
        {:error, {:unauthorized, body}}

      {:error, :remote_disabled} ->
        {:error, :remote_disabled}

      {:ok, status, body} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def characters(key) when is_binary(key) do
    with_retry(fn -> get("/v2/characters", token: key) end)
    |> case do
      {:ok, 200, json} when is_list(json) -> {:ok, json}
      {:error, :remote_disabled} -> {:error, :remote_disabled}
      {:ok, status, body}                 -> {:error, {:unexpected_status, status, body}}
      {:error, reason}                    -> {:error, reason}
    end
  end

  def account_bank(key) when is_binary(key) do
    with_retry(fn -> get("/v2/account/bank", token: key) end)
    |> case do
      {:ok, 200, json} when is_list(json) -> {:ok, json}
      {:error, :remote_disabled} -> {:error, :remote_disabled}
      {:ok, status, body}                 -> {:error, {:unexpected_status, status, body}}
      {:error, reason}                    -> {:error, reason}
    end
  end

  def account_materials(key) when is_binary(key) do
    with_retry(fn -> get("/v2/account/materials", token: key) end)
    |> case do
      {:ok, 200, json} when is_list(json) -> {:ok, json}
      {:error, :remote_disabled} -> {:error, :remote_disabled}
      {:ok, status, body}                 -> {:error, {:unexpected_status, status, body}}
      {:error, reason}                    -> {:error, reason}
    end
  end

  def account_inventory(key) when is_binary(key) do
    with_retry(fn -> get("/v2/account/inventory", token: key) end)
    |> case do
      {:ok, 200, json} when is_list(json) -> {:ok, json}
      {:error, :remote_disabled} -> {:error, :remote_disabled}
      {:ok, status, body}                 -> {:error, {:unexpected_status, status, body}}
      {:error, reason}                    -> {:error, reason}
    end
  end

  def account_wallet(key) when is_binary(key) do
    with_retry(fn -> get("/v2/account/wallet", token: key) end)
    |> case do
      {:ok, 200, json} when is_list(json) -> {:ok, json}
      {:error, :remote_disabled} -> {:error, :remote_disabled}
      {:ok, status, body}                 -> {:error, {:unexpected_status, status, body}}
      {:error, reason}                    -> {:error, reason}
    end
  end

  def character_inventory(key, character_name, opts \\ [])
      when is_binary(key) and is_binary(character_name) and is_list(opts) do
    encoded =
      character_name
      |> String.trim()
      |> URI.encode(&URI.char_unreserved?/1)

    with_retry(fn -> get("/v2/characters/#{encoded}/inventory", Keyword.put(opts, :token, key)) end)
    |> case do
      {:ok, 200, json} when is_map(json) -> {:ok, json}
      {:error, :remote_disabled} -> {:error, :remote_disabled}
      {:ok, status, body}                -> {:error, {:unexpected_status, status, body}}
      {:error, reason}                   -> {:error, reason}
    end
  end

  def items(ids) when is_list(ids),
    do: chunked_get_list("/v2/items", ids, @chunk_size_items)

  def prices(ids) when is_list(ids),
    do: chunked_get_list("/v2/commerce/prices", ids, @chunk_size_prices)

  def currencies(ids) when is_list(ids),
    do: chunked_get_list("/v2/currencies", ids, @chunk_size_currencies)

  def account(key) when is_binary(key) do
    with_retry(fn -> get("/v2/account", token: key) end)
    |> case do
      {:ok, 200, %{} = json} -> {:ok, json}  # includes full GW2 account (has "name")
      {:error, :remote_disabled} -> {:error, :remote_disabled}
      {:ok, status, body}    -> {:error, {:unexpected_status, status, body}}
      {:error, reason}       -> {:error, reason}
    end
  end
end
