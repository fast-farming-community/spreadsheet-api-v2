defmodule FastApi.AuthTest do
  @moduledoc false
  use FastApiWeb.ConnCase

  alias FastApi.Auth
  alias FastApi.Utils.Ecto, as: EctoUtils
  alias FastApi.Schemas.Auth.User

  @default_user_attributes %{
    "email" => "user@fast.farming-community.eu",
    "password" => "Fast4Life!!!",
    "password_confirmation" => "Fast4Life!!!"
  }

  describe "init_user/1" do
    test "with valid data initializes a user" do
      assert {:ok, %User{}} = Auth.init_user(@default_user_attributes)
    end

    test "fails when initializing a user with the same email" do
      assert {:ok, %User{}} = Auth.init_user(@default_user_attributes)

      assert {:error, %Ecto.Changeset{valid?: false, errors: [{:email, _}]}} =
               Auth.init_user(@default_user_attributes)
    end
  end

  describe "create_user/1" do
    test "with valid data creates a user" do
      user = create_default_user()

      assert Bcrypt.verify_pass("Fast4Life!!!", user.password)
    end

    test "fails when creating a user with the same email/token" do
      assert {:ok, %User{token: token}} = Auth.init_user(@default_user_attributes)

      assert {:ok, %User{}} =
               @default_user_attributes |> Map.put("token", token) |> Auth.create_user()

      assert {:error, :invalid_token} =
               @default_user_attributes |> Map.put("token", token) |> Auth.create_user()
    end

    test "fails when creating a user with an invalid token" do
      create_default_user()

      assert {:error, :invalid_token} =
               @default_user_attributes |> Map.put("token", "") |> Auth.create_user()
    end

    for {error, password} <- [
          {"should be at least 12 character(s)", "Fast4Life!"},
          {"Password must contain a number", "FastForLife!!!"},
          {"Password must contain an upper-case letter", "fast4life!!!"},
          {"Password must contain a lower-case letter", "FAST4LIFE!!!"},
          {"Password must contain a symbol", "Fast4Life111"}
        ] do
      test "fails when providing invalid password: #{error}" do
        assert {:ok, %User{token: token}} = Auth.init_user(@default_user_attributes)

        assert {:error, changeset} =
                 Auth.create_user(%{
                   "email" => "user@fast.farming-community.eu",
                   "password" => unquote(password),
                   "token" => token
                 })

        assert %{password: [unquote(error)]} = EctoUtils.get_errors(changeset)
      end
    end
  end

  describe "change_password/2" do
    test "requires old_password, password and password_confirmation" do
      user = create_default_user()

      assert {:ok, %User{}} =
               Auth.change_password(user, %{
                 "password" => "Cornix4Life!!!",
                 "old_password" => "Fast4Life!!!",
                 "password_confirmation" => "Cornix4Life!!!"
               })
    end

    test "does not allow changing of email" do
      user = create_default_user()

      assert {:ok, %User{} = user} =
               Auth.change_password(user, %{
                 "email" => "different_user@fast-farming-community.eu",
                 "password" => "Cornix4Life!!!",
                 "old_password" => "Fast4Life!!!",
                 "password_confirmation" => "Cornix4Life!!!"
               })

      assert Bcrypt.verify_pass("Cornix4Life!!!", user.password)
    end

    test "fails when missing password_confirmation" do
      user = create_default_user()

      assert {:error, changeset} = Auth.change_password(user, %{"password" => "Cornix4Life!!!"})

      assert %{password_confirmation: ["can't be blank"]} = EctoUtils.get_errors(changeset)
    end
  end

  test "create_user/1 and change_password/2 require password confirmation" do
    assert {:ok, %User{token: token}} = Auth.init_user(@default_user_attributes)

    assert {:error, changeset} =
             @default_user_attributes
             |> Map.put("token", token)
             |> Map.put("password_confirmation", "Cornix4Life!!!")
             |> Auth.create_user()

    assert %{password_confirmation: ["does not match confirmation"]} =
             EctoUtils.get_errors(changeset)

    assert {:ok, %User{} = user} =
             @default_user_attributes |> Map.put("token", token) |> Auth.create_user()

    assert {:error, changeset} =
             Auth.change_password(
               user,
               %{
                 "password" => "Cornix4Life!!!",
                 "old_password" => "Fast4Life!!!",
                 "password_confirmation" => "Fast4Life!!!"
               }
             )

    assert %{password_confirmation: ["does not match confirmation"]} =
             EctoUtils.get_errors(changeset)
  end

  defp create_default_user() do
    assert {:ok, %User{token: token}} = Auth.init_user(@default_user_attributes)

    assert {:ok, %User{} = user} =
             @default_user_attributes |> Map.put("token", token) |> Auth.create_user()

    user
  end
end
