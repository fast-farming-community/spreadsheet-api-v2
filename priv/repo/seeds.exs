# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     FastApi.Repo.insert!(%FastApi.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.
alias FastApi.Schemas.Auth.Role
alias FastApi.Schemas.Fast.{DetailFeature, DetailTable, Feature, Page, Table}

Enum.each(
  ["free", "copper", "silver", "gold", "premium", "admin"],
  fn role ->
    case FastApi.Repo.get_by(Role, name: role) do
      %Role{} -> :ok
      _ -> FastApi.Repo.insert!(%Role{name: role})
    end
  end
)

if Mix.env() in [:dev, :test] do
  now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  seeds = "priv/repo/seeds.json" |> File.read!() |> Jason.decode!(keys: :atoms)

  add_timestamps = fn map ->
    map
    |> Map.put(:inserted_at, now)
    |> Map.put(:updated_at, now)
  end

  # Features
  Ecto.Multi.new()
  |> Ecto.Multi.insert_all(:create_features, Feature, fn _ ->
    Enum.map(seeds.features, fn feature ->
      feature |> add_timestamps.() |> Map.delete(:pages)
    end)
  end)
  |> Ecto.Multi.run(:features, fn repo, _ ->
    {:ok, repo.all(Feature)}
  end)
  |> Ecto.Multi.insert_all(:create_pages, Page, fn %{features: features} ->
    Enum.flat_map(seeds.features, fn feature ->
      feature_entry = Enum.find(features, &(&1.name == feature.name))

      Enum.map(feature.pages, fn page ->
        page
        |> add_timestamps.()
        |> Map.put(:feature_id, feature_entry.id)
        |> Map.delete(:tables)
      end)
    end)
  end)
  |> Ecto.Multi.run(:feature_pages, fn repo, _ ->
    {:ok, repo.all(Feature) |> repo.preload(:pages)}
  end)
  |> Ecto.Multi.insert_all(:create_tables, Table, fn %{feature_pages: feature_pages} ->
    Enum.flat_map(seeds.features, fn feature ->
      feature_entry = Enum.find(feature_pages, &(&1.name == feature.name))

      Enum.flat_map(feature.pages, fn page ->
        page_entry = Enum.find(feature_entry.pages, &(&1.name == page.name))

        Enum.map(page.tables, fn table ->
          table
          |> add_timestamps.()
          |> Map.put(:page_id, page_entry.id)
        end)
      end)
    end)
  end)
  |> FastApi.Repo.transaction()

  # Details
  Ecto.Multi.new()
  |> Ecto.Multi.insert_all(:create_features, DetailFeature, fn _ ->
    Enum.map(seeds.details, fn feature ->
      feature |> add_timestamps.() |> Map.delete(:tables)
    end)
  end)
  |> Ecto.Multi.run(:features, fn repo, _ ->
    {:ok, repo.all(DetailFeature)}
  end)
  |> Ecto.Multi.insert_all(:create_tables, DetailTable, fn %{features: features} ->
    Enum.flat_map(seeds.details, fn feature ->
      feature_entry = Enum.find(features, &(&1.name == feature.name))

      Enum.map(feature.tables, fn table ->
        table
        |> add_timestamps.()
        |> Map.put(:detail_feature_id, feature_entry.id)
      end)
    end)
  end)
  |> FastApi.Repo.transaction()
end
