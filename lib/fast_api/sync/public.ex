defmodule FastApi.Sync.Public do
  @moduledoc "Synchronize metadata for the public repository."

  alias FastApi.Repo
  alias FastApi.Schemas.Fast

  require Logger

  def execute() do
    json_data =
      Jason.encode!(%{
        changelog: %{updated_at: github_file_last_update("CHANGELOG.md")},
        content_updates: %{updated_at: github_file_last_update("WEBSITE_CONTENT_UPDATES.md")},
        todos: %{updated_at: github_file_last_update("WEBSITE_TODOS.md")}
      })

    case Repo.get_by(Fast.Metadata, name: "public") do
      nil ->
        Repo.insert(%Fast.Metadata{name: "public", data: json_data})

      public_metadata ->
        public_metadata
        |> Fast.Metadata.changeset(%{data: json_data})
        |> Repo.update()
    end
  end

  def github_file_last_update(filename) do
    :get
    |> Finch.build(
      "https://api.github.com/repos/fast-farming-community/public/commits?path=#{filename}&page=1&per_page=1",
      [{"Content-Type", "application/vnd.github+json"}, {"X-GitHub-Api-Version", "2022-11-28"}]
    )
    |> Finch.request(FastApi.Finch)
    |> then(fn
      {:ok, %Finch.Response{body: body}} ->
        body
        |> Jason.decode!(keys: :atoms)
        |> then(fn [commit] -> commit.commit.committer.date end)

      {:error, error} ->
        Logger.error("Error requesting #{filename} from GitHub: #{error}")
        ""
    end)
  end
end
