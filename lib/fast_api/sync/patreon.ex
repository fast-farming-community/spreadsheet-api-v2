defmodule FastApi.Sync.Patreon do
  alias FastApi.Auth
  alias FastApi.Patreon.Client

  def sync_memberships() do
    {:ok, members} = Client.active_patrons()

    Enum.each(members, fn %{email: email, role: role} ->
      with user <- Auth.get_user_by_email(email) do
        Auth.set_role(user, role)
      end
    end)
  end
end
