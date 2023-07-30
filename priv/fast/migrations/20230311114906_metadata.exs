defmodule FastApi.Repo.Migrations.Metadata do
  use Ecto.Migration

  def change do
    create table("metadata") do
      add :data, :text
      add :name, :string

      timestamps()
    end
  end
end
