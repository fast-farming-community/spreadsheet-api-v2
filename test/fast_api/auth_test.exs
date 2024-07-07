defmodule FastApi.AuthTest do
  @moduledoc false
  use ExUnit.Case

  alias FastApi.Auth
  alias FastApi.Schemas.Auth.User

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(FastApi.Repo)
  end

  test "create_user/1 with valid data creates a user" do
    assert {:ok, %User{} = user} =
             Auth.create_user(%{email: "user@fast.farming-community.eu", password: "Fast4Life"})

    assert Bcrypt.verify_pass("Fast4Life", user.password)
  end
end
