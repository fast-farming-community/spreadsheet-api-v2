defmodule FastApi.Repo.Migrations.ContentAddOrder do
  use Ecto.Migration

  def change do
    alter table("about") do
      add :order, :integer
    end

    alter table("guides") do
      add :order, :integer
    end
  end
end
