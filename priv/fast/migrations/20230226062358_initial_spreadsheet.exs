defmodule FastApi.Repos.Fast.Migrations.InitialSpreadsheet do
  use Ecto.Migration

  def change do
    create table("features") do
      add :name, :string
      add :published, :boolean

      timestamps()
    end

    create table("pages") do
      add :feature_id, references (:features)
      add :name, :string
      add :published, :boolean

      timestamps()
    end

    create table("tables") do
      add :description, :text
      add :name, :string
      add :order, :integer
      add :page_id, references (:pages)
      add :published, :boolean
      add :range, :string
      add :rows, :text

      timestamps()
    end

    create unique_index("features", [:name], name: :features_unique_id)
    create unique_index("pages", [:feature_id, :name], name: :pages_unique_id)
    create unique_index("tables", [:page_id, :name], name: :tables_unique_id)
  end
end
