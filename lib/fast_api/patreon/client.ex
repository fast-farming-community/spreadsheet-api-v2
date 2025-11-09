defmodule FastApi.Patreon.Client do
  @moduledoc "Patreon API Client."
  require Logger

  @tiers %{
    "23778194" => "copper",
    "5061127"  => "silver",
    "5061143"  => "gold",
    "5061144"  => "premium"
  }

  @base "https://www.patreon.com/api/oauth2/v2"
  @default_headers [
    {"Accept", "application/json"},
    {"Content-Type", "application/json"}
  ]

  @doc """
  Fetch all active patrons with pagination.

  Returns:
    - {:ok, patrons :: list()}
    - {:error, reason} when the *first* request fails hard (auth/network)
  """
  def active_patrons() do
    campaign_id = Application.fetch_env!(:fast_api, :patreon_campaign)

    url =
      "#{@base}/campaigns/#{campaign_id}/members" <>
        "?include=currently_entitled_tiers,address" <>
        "&fields%5Bmember%5D=email,is_follower,last_charge_date,last_charge_status,lifetime_support_cents,currently_entitled_amount_cents,patron_status" <>
        "&fields%5Btier%5D=title,amount_cents,created_at,edited_at,published,published_at,title"

    with {:ok, first} <- get_patrons(url) do
      patrons = Enum.flat_map(first.data, &build_patron/1)
      paginate_and_accumulate(first, patrons)
    else
      {:error, reason} = e ->
        Logger.error("Patreon initial query failed: #{inspect(reason)}")
        e
    end
  end

  defp get_patrons(link) when is_binary(link) do
    headers =
      [{"Authorization", "Bearer #{Application.fetch_env!(:fast_api, :patreon_api_key)}"},
      {"User-Agent", "fast-api/1.0"} | @default_headers]

    req = Finch.build(:get, link, headers)

    case Finch.request(req, FastApi.FinchJobs) do
      {:ok, %Finch.Response{status: status, headers: _resp_headers, body: body}}
      when status in 200..299 ->
        case safe_decode_json(body) do
          {:ok, json} -> {:ok, json}
          {:error, decode_err} ->
            Logger.error("Patreon JSON decode error (#{status}): #{inspect(decode_err)} body=#{preview(body)}")
            {:error, :invalid_json}
        end

      {:ok, %Finch.Response{status: status, headers: resp_headers, body: body}} ->
        ctype = content_type(resp_headers)
        Logger.warning("Patreon unexpected status #{status} ctype=#{inspect(ctype)} body=#{preview(body)}")
        {:error, {:unexpected_status, status, ctype}}

      {:error, reason} ->
        Logger.error("Patreon transport error: #{inspect(reason)}")
        {:error, {:transport, reason}}
    end
  end

  defp safe_decode_json(body) do
    case Jason.decode(body, keys: :atoms) do
      {:ok, json} -> {:ok, json}
      {:error, err} -> {:error, err}
    end
  end

  defp content_type(headers) do
    headers
    |> Enum.find_value(fn {k, v} -> if String.downcase(k) == "content-type", do: v end)
  end

  defp preview(body) when is_binary(body) do
    body |> String.slice(0, 200) |> String.replace("\n", " ")
  end

  defp paginate_and_accumulate(%{links: %{next: next}} = _page, patrons) when is_binary(next) do
    case get_patrons(next) do
      {:ok, page} ->
        new = patrons ++ Enum.flat_map(page.data, &build_patron/1)
        paginate_and_accumulate(page, new)

      {:error, reason} ->
        # Be tolerant: keep what we have but normalize shape.
        Logger.warning("Patreon pagination stopped due to error: #{inspect(reason)}")
        {:ok, patrons}
    end
  end

  defp paginate_and_accumulate(_page, patrons), do: {:ok, patrons}

  defp build_patron(%{
         attributes: %{patron_status: "active_patron"} = attrs,
         relationships: %{currently_entitled_tiers: %{data: [%{id: tier_id}]}}
       }) do
    role = Map.get(@tiers, tier_id, "free")
    [Map.put(attrs, :role, role)]
  end

  defp build_patron(_), do: []
end
