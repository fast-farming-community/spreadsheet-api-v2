defmodule FastApiWeb.Controllers.UserControllerTest do
  @moduledoc false
  use FastApiWeb.ConnCase

  alias FastApi.Test.Support.HttpClient

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(FastApi.Repo)
  end

  describe "Signup" do
    test "Sunny day" do
      assert {:ok, %{token: _}} =
               HttpClient.post("auth/signup", %{
                 email: "user@fast-farming-community.eu",
                 password: "Fast4Life!!!",
                 password_confirmation: "Fast4Life!!!"
               })
    end

    test "Invalid email and password" do
      assert {:ok,
              %{
                errors: %{
                  password: ["should be at least 12 character(s)"],
                  email: ["Must be a valid email address"],
                  password_confirmation: ["does not match confirmation"]
                }
              }} =
               HttpClient.post("auth/signup", %{
                 email: "userfast-farming-community.eu",
                 password: "Fast4Life!!",
                 password_confirmation: "Fast4Life!!!"
               })
    end
  end
end
