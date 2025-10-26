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

  # DAILY: snapshot items from character inventory into raffles.items
  def refresh_items_from_character() do
    r = current_row()

    cond do
      is_nil(@api_key) or @api_key == "" ->
        Logger.warning("raffle refresh skipped: RAFFLE_GW2_API_KEY missing")
        :ok

      is_nil(@character) or @character == "" ->
        Logger.warning("raffle refresh skipped: RAFFLE_GW2_CHARACTER missing")
        :ok

      true ->
        case GW2.character_inventory(@api_key, @character) do
          {:ok, %{"bags" => bags}} ->
            items =
              bags
              |> Enum.flat_map(fn
                %{"inventory" => slots} when is_list(slots) -> slots
                _ -> []
              end)
              |> Enum.reduce(%{}, fn
                %{"id" => id, "count" => c}, acc when is_integer(id) ->
                  Map.update(acc, id, max(c, 1), &(&1 + max(c, 1)))
                _s, acc -> acc
              end)
              |> Enum.map(fn {id, qty} -> %{"item_id" => id, "quantity" => qty} end)

            r
            |> Ecto.Changeset.change(%{items: wrap_items(items), updated_at: now_ts()})
            |> Repo.update()

            :ok

          other ->
            Logger.warning("raffle refresh failed: #{inspect(other)}")
            :ok
        end
    end
  end

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

  # Draw paying=5 tickets, free=1; unique winners per month, one per item (quantity respected)
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

  defp do_draw(r) do
    items = normalize_items(r.items)

    pool =
      from(u in User, where: u.verified == true and u.raffle_signed == true,
        select: {u.id, fragment("CASE WHEN ? <> 'free' THEN 5 ELSE 1 END", u.role_id)}
      )
      |> Repo.all()

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
