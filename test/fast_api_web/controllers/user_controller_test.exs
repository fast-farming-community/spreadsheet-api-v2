defmodule FastApiWeb.Controllers.UserControllerTest do
  @moduledoc false
  use FastApiWeb.ConnCase

  alias FastApi.Auth
  alias FastApi.Test.Support.HttpClient
  alias FastApi.Schemas.Auth.User

  import Swoosh.TestAssertions

  @default_user_attributes %{
    "email" => "user@fast.farming-community.eu",
    "password" => "Fast4Life!!!",
    "password_confirmation" => "Fast4Life!!!"
  }

  describe "pre-register" do
    test "Sunny day" do
      set_swoosh_global()

      assert {:ok, %{success: _}} = HttpClient.post("auth/pre-register", @default_user_attributes)

      user = @default_user_attributes |> Map.get("email") |> Auth.get_user_by_email()

      assert_email_sent(FastApiWeb.Notifiers.PreRegistrationNotifier.pre_register(user))
    end

    test "Invalid email" do
      assert {:ok, %{errors: %{email: ["Must be a valid email address"]}}} =
               HttpClient.post("auth/pre-register", %{
                 email: "userfast.farming-community.eu"
               })
    end
  end

  describe "register" do
    test "Sunny day" do
      assert {:ok, tokens} = create_user()

      verify_tokens(tokens)
    end

    test "Invalid password" do
      assert {:ok,
              %{
                errors: %{
                  password: ["should be at least 12 character(s)"],
                  password_confirmation: ["does not match confirmation"]
                }
              }} =
               create_user(%{
                 "password" => "Fast4Life!!",
                 "password_confirmation" => "Fast4Life!!!"
               })
    end

    test "Invalid token" do
      assert {:ok, %{errors: ["Registration token is no longer valid."]}} =
               create_user(%{"token" => "invalid-token"})
    end
  end

  describe "login" do
    test "Sunny day" do
      assert {:ok, tokens} = create_user()

      verify_tokens(tokens)

      assert {:ok, tokens} =
               HttpClient.post("auth/login", %{
                 email: "user@fast.farming-community.eu",
                 password: "Fast4Life!!!"
               })

      verify_tokens(tokens)
    end

    test "Invalid password" do
      assert {:ok, %{access: _}} = create_user()

      assert {:ok, %{error: "Invalid username/password combination"}} =
               HttpClient.post("auth/login", %{
                 email: "user@fast.farming-community.eu",
                 password: "Cornix4Life!!!"
               })
    end
  end

  describe "refresh" do
    test "Sunny day" do
      {:ok, %{refresh: refresh}} = create_user()

      assert {:ok, tokens} = HttpClient.post("auth/refresh", %{token: refresh})

      verify_tokens(tokens)
    end

    test "Expired refresh token" do
      temp_env(:refresh_token_ttl, {1, :seconds})

      assert {:ok, %{refresh: refresh}} = create_user()

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

  defp create_user(additional_attributes \\ %{}) do
    attributes = Map.merge(@default_user_attributes, additional_attributes)

    assert {:ok, %User{token: token}} = Auth.init_user(attributes)

    attributes
    |> Map.put_new("token", token)
    |> then(&HttpClient.post("auth/register", &1))
  end
end
