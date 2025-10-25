defmodule FastApi.Sync.Patreon do
  @moduledoc "Synchronize database with Patreon data."
  alias FastApi.Auth
  alias FastApi.Patreon.Client
  require Logger

  defp fmt_ms(ms) do
    total = div(ms, 1000)
    mins = div(total, 60)
    secs = rem(total, 60)
    "#{mins}:#{String.pad_leading(Integer.to_string(secs), 2, "0")} mins"
  end

  defp fetch_members() do
    case Client.active_patrons() do
      {:ok, members} when is_list(members) ->
        {:ok, members}

      {:error, _} = e ->
        e

      members when is_list(members) ->
        # Client returned a bare list (e.g., pagination error path). Treat as ok.
        {:ok, members}
    end
  end

  def sync_memberships() do
    t0 = System.monotonic_time(:millisecond)

    case fetch_members() do
      {:ok, members} ->
        refreshed =
          Enum.reduce(members, 0, fn
            %{email: email, role: role}, acc ->
              with user when not is_nil(user) <- Auth.get_user_by_email(email) do
                _ = Auth.set_role(user, role)
                acc + 1
              else
                _ -> acc
              end

            _, acc ->
              acc
          end)

        dt = System.monotonic_time(:millisecond) - t0
        Logger.info("[job] patreon.sync_memberships completed in #{fmt_ms(dt)} refreshed=#{refreshed} total_members=#{length(members)}")
        :ok

      {:error, err} ->
        dt = System.monotonic_time(:millisecond) - t0
        Logger.error("[job] patreon.sync_memberships failed in #{fmt_ms(dt)} error=#{inspect(err)}")
        :error
    end
  end

  def clear_memberships() do
    t0 = System.monotonic_time(:millisecond)
    users = Auth.all_users()

    case fetch_members() do
      {:ok, members} ->
        member_map =
          Map.new(members, fn
            %{email: email, role: role} -> {email, role}
            _ -> {nil, "free"}
          end)

        {pruned, updated, skipped_admin} =
          Enum.reduce(users, {0, 0, 0}, fn
            %{role_id: "admin"} = _user, {p, u, a} ->
              {p, u, a + 1}

            %{email: email} = user, {p, u, a} ->
              role = Map.get(member_map, email, "free")
              _ = Auth.set_role(user, role)
              if role == "free", do: {p + 1, u, a}, else: {p, u + 1, a}

            _user, acc ->
              acc
          end)

        dt = System.monotonic_time(:millisecond) - t0
        Logger.info("[job] patreon.clear_memberships completed in #{fmt_ms(dt)} pruned=#{pruned} updated=#{updated} admins_skipped=#{skipped_admin} users_total=#{length(users)}")
        :ok

      {:error, err} ->
        dt = System.monotonic_time(:millisecond) - t0
        Logger.error("[job] patreon.clear_memberships failed in #{fmt_ms(dt)} error=#{inspect(err)} users_total=#{length(users)}")
        :error
    end
  end
end
