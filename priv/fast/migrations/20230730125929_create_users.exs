defmodule FastApi.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    # roles
    create table("roles") do
      add :name, :string

      timestamps()
    end

    # users
    create table("users") do
      add :email, :string
      add :password, :string
      add :token, :string
      add :role, references(:roles)

      timestamps()
    end

    create unique_index("users", :email, name: :users_unique_id)
    create unique_index("roles", :name, name: :roles_unique_id)
  end
end
