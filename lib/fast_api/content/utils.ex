defmodule FastApi.Content.Utils do
  alias FastApi.Content.Schema.{
    About,
    Contributor,
    Guide,
    Spreadsheet,
    SpreadsheetEntry,
    SpreadsheetTable
  }

  def parse_content(%{document: document}) do
    document
    |> Jason.decode!()
    |> to_struct()
  end

  defp to_struct(%{"Published" => published, "content" => content, "title" => title}) do
    %About{content: content, published: published, title: title}
  end

  defp to_struct(%{
         "commanders" => commanders,
         "developers" => developers,
         "supporters" => supporters
       }) do
    %Contributor{commanders: commanders, developers: developers, supporters: supporters}
  end

  defp to_struct(%{
         "Published" => published,
         "farmtrain" => farmtrain,
         "image" => image,
         "info" => info,
         "title" => title
       }) do
    %Guide{farmtrain: farmtrain, image: image, info: info, published: published, title: title}
  end

  defp to_struct(%{"Entries" => entries, "Feature" => feature, "Published" => published}) do
    %Spreadsheet{
      entries: Enum.map(entries, &to_struct/1),
      feature: feature,
      published: published
    }
  end

  defp to_struct(%{"name" => name, "tables" => tables}) do
    %SpreadsheetEntry{name: name, tables: Enum.map(tables, &to_struct/1)}
  end

  defp to_struct(%{"description" => description, "name" => name, "range" => range}) do
    %SpreadsheetTable{description: description, name: name, range: range}
  end

  defp to_struct(map), do: map
end
