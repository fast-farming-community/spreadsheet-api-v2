defmodule FastApi.Sync.Features do
  alias FastApi.Repos.Fast, as: Repo
  alias GoogleApi.Sheets.V4.Model.ValueRange

  def index() do
    Repo.Table
    |> Repo.all()
    |> Enum.chunk_every(30)
    |> Enum.flat_map(&get_spreadsheet_tables/1)
    |> Enum.map(fn {table, changes} -> Repo.Table.changeset(table, changes) end)
    |> Enum.each(&Repo.update/1)
  end

  @spec get_spreadsheet_tables([Repo.Table.t()]) :: [{Repo.Table.t(), map()}]
  defp get_spreadsheet_tables(tables) do
    {:ok, token} = Goth.Token.for_scope("https://www.googleapis.com/auth/spreadsheets")
    connection = GoogleApi.Sheets.V4.Connection.new(token.token)

    {:ok, response} =
      GoogleApi.Sheets.V4.Api.Spreadsheets.sheets_spreadsheets_values_batch_get(
        connection,
        "1WdwWxyP9zeJhcxoQAr-paMX47IuK6l5rqAPYDOA8mho",
        ranges: Enum.map(tables, & &1.range),
        valueRenderOption: "UNFORMATTED_VALUE",
        dateTimeRenderOption: "FORMATTED_STRING"
      )

    # Give Google some time to rest
    Process.sleep(1_000)

    tables
    |> Enum.zip(response.valueRanges)
    |> Enum.map(fn {%Repo.Table{} = table, %ValueRange{values: values}} ->
      [headers | rows] = values
      headers = Enum.map(headers, &String.replace(&1, ~r/[\W_]+/, ""))

      for row <- rows do
        headers
        |> Enum.zip(row)
        |> Enum.into(%{})
      end
      |> Jason.encode!()
      |> then(&{table, %{rows: &1}})
    end)
  end
end
