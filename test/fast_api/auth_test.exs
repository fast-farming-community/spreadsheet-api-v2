defmodule FastApi.AuthTest do
  @moduledoc false
  use ExUnit.Case

  alias FastApi.Auth
  alias FastApi.Utils.Ecto, as: EctoUtils
  alias FastApi.Schemas.Auth.User

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(FastApi.Repo)
  end

  @default_user_attributes %{
    email: "user@fast.farming-community.eu",
    password: "Fast4Life!!!",
    password_confirmation: "Fast4Life!!!"
  }

  describe "create_user/1" do
    test "with valid data creates a user" do
      assert {:ok, %User{} = user} = Auth.create_user(@default_user_attributes)

      assert Bcrypt.verify_pass("Fast4Life!!!", user.password)
    end

    test "fails when creating a user with the same email" do
      assert {:ok, %User{}} = Auth.create_user(@default_user_attributes)

      assert {:error, %Ecto.Changeset{valid?: false, errors: [{:email, _}]}} =
               Auth.create_user(@default_user_attributes)
    end

    for {error, password} <- [
          {"should be at least 12 character(s)", "Fast4Life!"},
          {"Password must contain a number", "FastForLife!!!"},
          {"Password must contain an upper-case letter", "fast4life!!!"},
          {"Password must contain a lower-case letter", "FAST4LIFE!!!"},
          {"Password must contain a symbol", "Fast4Life111"}
        ] do
      test "fails when providing invalid password: #{error}" do
        assert {:error, changeset} =
                 Auth.create_user(%{
                   email: "user@fast-farming-community.eu",
                   password: unquote(password)
                 })

        assert %{password: [unquote(error)]} = EctoUtils.get_errors(changeset)
      end
    end
  end

  describe "update_user/2" do
    test "requires old_password, password and password_confirmation" do
      assert {:ok, %User{} = user} = Auth.create_user(@default_user_attributes)

      assert {:ok, %User{}} =
               Auth.update_user(user, %{
                 password: "Cornix4Life!!!",
                 old_password: "Fast4Life!!!",
                 password_confirmation: "Cornix4Life!!!"
               })
    end

    test "does not allow changing of email" do
      assert {:ok, %User{} = user} = Auth.create_user(@default_user_attributes)

      assert {:ok, %User{} = user} =
               Auth.update_user(user, %{
                 email: "different_user@fast-farming-community.eu",
                 password: "Cornix4Life!!!",
                 old_password: "Fast4Life!!!",
                 password_confirmation: "Cornix4Life!!!"
               })

      assert Bcrypt.verify_pass("Cornix4Life!!!", user.password)
    end

    for field <- [:old_password, :password_confirmation] do
      test "fails when missing #{field}" do
        field = unquote(field)
        assert {:ok, %User{} = user} = Auth.create_user(@default_user_attributes)

        update_attributes =
          Map.delete(
            %{
              password: "Cornix4Life!!!",
              old_password: "Fast4Life!!!",
              password_confirmation: "Cornix4Life!!!"
            },
            field
          )

        assert {:error, changeset} = Auth.update_user(user, update_attributes)

        assert %{^field => ["can't be blank"]} = EctoUtils.get_errors(changeset)
      end
    end
  end

  test "create_user/1 and update_user/2 require password confirmation" do
    assert {:error, changeset} =
             Auth.create_user(%{
               @default_user_attributes
               | password_confirmation: "Cornix4Life!!!"
             })

    assert %{password_confirmation: ["does not match confirmation"]} =
             EctoUtils.get_errors(changeset)

    assert {:ok, %User{} = user} = Auth.create_user(@default_user_attributes)

    assert {:error, changeset} =
             Auth.update_user(
               user,
               %{
                 password: "Cornix4Life!!!",
                 old_password: "Fast4Life!!!",
                 password_confirmation: "Fast4Life!!!"
               }
             )

    assert %{password_confirmation: ["does not match confirmation"]} =
             EctoUtils.get_errors(changeset)
  end
end
