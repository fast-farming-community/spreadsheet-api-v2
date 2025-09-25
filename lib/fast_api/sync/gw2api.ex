defmodule FastApi.Sync.GW2API do
  @moduledoc "Synchronize the spreadsheet using GW2 API data."
  import Ecto.Query, only: [from: 2]

  alias FastApi.Repo
  alias FastApi.Schemas.Fast

  require Logger

  @items "https://api.guildwars2.com/v2/items"
  @prices "https://api.guildwars2.com/v2/commerce/prices"
  @step 150

  # WIP: Cleanup
  @spec sync_items() :: :ok
  def sync_items do
    item_ids = get_item_ids()
    commerce_item_ids = get_commerce_item_ids()

    {tradable, non_tradable} = Enum.split_with(item_ids, &(&1 in commerce_item_ids))

    tradable
    |> get_details(@items)
    |> Enum.map(&to_item(&1, true))
    |> Enum.each(&Repo.insert(&1, on_conflict: :replace_all, conflict_target: [:id]))

    non_tradable
    |> get_details(@items)
    |> Enum.map(&to_item/1)
    |> Enum.each(&Repo.insert(&1, on_conflict: :replace_all, conflict_target: [:id]))

    :ok
  end

  @spec sync_prices() :: {:ok, non_neg_integer}
  def sync_prices do
    # --- START LINE (1/2) ---
    t0 = System.monotonic_time(:millisecond)
    Logger.info("[job] gw2.sync_prices — started")

    updated =
      from(item in Fast.Item,
        where: item.tradable == true,
        select: item
      )
      |> Repo.all()
      |> get_item_details()
      |> Enum.reduce(0, fn
        {%Fast.Item{id: id, vendor_value: vendor_value} = item,
         %{id: id, buys: %{"unit_price" => buy} = buys} = changes},
         acc ->
          buy = if is_nil(buy) or buy == 0, do: vendor_value, else: buy

          item
          |> Fast.Item.changeset(%{changes | buys: %{buys | "unit_price" => buy}})
          |> Repo.update()

          acc + 1

        {_item, _changes}, acc ->
          acc
      end)

    # --- END LINE (2/2) ---
    dt = System.monotonic_time(:millisecond) - t0
    Logger.info("[job] gw2.sync_prices — completed in #{dt}ms updated=#{updated}")

    {:ok, updated}
  end

  defp get_item_details(items) do
    items
    |> Enum.chunk_every(@step)
    |> Enum.flat_map(fn chunk ->
      ids      = Enum.map(chunk, & &1.id)
      req_url  = "#{@prices}?ids=#{Enum.map_join(chunk, ",", & &1.id)}"

      result =
        Finch.build(:get, req_url)
        |> request_json()
        |> Enum.map(fn
          %{} = m -> keys_to_atoms(m)
          other ->
            Logger.error("GW2 prices API unexpected element (no map) for #{req_url}: #{inspect(other)}")
            %{}
        end)

      # Separate good rows (with :id) from bad rows (missing :id)
      {good, bad} = Enum.split_with(result, &match?(%{id: _}, &1))

      if bad != [] do
        sample = Enum.take(bad, 3)
        Logger.error("""
        GW2 prices API returned #{length(bad)} bad records WITHOUT :id for #{req_url}
        bad_samples=#{inspect(sample, pretty: true, limit: :infinity, printable_limit: :infinity)}
        requested_ids=#{inspect(ids)}
        """)
      end

      # Build a map by id for stable pairing
      result_by_id = for %{id: id} = m <- good, into: %{}, do: {id, m}

      # Partition requested chunk into matching/missing ids
      {matching, missing} = Enum.split_with(chunk, fn item -> Map.has_key?(result_by_id, item.id) end)

      if missing != [] do
        missing_ids = Enum.map(missing, & &1.id)
        Logger.error("GW2 prices API missing entries for ids=#{inspect(missing_ids)} url=#{req_url}")
      end

      # Return only pairs that we actually have data for
      Enum.map(matching, fn item -> {item, Map.fetch!(result_by_id, item.id)} end)
    end)
  end

  def sync_sheet do
    # --- START LINE (1/2) ---
    t0 = System.monotonic_time(:millisecond)
    Logger.info("[job] gw2.sync_sheet — started")

    {:ok, updated_prices} = sync_prices()

    items =
      Fast.Item
      |> Repo.all()
      |> Enum.map(fn %Fast.Item{} = item ->
        [item.id, item.name, item.buy, item.sell, item.icon, item.rarity, item.vendor_value]
      end)
      |> Enum.sort_by(&List.first/1)

    {:ok, token} = Goth.fetch(FastApi.Goth)
    connection = GoogleApi.Sheets.V4.Connection.new(token.token)

    {:ok, _response} =
      GoogleApi.Sheets.V4.Api.Spreadsheets.sheets_spreadsheets_values_update(
        connection,
        "1WdwWxyP9zeJhcxoQAr-paMX47IuK6l5rqAPYDOA8mho",
        "API!A4:G#{4 + length(items)}",
        body: %{values: items},
        valueInputOption: "RAW"
      )

    # --- END LINE (2/2) ---
    dt = System.monotonic_time(:millisecond) - t0
    Logger.info("[job] gw2.sync_sheet — completed in #{dt}ms prices_updated=#{updated_prices} rows_written=#{length(items)}")

    :ok
  end

  defp get_details(ids, base_url) do
    ids
    |> Enum.chunk_every(@step)
    |> Enum.flat_map(fn chunk ->
      req_url = "#{base_url}?ids=#{Enum.join(chunk, ",")}"

      Finch.build(:get, req_url)
      |> request_json()
      |> tap(fn
        result when length(result) == length(chunk) ->
          :ok

        result ->
          missing_ids = chunk -- Enum.map(result, &Map.get(&1, "id"))
          Logger.error("Missing IDs for #{req_url}: #{inspect(missing_ids)}")
      end)
    end)
    |> Enum.map(&keys_to_atoms/1)
  end

  defp get_item_ids do
    Finch.build(:get, @items)
    |> request_json()
  end

  defp get_commerce_item_ids do
    Finch.build(:get, @prices)
    |> request_json()
  end

  defp request_json(request, retry \\ 0) do
    case Finch.request(request, FastApi.Finch) do
      {:ok, %Finch.Response{status: status, body: body}} ->
        case Jason.decode(body) do
          {:ok, decoded} when is_list(decoded) ->
            if status != 200 do
              Logger.error("HTTP #{status} with list body from remote: #{inspect(Enum.take(decoded, 1))}")
            end
            decoded

          {:ok, decoded} when is_map(decoded) ->
            if status != 200 do
              Logger.error("HTTP #{status} with map body from remote: #{inspect(decoded)}")
            end
            [decoded]

          {:ok, other} ->
            Logger.error("Unexpected JSON shape (status #{status}): #{inspect(other)}")
            []

          {:error, error} ->
            Logger.error("Failed to decode JSON (status #{status}): #{inspect(error)} body_snippet=#{inspect(String.slice(to_string(body), 0, 400))}")
            []
        end

      {:error, %Mint.TransportError{reason: :timeout}} when retry < 5 ->
        Logger.warning("HTTP timeout (#{retry + 1}/5), retrying…")
        request_json(request, retry + 1)

      {:error, error} ->
        Logger.error("HTTP request error: #{inspect(error)}")
        []
    end
  end

  defp keys_to_atoms(map) do
    Enum.into(map, %{}, fn {key, value} -> {String.to_atom(key), value} end)
  end

  defp to_item(params, tradable \\ false) do
    params
    |> Map.put(:tradable, tradable)
    |> then(&struct(Fast.Item, &1))
  end
end
