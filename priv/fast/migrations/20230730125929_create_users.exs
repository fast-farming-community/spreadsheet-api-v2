defmodule FastApi.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    # roles
    create table("roles", primary_key: false) do
      add :name, :string, primary_key: true

      timestamps()
    end

    # users
    create table("users") do
      add :email, :string
      add :password, :string
      add :token, :string
      add :verified, :boolean
      add :role_id, references(:roles, type: :string, column: :name)

      timestamps()
    end

    create unique_index("users", :email, name: :users_unique_id)
  end
end
