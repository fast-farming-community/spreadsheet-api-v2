defmodule FastApi.Sync.BeepBoop do
  alias FastApi.Content.{Schema, Utils}
  alias FastApi.Repos.Content, as: Repo

  alias GoogleApi.Sheets.V4.Model.{BatchGetValuesResponse, ValueRange}

  def index() do
    spreadsheet = Repo.get(Repo.Spreadsheet, 1) |> Utils.parse_content()

    %Schema.Spreadsheet{spreadsheet | entries: get_spreadsheet_entries(spreadsheet.entries)}

    # Repo.Spreadsheet
    # |> Repo.all()
    # |> Enum.map(&Utils.parse_content/1)
    # |> Enum.map(&%Schema.Spreadsheet{&1 | entries: get_spreadsheet_entries(&1)})
  end

  defp get_spreadsheet_entries(entries) do
    entries
    |> Enum.map(&%Schema.SpreadsheetEntry{&1 | tables: get_spreadsheet_tables(&1.tables)})
    |> List.flatten()
  end

  def get_spreadsheet_tables(tables) do
    {:ok, token} = Goth.Token.for_scope("https://www.googleapis.com/auth/spreadsheets")
    connection = GoogleApi.Sheets.V4.Connection.new(token.token)

    # DEBUG
    tables = Enum.take(tables, 1)

    {:ok, response} =
      GoogleApi.Sheets.V4.Api.Spreadsheets.sheets_spreadsheets_values_batch_get(
        connection,
        "1WdwWxyP9zeJhcxoQAr-paMX47IuK6l5rqAPYDOA8mho",
        ranges: Enum.map(tables, & &1.range),
        valueRenderOption: "UNFORMATTED_VALUE",
        dateTimeRenderOption: "FORMATTED_STRING"
      )

    tables
    |> Enum.zip(response.valueRanges)
    |> Enum.map(fn {%Schema.SpreadsheetTable{} = table, %ValueRange{values: values}} ->
      [headers | rows] = values
      headers = Enum.map(headers, &String.replace(&1, " ", ""))

      for row <- rows do
        headers
        |> Enum.zip(row)
        |> Enum.into(%{})
      end
      |> then(&%Schema.SpreadsheetTable{table | rows: &1})
    end)
  end
end
