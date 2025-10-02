defmodule FastApi.GW2.Client do
  @moduledoc false
  @base "https://api.guildwars2.com"

  # --- timeouts & batching knobs ---
  @connect_timeout 5_000
  @pool_timeout    5_000
  @receive_timeout 15_000

  @chunk_size_items      25
  @chunk_size_prices     25
  @chunk_size_currencies 50

  @max_concurrency 4
  @retry_attempts  3
  @retry_base_ms   200

  # -------- core request --------
  defp finch_opts do
    [
      connect_timeout: @connect_timeout,
      pool_timeout:    @pool_timeout,
      receive_timeout: @receive_timeout
    ]
  end

  def get(path, opts \\ []) do
    url = @base <> path

    headers =
      case Keyword.get(opts, :token) do
        nil   -> []
        token -> [{"authorization", "Bearer " <> String.trim(token)}]
      end

    req = Finch.build(:get, url, headers)

    case Finch.request(req, FastApi.Finch, finch_opts()) do
      {:ok, %Finch.Response{status: status, body: body}} ->
        case Jason.decode(body) do
          {:ok, json} -> {:ok, status, json}
          _           -> {:ok, status, body}
        end

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  # -------- retry wrapper --------
  defp with_retry(fun, attempts \\ @retry_attempts)

  defp with_retry(fun, attempts) when attempts > 1 do
    case fun.() do
      {:ok, _status, _} = ok -> ok
      {:error, {:transport, _} = err} ->
        backoff(attempts)
        with_retry(fun, attempts - 1)
      {:ok, status, _} = resp when status in 500..599 ->
        backoff(attempts)
        with_retry(fun, attempts - 1)
      other ->
        other
    end
  end

  defp with_retry(fun, _attempts), do: fun.()

  defp backoff(attempts_left) do
    # simple exponential-ish backoff
    step = @retry_attempts - attempts_left + 1
    :timer.sleep(@retry_base_ms * step)
  end

  # -------- helpers for chunked list endpoints --------
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
      timeout: @receive_timeout + 5_000
    )
    |> Enum.reduce({:ok, []}, fn
      {:ok, {:ok, 200, list}}, {:ok, acc} when is_list(list) ->
        {:ok, acc ++ list}

      {:ok, {:ok, 206, list}}, {:ok, acc} when is_list(list) ->
        # GW2 sometimes replies 206 for partial content; still merge what we got
        {:ok, acc ++ list}

      {:ok, {:ok, status, body}}, {:ok, acc} when status in 400..499 ->
        # hard client error for this chunk; keep going but remember failure
        {:partial_error, acc, {:unexpected_status, status, body}}

      {:ok, {:error, reason}}, {:ok, acc} ->
        {:partial_error, acc, reason}

      {:ok, other}, {:ok, acc} ->
        {:partial_error, acc, {:unknown, other}}

      # if we already had a partial error, keep merging successes but retain the error tag
      {:ok, {:ok, 200, list}}, {:partial_error, acc, err} when is_list(list) ->
        {:partial_error, acc ++ list, err}

      _chunk_result, error_acc ->
        error_acc
    end)
    |> case do
      {:ok, list} ->
        {:ok, list}

      {:partial_error, list, err} ->
        # surface partial results but mark the error for the caller if needed;
        # here we choose to return {:ok, list} so the controller can still respond 200.
        # If you prefer to fail the whole request, switch to: {:error, err}
        {:ok, list}
    end
  end

  # -------- token + account endpoints (single calls) --------
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
      {:ok, status, body}                 -> {:error, {:unexpected_status, status, body}}
      {:error, reason}                    -> {:error, reason}
    end
  end

  def account_bank(key) when is_binary(key) do
    with_retry(fn -> get("/v2/account/bank", token: key) end)
    |> case do
      {:ok, 200, json} when is_list(json) -> {:ok, json}
      {:ok, status, body}                 -> {:error, {:unexpected_status, status, body}}
      {:error, reason}                    -> {:error, reason}
    end
  end

  def account_materials(key) when is_binary(key) do
    with_retry(fn -> get("/v2/account/materials", token: key) end)
    |> case do
      {:ok, 200, json} when is_list(json) -> {:ok, json}
      {:ok, status, body}                 -> {:error, {:unexpected_status, status, body}}
      {:error, reason}                    -> {:error, reason}
    end
  end

  def account_inventory(key) when is_binary(key) do
    with_retry(fn -> get("/v2/account/inventory", token: key) end)
    |> case do
      {:ok, 200, json} when is_list(json) -> {:ok, json}
      {:ok, status, body}                 -> {:error, {:unexpected_status, status, body}}
      {:error, reason}                    -> {:error, reason}
    end
  end

  def account_wallet(key) when is_binary(key) do
    with_retry(fn -> get("/v2/account/wallet", token: key) end)
    |> case do
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

    with_retry(fn -> get("/v2/characters/#{encoded}/inventory", token: key) end)
    |> case do
      {:ok, 200, json} when is_map(json) -> {:ok, json}
      {:ok, status, body}                -> {:error, {:unexpected_status, status, body}}
      {:error, reason}                   -> {:error, reason}
    end
  end

  # -------- catalog endpoints (chunked + retries) --------
  def items(ids) when is_list(ids),
    do: chunked_get_list("/v2/items", ids, @chunk_size_items)

  def prices(ids) when is_list(ids),
    do: chunked_get_list("/v2/commerce/prices", ids, @chunk_size_prices)

  def currencies(ids) when is_list(ids),
    do: chunked_get_list("/v2/currencies", ids, @chunk_size_currencies)
end
