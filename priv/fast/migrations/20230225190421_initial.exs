defmodule FastApi.Repo.Migrations.Initial do
  use Ecto.Migration

  def change do
    create table("about") do
      add(:content, :text)
      add(:published, :boolean)
      add(:title, :string)

      timestamps()
    end

    create table("builds") do
      add(:armor, :text)
      add(:burstRotation, :text)
      add(:multiTarget, :text)
      add(:name, :text)
      add(:notice, :text)
      add(:overview, :text)
      add(:profession, :text)
      add(:published, :boolean)
      add(:singleTarget, :text)
      add(:skills, :text)
      add(:specialization, :text)
      add(:template, :text)
      add(:traits, :text)
      add(:traitsInfo, :text)
      add(:trinkets, :text)
      add(:utilitySkills, :text)
      add(:weapons, :text)

      timestamps()
    end

    create table("contributors") do
      add(:name, :string)
      add(:published, :boolean)
      add(:type, :string)

      timestamps()
    end

    create table("guides") do
      add(:farmtrain, :string)
      add(:image, :string)
      add(:info, :text)
      add(:published, :boolean)
      add(:title, :string)

      timestamps()
    end
  end
end
