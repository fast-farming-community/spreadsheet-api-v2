defmodule FastApi.Sync.Indexer do
  @moduledoc "Create API index."
  alias FastApi.Repo
  alias FastApi.Schemas.Fast

  def execute() do
    index =
      Fast.Feature
      |> Repo.all()
      |> Repo.preload(pages: [:tables])
      |> Enum.flat_map(fn %Fast.Feature{name: feature, pages: pages} ->
        Enum.map(pages, fn %Fast.Page{name: page, tables: tables} ->
          %{name: kebab_to_capital(page), route: "#{feature}/#{page}", tags: page_tags(tables)}
        end)
      end)

    Fast.Metadata
    |> Repo.get_by(name: "index")
    |> Fast.Metadata.changeset(%{data: Jason.encode!(index)})
    |> Repo.update()
  end

  defp page_tags(tables) do
    Enum.flat_map(tables, fn %Fast.Table{rows: rows} ->
      rows
      |> Jason.decode!()
      |> tl()
      |> Enum.map(&Map.get(&1, "Name"))
    end)
  end

  defp kebab_to_capital(name),
    do: name |> String.split("-") |> Enum.map_join(" ", &String.capitalize/1)
end
