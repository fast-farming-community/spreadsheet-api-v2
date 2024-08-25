defmodule FastApi.Repo.Migrations.DetailedSpreadsheet do
  use Ecto.Migration

  def change do
    create table("detail_features") do
      add :name, :string
      add :published, :boolean

      timestamps()
    end

    create table("detail_tables") do
      add :description, :text
      add :detail_feature_id, references (:detail_features)
      add :key, :string
      add :name, :string
      add :range, :string
      add :rows, :text

      timestamps()
    end

    create unique_index("detail_features", [:name], name: :detail_features_unique_id)
    create unique_index("detail_tables", [:detail_feature_id, :key], name: :detail_tables_unique_id)

  end
end
