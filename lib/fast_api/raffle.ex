defmodule FastApi.Raffle do
  @moduledoc "Monthly raffle with single raffles table + users.raffle_signed."
  import Ecto.Query
  alias FastApi.{Repo}
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
  # Manual/scheduled snapshot from character inventory into raffles.items.
  # Accepts optional overrides: refresh_items_from_character(character: "Name", api_key: "KEY")
  # Fails hard (raise) on missing config or GW2 errors; empty inventory is allowed.
  def refresh_items_from_character(opts \\ []) do
    r = current_row()

    # prefer overrides; fall back to compile-time config
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

        r
        |> Ecto.Changeset.change(%{items: wrap_items(items), updated_at: now_ts()})
        |> Repo.update()

        Logger.info("[raffle] items written to DB for month=#{r.month_key}")
        :ok

      {:ok, other} ->
        # Unexpected payload shape → crash so you can fix it
        raise RuntimeError, "[raffle] unexpected character_inventory payload: #{inspect(other, limit: 200)}"

      {:error, err} ->
        # GW2 client reported an error → crash
        raise RuntimeError, "[raffle] GW2 character_inventory error: #{inspect(err)}"

      other ->
        # Any other return → crash
        raise RuntimeError, "[raffle] character_inventory returned unexpected value: #{inspect(other)}"
    end
  end

  # ---------------------------
  # MONTHLY ROLLOVER / SIGNUP / DRAW
  # ---------------------------

  # MONTHLY (1st): ensure row, auto-sign paying, reset free
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

  # FREE users click to opt in; PAYING users are already auto-signed elsewhere.
  def signup(%User{id: id}) do
    {count, _} =
      from(u in User, where: u.id == ^id)
      |> Repo.update_all(set: [raffle_signed: true, updated_at: now_ts()])

    if count == 1, do: {:ok, :signed}, else: {:error, :not_found}
  end

  # Draw with per-role ticket weights; unique winners per month, one per item (quantity respected)
  # Guard: only draw on the last calendar day, and don't re-draw if already drawn.
  def draw_current_month() do
    today = Date.utc_today()
    last_day? = today.day == Date.days_in_month(today)

    if last_day? do
      r = current_row()

      if r.status == "drawn" do
        {:ok, 0}
      else
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
        select: {u.id, u.role_id, u.ingame_name}
      )
      |> Repo.all()

    # Build pool as {user_id, weight}
    # RULE: exclude ANY user (regardless of role) without ingame_name (no API key)
    pool =
      raw
      |> Enum.reduce([], fn {uid, role, ign}, acc ->
        if present_ingame?(ign) do
          [{uid, ticket_weight(role)} | acc]
        else
          acc
        end
      end)

    winners =
      weighted_without_replacement(items, pool)
      |> Enum.map(fn %{item_id: item, user_id: uid} -> %{"item_id" => item, "user_id" => uid} end)

    r
    |> Ecto.Changeset.change(%{winners: wrap_winners(winners), status: "drawn", updated_at: now_ts()})
    |> Repo.update()

    {:ok, length(winners)}
  end

  defp weighted_without_replacement(items, pool) do
    expanded_items = for %{"item_id" => id, "quantity" => q} <- items, _ <- 1..max(q, 1), do: id
    tickets        = for {uid, w} <- pool, _ <- 1..max(w, 1), do: uid

    Enum.reduce(expanded_items, {MapSet.new(), [], tickets}, fn item, {used, acc, tix} ->
      avail = Enum.reject(tix, &MapSet.member?(used, &1))

      if avail == [] do
        {used, acc, tix}
      else
        pick = Enum.random(avail)
        {MapSet.put(used, pick), [%{item_id: item, user_id: pick} | acc], tix}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end
end
