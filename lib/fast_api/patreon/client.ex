defmodule FastApi.Patreon.Client do
  require Logger

  def active_patrons() do
    :get
    |> Finch.build(
      "https://www.patreon.com/api/oauth2/v2/campaigns/#{Application.fetch_env!(:fast_api, :patreon_campaign)}/members?include=currently_entitled_tiers,address&fields%5Bmember%5D=email,is_follower,last_charge_date,last_charge_status,lifetime_support_cents,currently_entitled_amount_cents,patron_status&fields%5Btier%5D=amount_cents,created_at,edited_at,published,published_at,title",
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
        |> Enum.flat_map(fn
          %{attributes: %{patron_status: "active_patron"} = patron} -> [patron]
          _ -> []
        end)
        |> then(&{:ok, &1})

      {:error, error} = e ->
        Logger.error("Error while querying Patreon: #{error}")
        e
    end)
  end
end
