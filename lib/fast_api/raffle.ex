defmodule FastApi.Raffle do
  @moduledoc """
  Monthly raffle with single raffles table + users.raffle_signed.

  Behavior:
  - Items are snapshot from a configured GW2 character once per day.
  - Immediately after importing items (once per day), snapshot TP prices for those items.
  - If the raffle is already drawn, we DO NOT update prices/items anymore (frozen history).
  """
  import Ecto.Query
  alias FastApi.Repo
  alias FastApi.Schemas.Raffle, as: RaffleRow
  alias FastApi.Schemas.Auth.User
  alias FastApi.GW2.Client, as: GW2
  require Logger

  @cfg Application.compile_env(:fast_api, FastApi.Raffle, [])
  @api_key Keyword.get(@cfg, :api_key)
  @character Keyword.get(@cfg, :character)

  # Use DateTime (UTC) to satisfy @timestamps_opts [type: :utc_datetime]
  defp now_ts(), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp month_key(date \\ Date.utc_today()) do
    %Date{year: y, month: m} = date
    Date.new!(y, m, 1)
  end

  # Helpers: store maps in DB, expose lists to the rest of the module
  defp normalize_items(v) do
    cond do
      is_map(v) -> Map.get(v, "items", Map.get(v, :items, [])) || []
      is_list(v) -> v
      true -> []
    end
  end

  defp wrap_items(list) when is_list(list), do: %{"items" => list}
  defp wrap_winners(list) when is_list(list), do: %{"winners" => list}

  # upsert by month_key to avoid unique violations on concurrent first call
  def current_row() do
    key = month_key()

    case Repo.get_by(RaffleRow, month_key: key) do
      nil ->
        now = now_ts()

        {_count, _} =
          Repo.insert_all(
            RaffleRow,
            [
              %{
                month_key: key,
                status: "open",
                items: %{"items" => []},      # store as MAP
                winners: %{"winners" => []},  # store as MAP
                inserted_at: now,
                updated_at: now
              }
            ],
            on_conflict: :nothing,
            conflict_target: [:month_key]
          )

        Repo.get_by!(RaffleRow, month_key: key)

      row ->
        row
    end
  end

  # ---------------------------
  # PRIZES SNAPSHOT (GW2)
  # ---------------------------
  @doc """
  Daily job: refresh items from the configured GW2 character.

  After items are written for the **current open** month, we immediately refresh prices once (same daily run).
  If the current month is already drawn, we skip updates entirely (frozen).
  """
  def refresh_items_from_character(opts \\ []) do
    r = current_row()

    # If already drawn, do nothing (frozen history)
    if r.status == "drawn" do
      Logger.info("[raffle] month=#{r.month_key} is already drawn; skipping item refresh.")
      return_ok()
    else
      key =
        (Keyword.get(opts, :api_key) || @api_key || "")
        |> to_string()
        |> String.trim()

      char =
        (Keyword.get(opts, :character) || @character || "")
        |> to_string()
        |> String.trim()

      if key == "" do
        raise ArgumentError, "[raffle] RAFFLE_GW2_API_KEY missing (config or override)"
      end

      if char == "" do
        raise ArgumentError, "[raffle] RAFFLE_GW2_CHARACTER missing (config or override)"
      end

      Logger.info("[raffle] refreshing items from character=#{inspect(char)} month=#{r.month_key}")

      case GW2.character_inventory(key, char) do
        {:ok, %{"bags" => bags}} ->
          bag_count = Enum.count(bags || [])

          slots =
            (bags || [])
            |> Enum.flat_map(fn
              %{"inventory" => s} when is_list(s) -> s
              _ -> []
            end)

          raw_slots = Enum.count(slots)

          items =
            slots
            |> Enum.reduce(%{}, fn
              %{"id" => id, "count" => c}, acc when is_integer(id) ->
                Map.update(acc, id, max(c, 1), &(&1 + max(c, 1)))
              _s, acc -> acc
            end)
            |> Enum.map(fn {id, qty} -> %{"item_id" => id, "quantity" => qty} end)

          Logger.info("[raffle] parsed bags=#{bag_count} slots=#{raw_slots} unique_items=#{length(items)}")

          _ =
            r
            |> Ecto.Changeset.change(%{items: wrap_items(items), updated_at: now_ts()})
            |> Repo.update()

          Logger.info("[raffle] items written to DB for month=#{r.month_key}")

          # Immediately snapshot prices once per day for the open month
          _ = refresh_prices()

          :ok

        {:ok, other} ->
          raise RuntimeError, "[raffle] unexpected character_inventory payload: #{inspect(other, limit: 200)}"

        {:error, err} ->
          raise RuntimeError, "[raffle] GW2 character_inventory error: #{inspect(err)}"

        other ->
          raise RuntimeError, "[raffle] character_inventory returned unexpected value: #{inspect(other)}"
      end
    end
  end

  @doc """
  Merge GW2 TP prices into the current month's items and persist them.

  - Only runs when current month is **open**.
  - Skips if there are no items.
  - Does not store timestamps (kept simple).
  """
  def refresh_prices() do
    r = current_row()

    if r.status == "drawn" do
      Logger.info("[raffle] month=#{r.month_key} is drawn; skipping price refresh.")
      return_ok()
    else
      items = normalize_items(r.items)
      ids = Enum.map(items, & &1["item_id"]) |> Enum.uniq()

      if ids == [] do
        Logger.info("[raffle] no items to price for month=#{r.month_key}")
        :ok
      else
        Logger.info("[raffle] refreshing prices for #{length(ids)} items, month=#{r.month_key}")

        case GW2.prices(ids) do
          {:ok, prices} when is_list(prices) ->
            pmap =
              prices
              |> Enum.reduce(%{}, fn p, acc ->
                id = p["id"] || p[:id]
                buy = get_in(p, ["buys", "unit_price"]) || get_in(p, [:buys, :unit_price])
                sell = get_in(p, ["sells", "unit_price"]) || get_in(p, [:sells, :unit_price])
                if is_integer(id), do: Map.put(acc, id, %{buy: buy, sell: sell}), else: acc
              end)

            enriched =
              for it <- items do
                id = it["item_id"]
                pr = Map.get(pmap, id, %{})
                it
                |> Map.put("tp_buy", pr[:buy] || pr["buy"])
                |> Map.put("tp_sell", pr[:sell] || pr["sell"])
              end

            _ =
              r
              |> Ecto.Changeset.change(%{items: wrap_items(enriched), updated_at: now_ts()})
              |> Repo.update()

            Logger.info("[raffle] prices written to DB for month=#{r.month_key}")
            :ok

          {:error, err} ->
            Logger.error("[raffle] prices error: #{inspect(err)}")
            {:error, err}

          other ->
            Logger.error("[raffle] prices unexpected payload: #{inspect(other, limit: 200)}")
            {:error, :unexpected}
        end
      end
    end
  end

  # ---------------------------
  # MONTHLY ROLLOVER / SIGNUP / DRAW
  # ---------------------------

  def rollover_new_month() do
    _ = current_row()

    # auto-sign paying users
    from(u in User, where: u.verified == true and u.role_id != "free")
    |> Repo.update_all(set: [raffle_signed: true, updated_at: now_ts()])

    # reset free users
    from(u in User, where: u.verified == true and u.role_id == "free")
    |> Repo.update_all(set: [raffle_signed: false, updated_at: now_ts()])

    :ok
  end

  def signup(%User{id: id}) do
    {count, _} =
      from(u in User, where: u.id == ^id)
      |> Repo.update_all(set: [raffle_signed: true, updated_at: now_ts()])

    if count == 1, do: {:ok, :signed}, else: {:error, :not_found}
  end

  # Guard: only draw on the last calendar day, and don't re-draw if already drawn.
  def draw_current_month() do
    today = Date.utc_today()
    last_day? = today.day == Date.days_in_month(today)

    if last_day? do
      r = current_row()

      if r.status == "drawn" do
        {:ok, 0}
      else
        # Take a final price snapshot for the open month before freezing
        _ = refresh_prices()
        do_draw(r)
      end
    else
      {:ok, 0}
    end
  end

  # ---- Ticket weights ----
  # "free" => 1, "copper" => 5, "silver" => 10, "gold" => 25, "premium" => 50
  defp ticket_weight("premium"), do: 50
  defp ticket_weight("gold"),    do: 25
  defp ticket_weight("silver"),  do: 10
  defp ticket_weight("copper"),  do: 5
  defp ticket_weight(_),         do: 1

  defp present_ingame?(nil), do: false
  defp present_ingame?(name) when is_binary(name), do: String.trim(name) != ""
  defp present_ingame?(_), do: false

  defp do_draw(r) do
    items = normalize_items(r.items)

    raw =
      from(u in User,
        where: u.verified == true and u.raffle_signed == true,
        select: {u.ingame_name, u.role_id}
      )
      |> Repo.all()

    # Build pool as {ign, weight}; exclude users without IGN
    pool =
      raw
      |> Enum.reduce([], fn {ign, role}, acc ->
        if present_ingame?(ign) do
          [{String.trim(ign), ticket_weight(role)} | acc]
        else
          acc
        end
      end)

    winners =
      weighted_without_replacement(items, pool)
      |> Enum.map(fn %{item_id: item, user_ign: ign} ->
        %{"item_id" => item, "user_ign" => ign}
      end)

    _ =
      r
      |> Ecto.Changeset.change(%{winners: wrap_winners(winners), status: "drawn", updated_at: now_ts()})
      |> Repo.update()

    {:ok, length(winners)}
  end

  # pool: list of {ign :: String.t(), weight :: pos_integer()}
  defp weighted_without_replacement(items, pool) do
    expanded_items = for %{"item_id" => id, "quantity" => q} <- items, _ <- 1..max(q, 1), do: id
    tickets        = for {ign, w} <- pool, _ <- 1..max(w, 1), do: ign

    Enum.reduce(expanded_items, {MapSet.new(), [], tickets}, fn item, {used, acc, tix} ->
      avail = Enum.reject(tix, &MapSet.member?(used, &1))

      if avail == [] do
        {used, acc, tix}
      else
        pick_ign = Enum.random(avail)
        {MapSet.put(used, pick_ign), [%{item_id: item, user_ign: pick_ign} | acc], tix}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp return_ok(), do: :ok
end
