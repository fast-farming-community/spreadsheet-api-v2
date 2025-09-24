defmodule FastApi.Patreon.Client do
  @moduledoc "Patreon API Client."
  require Logger

  @tiers %{
    "23778194" => "copper",
    "5061127" => "silver",
    "5061143" => "gold",
    "5061144" => "premium"
  }

  def active_patrons() do
    "https://www.patreon.com/api/oauth2/v2/campaigns/#{Application.fetch_env!(:fast_api, :patreon_campaign)}/members?include=currently_entitled_tiers,address&fields%5Bmember%5D=email,is_follower,last_charge_date,last_charge_status,lifetime_support_cents,currently_entitled_amount_cents,patron_status&fields%5Btier%5D=title,amount_cents,created_at,edited_at,published,published_at,title"
    |> get_patrons()
    |> then(fn
      {:ok, result} ->
        patrons = Enum.flat_map(result.data, &build_patron/1)

        active_patrons(result, patrons)

      {:error, error} = e ->
        Logger.error("Error while querying Patreon: #{error}")
        e
    end)
  end

  defp get_patrons(link) do
    :get
    |> Finch.build(
      link,
      [
        {"Content-Type", "application/json"},
        {"Authorization", "Bearer #{Application.fetch_env!(:fast_api, :patreon_api_key)}"}
      ]
    )
    |> Finch.request(FastApi.Finch)
    |> then(fn
      {:ok, %Finch.Response{body: body}} ->
        {:ok, Jason.decode!(body, keys: :atoms)}

      {:error, error} = e ->
        Logger.error("Error while querying Patreon: #{error}")
        e
    end)
  end

  defp active_patrons(%{links: %{next: next}}, patrons) do
    next
    |> get_patrons()
    |> then(fn
      {:ok, result} ->
        active_patrons(result, patrons ++ Enum.flat_map(result.data, &build_patron/1))

      {:error, _} ->
        patrons
    end)
  end

  defp active_patrons(_, patrons) do
    {:ok, patrons}
  end

  defp build_patron(%{
         attributes: %{patron_status: "active_patron"} = patron,
         relationships: %{currently_entitled_tiers: %{data: [%{id: tier}]}}
       }) do
    role = Map.get(@tiers, tier, "free")
    [Map.put(patron, :role, role)]
  end

  defp build_patron(_) do
    []
  end
end
