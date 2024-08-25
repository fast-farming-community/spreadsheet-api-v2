defmodule FastApi.PatreonTest do
  @moduledoc false
  use FastApiWeb.ConnCase

  alias FastApi.Auth
  alias FastApi.Schemas.Auth.User

  import Mock

  @default_user_attributes %{
    "email" => "user@fast.farming-community.eu",
    "password" => "Fast4Life!!!",
    "password_confirmation" => "Fast4Life!!!"
  }

  test "Sunny day" do
    with_mock FastApi.Patreon.Client,
      active_patrons: fn ->
        {:ok, [%{email: Map.get(@default_user_attributes, "email"), role: "tribune"}]}
      end do
      create_default_user()
      FastApi.Sync.Patreon.sync_memberships()

      assert "tribune" ==
               @default_user_attributes
               |> Map.get("email")
               |> Auth.get_user_by_email()
               |> Auth.get_user_role()
    end
  end

  defp create_default_user() do
    assert {:ok, %User{token: token}} = Auth.init_user(@default_user_attributes)

    assert {:ok, %User{} = user} =
             @default_user_attributes |> Map.put("token", token) |> Auth.create_user()

    user
  end
end
