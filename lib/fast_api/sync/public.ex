defmodule FastApi.Sync.Public do
  @moduledoc "Synchronize metadata for the public repository."

  alias FastApi.Repo
  alias FastApi.Schemas.Fast

  require Logger

  defp fmt_ms(ms) do
    total = div(ms, 1000)
    mins = div(total, 60)
    secs = rem(total, 60)
    "#{mins}:#{String.pad_leading(Integer.to_string(secs), 2, "0")} mins"
  end

  def execute() do
    t0 = System.monotonic_time(:millisecond)
    Logger.info("[job] public.execute started")

    changelog_dt = github_file_last_update("CHANGELOG.md")
    updates_dt   = github_file_last_update("WEBSITE_CONTENT_UPDATES.md")
    todos_dt     = github_file_last_update("WEBSITE_TODOS.md")

    json_data =
      Jason.encode!(%{
        changelog: %{updated_at: changelog_dt},
        content_updates: %{updated_at: updates_dt},
        todos: %{updated_at: todos_dt}
      })

    result =
      case Repo.get_by(Fast.Metadata, name: "public") do
        nil ->
          Repo.insert(%Fast.Metadata{name: "public", data: json_data})

        public_metadata ->
          public_metadata
          |> Fast.Metadata.changeset(%{data: json_data})
          |> Repo.update()
      end

    dt = System.monotonic_time(:millisecond) - t0
    ok_count =
      [changelog_dt, updates_dt, todos_dt]
      |> Enum.count(&(&1 != ""))

    Logger.info("[job] public.execute completed in #{fmt_ms(dt)} files=3 resolved=#{ok_count}")

    result
  end

  def github_file_last_update(filename) do
    :get
    |> Finch.build(
      "https://api.github.com/repos/fast-farming-community/public/commits?path=#{filename}&page=1&per_page=1",
      [{"Content-Type", "application/vnd.github+json"}, {"X-GitHub-Api-Version", "2022-11-28"}]
    )
    |> Finch.request(FastApi.Finch)
    |> case do
      {:ok, %Finch.Response{status: status, body: body}} ->
        with {:ok, decoded} <- Jason.decode(body, keys: :atoms),
             [commit] <- decoded,
             date when is_binary(date) <- get_in(commit, [:commit, :committer, :date]) do
          date
        else
          other ->
            Logger.error("GitHub parse error for #{filename} (status #{status}): #{inspect(other)}")
            ""
        end

      {:error, error} ->
        Logger.error("Error requesting #{filename} from GitHub: #{inspect(error)}")
        ""
    end
  end
end
