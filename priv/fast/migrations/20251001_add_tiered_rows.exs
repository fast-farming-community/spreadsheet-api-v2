defmodule FastApi.Repo.Migrations.AddTieredRows do
  use Ecto.Migration

  def change do
    alter table(:tables, prefix: "public") do
      add :rows_copper, :text
      add :rows_silver, :text
      add :rows_gold,   :text
    end

    alter table(:detail_tables, prefix: "public") do
      add :rows_copper, :text
      add :rows_silver, :text
      add :rows_gold,   :text
    end

    execute """
    UPDATE public.tables
       SET rows_copper = COALESCE(rows_copper, rows),
           rows_silver = COALESCE(rows_silver, rows),
           rows_gold   = COALESCE(rows_gold,   rows)
    """, "/* no-op down */"

    execute """
    UPDATE public.detail_tables
       SET rows_copper = COALESCE(rows_copper, rows),
           rows_silver = COALESCE(rows_silver, rows),
           rows_gold   = COALESCE(rows_gold,   rows)
    """, "/* no-op down */"
  end
end
