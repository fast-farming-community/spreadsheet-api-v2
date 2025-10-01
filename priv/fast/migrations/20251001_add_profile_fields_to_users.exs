defmodule FastApi.Repo.Migrations.AddProfileFieldsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :api_keys, :map, default: %{}, null: false
      add :ingame_name, :string
    end
  end
end
