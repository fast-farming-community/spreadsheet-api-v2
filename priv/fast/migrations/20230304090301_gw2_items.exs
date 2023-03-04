defmodule FastApi.Repos.Fast.Migrations.Gw2Items do
  use Ecto.Migration

  def change do
    create table("items") do
      add(:buy, :integer)
      add(:chat_link, :string)
      add(:icon, :string)
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
