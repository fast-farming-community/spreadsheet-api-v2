defmodule FastApi.Sync.Indexer do
  alias FastApi.Repos.Fast, as: Repo

  def execute() do
    index =
      Repo.Feature
      |> Repo.all()
      |> Repo.preload(pages: [:tables])
      |> Enum.flat_map(fn %Repo.Feature{name: feature, pages: pages} ->
        Enum.map(pages, fn %Repo.Page{name: page, tables: tables} ->
          %{name: kebab_to_capital(page), route: "#{feature}/#{page}", tags: page_tags(tables)}
        end)
      end)

    Repo.Metadata
    |> Repo.get_by(name: "index")
    |> Repo.Metadata.changeset(%{data: Jason.encode!(index)})
    |> Repo.update()
  end

  defp page_tags(tables) do
    Enum.flat_map(
      tables,
      fn
        %Repo.Table{rows: "[]"} ->
          []

        %Repo.Table{rows: rows} ->
          rows
          |> Jason.decode!()
          |> tl()
          |> Enum.map(&Map.get(&1, "Name"))
      end
    )
  end

  defp kebab_to_capital(name),
    do: name |> String.split("-") |> Enum.map_join(" ", &String.capitalize/1)
end
