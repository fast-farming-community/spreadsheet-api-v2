defmodule FastApi.Patreon.Client do
  @moduledoc "Patreon API Client."
  require Logger

  @tiers %{
    "5061127" => "legionnaire",
    "5061143" => "tribunte",
    "5061144" => "khan-ur"
  }

  def active_patrons() do
    :get
    |> Finch.build(
      "https://www.patreon.com/api/oauth2/v2/campaigns/#{Application.fetch_env!(:fast_api, :patreon_campaign)}/members?include=currently_entitled_tiers,address&fields%5Bmember%5D=email,is_follower,last_charge_date,last_charge_status,lifetime_support_cents,currently_entitled_amount_cents,patron_status&fields%5Btier%5D=title,amount_cents,created_at,edited_at,published,published_at,title",
      [
        {"Content-Type", "application/json"},
        {"Authorization", "Bearer #{Application.fetch_env!(:fast_api, :patreon_api_key)}"}
      ]
    )
    |> Finch.request(FastApi.Finch)
    |> then(fn
      {:ok, %Finch.Response{body: body}} ->
        body
        |> Jason.decode!(keys: :atoms)
        |> then(& &1.data)
        |> Enum.flat_map(&build_patron/1)
        |> then(&{:ok, &1})

      {:error, error} = e ->
        Logger.error("Error while querying Patreon: #{error}")
        e
    end)
  end

  defp build_patron(%{
         attributes: %{patron_status: "active_patron"} = patron,
         relationships: %{currently_entitle_tiers: %{data: [%{id: tier}]}}
       }) do
    role = Map.get(@tiers, tier, "soldier")
    [Map.put(patron, :role, role)]
  end

  defp build_patron(_) do
    []
  end
end
