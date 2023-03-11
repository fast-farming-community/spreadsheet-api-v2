defmodule FastApi.Sync.Features do
  alias FastApi.Repos.Fast, as: Repo
  alias GoogleApi.Sheets.V4.Model.ValueRange

  require Logger

  def execute(repo) do
    list = Repo.all(repo)
    len = length(list)

    Logger.info("Started fetching #{len} tables from Google Sheets API.")

    list
    |> Enum.chunk_every(30)
    |> Enum.with_index()
    |> Enum.flat_map(&get_spreadsheet_tables(&1, ceil(len / 30)))
    |> Enum.map(fn {table, changes} -> repo.changeset(table, changes) end)
    |> Enum.each(&Repo.update/1)

    Repo.Metadata
    |> Repo.get_by(name: metadata_name(repo))
    |> Repo.Metadata.changeset(%{data: DateTime.to_string(DateTime.utc_now())})
    |> Repo.update()

    Logger.info("Finished fetching #{len} tables from Google Sheets API.")
  end

  @spec get_spreadsheet_tables([Repo.Table.t()], non_neg_integer()) :: [{Repo.Table.t(), map()}]
  defp get_spreadsheet_tables({tables, idx}, total) do
    {:ok, token} = Goth.Token.for_scope("https://www.googleapis.com/auth/spreadsheets")
    connection = GoogleApi.Sheets.V4.Connection.new(token.token)

    Logger.info("Fetching table chunk #{idx + 1}/#{total}.")

    {:ok, response} =
      GoogleApi.Sheets.V4.Api.Spreadsheets.sheets_spreadsheets_values_batch_get(
        connection,
        "1WdwWxyP9zeJhcxoQAr-paMX47IuK6l5rqAPYDOA8mho",
        ranges: Enum.map(tables, & &1.range),
        valueRenderOption: "UNFORMATTED_VALUE",
        dateTimeRenderOption: "FORMATTED_STRING"
      )

    # Give Google some time to rest
    Process.sleep(200)

    tables
    |> Enum.zip(response.valueRanges)
    |> Enum.map(fn {%_{} = table, %ValueRange{values: values}} ->
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

  defp metadata_name(FastApi.Repos.Fast.Table), do: "main"
  defp metadata_name(FastApi.Repos.Fast.DetailTable), do: "detail"
end
