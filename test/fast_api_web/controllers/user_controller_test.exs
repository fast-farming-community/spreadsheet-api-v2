defmodule FastApiWeb.Controllers.UserControllerTest do
  @moduledoc false
  use FastApiWeb.ConnCase

  alias FastApi.Test.Support.HttpClient

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(FastApi.Repo)
  end

  describe "Signup" do
    test "Sunny day" do
      assert {:ok, tokens} =
               HttpClient.post("auth/signup", %{
                 email: "user@fast-farming-community.eu",
                 password: "Fast4Life!!!",
                 password_confirmation: "Fast4Life!!!"
               })

      verify_tokens(tokens)
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

  describe "login" do
    test "Sunny day" do
      assert {:ok, tokens} =
               HttpClient.post("auth/signup", %{
                 email: "user@fast-farming-community.eu",
                 password: "Fast4Life!!!",
                 password_confirmation: "Fast4Life!!!"
               })

      verify_tokens(tokens)

      assert {:ok, tokens} =
               HttpClient.post("auth/login", %{
                 email: "user@fast-farming-community.eu",
                 password: "Fast4Life!!!"
               })

      verify_tokens(tokens)
    end

    test "Invalid password" do
      assert {:ok, %{access: _}} =
               HttpClient.post("auth/signup", %{
                 email: "user@fast-farming-community.eu",
                 password: "Fast4Life!!!",
                 password_confirmation: "Fast4Life!!!"
               })

      assert {:ok, %{error: "Invalid username/password combination"}} =
               HttpClient.post("auth/login", %{
                 email: "user@fast-farming-community.eu",
                 password: "Cornix4Life!!!"
               })
    end
  end

  describe "refresh" do
    test "Sunny day" do
      assert {:ok, %{refresh: refresh}} =
               HttpClient.post("auth/signup", %{
                 email: "user@fast-farming-community.eu",
                 password: "Fast4Life!!!",
                 password_confirmation: "Fast4Life!!!"
               })

      assert {:ok, tokens} = HttpClient.post("auth/refresh", %{token: refresh})

      verify_tokens(tokens)
    end

    test "Expired refresh token" do
      temp_env(:refresh_token_ttl, {1, :seconds})

      assert {:ok, %{refresh: refresh}} =
               HttpClient.post("auth/signup", %{
                 email: "user@fast-farming-community.eu",
                 password: "Fast4Life!!!",
                 password_confirmation: "Fast4Life!!!"
               })

      Process.sleep(2_000)

      assert {:ok, %{error: "Invalid or Expired Refresh Token"}} =
               HttpClient.post("auth/refresh", %{token: refresh})
    end
  end

  defp temp_env(key, value) do
    original_value = Application.fetch_env!(:fast_api, key)
    Application.put_env(:fast_api, key, value)
    on_exit(fn -> Application.put_env(:fast_api, key, original_value) end)
  end

  defp verify_tokens(%{access: access, refresh: refresh}) do
    assert {:ok, %{"typ" => "access"}} =
             FastApi.Auth.Token.decode_and_verify(access, %{"role" => "soldier"})

    assert {:ok, %{"typ" => "refresh"}} =
             FastApi.Auth.Token.decode_and_verify(refresh, %{"role" => "soldier"})
  end
end
