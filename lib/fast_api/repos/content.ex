defmodule FastApi.Repos.Content do
  use Ecto.Repo, otp_app: :fast_api, adapter: Ecto.Adapters.SQLite3

  defmodule About do
    use Ecto.Schema

    schema "about" do
      field(:document, :string)
    end
  end

  defmodule Contributor do
    use Ecto.Schema

    schema "contributors" do
      field(:document, :string)
    end
  end

  defmodule DetailedDataDescription do
    use Ecto.Schema

    schema "detailed_data_descriptions" do
      field(:document, :string)
    end
  end

  defmodule DetailedSpreadsheet do
    use Ecto.Schema

    schema "detailed_spreadsheets" do
      field(:document, :string)
    end
  end

  defmodule FarmingBuild do
    use Ecto.Schema

    schema "farming_builds" do
      field(:document, :string)
    end
  end

  defmodule FarmingGuide do
    use Ecto.Schema

    schema "farming_guides" do
      field(:document, :string)
    end
  end

  defmodule Spreadsheet do
    use Ecto.Schema

    schema "spreadsheets" do
      field(:document, :string)
    end
  end
end
