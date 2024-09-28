alias FastApi.Schemas.Auth.Role
alias FastApi.Schemas.Fast.{DetailFeature, Feature}

features =
  FastApi.Repo.all(Feature)
  |> FastApi.Repo.preload(pages: [:tables])
  |> Enum.map(fn feature ->
    %{
      name: feature.name,
      published: feature.published,
      pages:
        Enum.map(feature.pages, fn page ->
          %{
            name: page.name,
            published: page.published,
            tables:
              Enum.map(page.tables, fn table ->
                %{
                  name: table.name,
                  description: "",
                  order: table.order,
                  published: table.published,
                  range: table.range,
                  rows: ""
                }
              end)
          }
        end)
    }
  end)

details =
  FastApi.Repo.all(DetailFeature)
  |> FastApi.Repo.preload(:detail_tables)
  |> Enum.map(fn feature ->
    %{
      name: feature.name,
      published: feature.published,
      tables:
        Enum.map(feature.detail_tables, fn table ->
          %{
            name: table.name,
            key: table.key,
            description: "",
            range: table.range,
            rows: ""
          }
        end)
    }
  end)

%{features: features, details: details}
|> Jason.encode!()
|> then(&File.write("priv/repo/seeds.json", &1))
