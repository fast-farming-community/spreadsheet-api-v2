defmodule FastApi.Repos.Fast.Migrations.ItemsCustomPrimaryKey do
  use Ecto.Migration

  def change do
    drop table("items")

    create table("items", primary_key: false) do
      add(:buy, :integer)
      add(:chat_link, :string)
      add(:icon, :string)
      add(:id, :integer, primary_key: true)
      add(:level, :integer)
      add(:name, :string)
      add(:rarity, :string)
      add(:sell, :integer)
      add(:tradable, :boolean)
      add(:type, :string)
      add(:vendor_value, :integer)

      timestamps()
    end
  end
end
