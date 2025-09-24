defmodule FastApi.Sync.Patreon do
  @moduledoc "Synchronize database with Patreon data."
  alias FastApi.Auth
  alias FastApi.Patreon.Client

  def sync_memberships() do
    {:ok, members} = Client.active_patrons()

    Enum.each(members, fn %{email: email, role: role} ->
      with user when not is_nil(user) <- Auth.get_user_by_email(email) do
        Auth.set_role(user, role)
      end
    end)
  end

  def clear_memberships() do
    users = Auth.all_users()
    {:ok, members} = Client.active_patrons()

    Enum.each(
      users,
      fn
        %{role_id: "admin"} ->
          :ok

        %{email: email} = user ->
          members
          |> Enum.find_value("free", fn
            %{email: ^email, role: role} -> role
            _ -> false
          end)
          |> then(&Auth.set_role(user, &1))
      end
    )
  end
end
