defmodule FastApi.Schemas.Fast do
  @moduledoc "Schemas for static content and spreadsheet data."

  defmodule About do
    @moduledoc false
    use Ecto.Schema
    @derive {Jason.Encoder, only: [:content, :published, :title]}
    schema "about" do
      field(:content, :string)
      field(:order, :integer)
      field(:published, :boolean)
      field(:title, :string)
      timestamps()
    end
  end

  defmodule Build do
    @moduledoc false
    use Ecto.Schema
    @derive {Jason.Encoder,
             only: [
               :armor, :burstRotation, :multiTarget, :name, :notice, :overview, :profession,
               :published, :singleTarget, :skills, :specialization, :template,
               :traits, :traitsInfo, :trinkets, :utilitySkills, :weapons
             ]}
    schema "builds" do
      field(:armor, :string)
      field(:burstRotation, :string)
      field(:multiTarget, :string)
      field(:name, :string)
      field(:notice, :string)
      field(:overview, :string)
      field(:profession, :string)
      field(:published, :boolean)
      field(:singleTarget, :string)
      field(:skills, :string)
      field(:specialization, :string)
      field(:template, :string)
      field(:traits, :string)
      field(:traitsInfo, :string)
      field(:trinkets, :string)
      field(:utilitySkills, :string)
      field(:weapons, :string)
      timestamps()
    end
  end

  defmodule Contributor do
    @moduledoc false
    use Ecto.Schema
    @derive {Jason.Encoder, only: [:name, :type]}
    schema "contributors" do
      field(:name, :string)
      field(:published, :boolean)
      field(:type, :string)
      timestamps()
    end
  end

  defmodule Guide do
    @moduledoc false
    use Ecto.Schema
    @derive {Jason.Encoder, only: [:farmtrain, :image, :info, :published, :title]}
    schema "guides" do
      field(:farmtrain, :string)
      field(:image, :string)
      field(:info, :string)
      field(:order, :integer)
      field(:published, :boolean)
      field(:title, :string)
      timestamps()
    end
  end

  defmodule Item do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :integer, []}
    schema "items" do
      field(:buy, :integer)
      field(:chat_link, :string)
      field(:icon, :string)
      field(:level, :integer)
      field(:name, :string)
      field(:rarity, :string)
      field(:sell, :integer)
      field(:tradable, :boolean)
      field(:type, :string)
      field(:vendor_value, :integer)
      timestamps()
    end

    def changeset(item, %{
          buys: %{"unit_price" => buy_price},
          sells: %{"unit_price" => sell_price}
        }) do
      change(item, buy: buy_price, sell: sell_price)
    end
  end

  defmodule Metadata do
    @moduledoc """
    Store JSON blobs (data) containing website metadata

    Default metadata (name):
      - main:    per-tier `updated_at` for feature sync
      - detail:  per-tier `updated_at` for detail sync
      - index:   table index
      - public:  CHANGELOG/WEBSITE_CONTENT_UPDATES/WEBSITE_TODOS timestamps
    """
    use Ecto.Schema
    import Ecto.Changeset

    @derive {Jason.Encoder, only: [:name, :data, :updated_at]}
    schema "metadata" do
      field(:data, :string)
      field(:name, :string)
      timestamps()
    end

    def changeset(metadata, params \\ %{}), do: cast(metadata, params, [:data])
  end

  defmodule Feature do
    @moduledoc false
    use Ecto.Schema

    @compile {:no_warn_undefined, FastApi.Schemas.Fast.Page}

    @derive {Jason.Encoder, only: [:name, :pages]}
    schema "features" do
      field(:name, :string)
      has_many(:pages, FastApi.Schemas.Fast.Page)
      field(:published, :boolean)
      timestamps()
    end
  end

  defmodule Table do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @compile {:no_warn_undefined, FastApi.Schemas.Fast.Page}

    @derive {Jason.Encoder, only: [:description, :name, :order, :rows, :restrictions]}
    schema "tables" do
      field :description, :string
      field :name, :string
      field :order, :integer
      belongs_to(:page, FastApi.Schemas.Fast.Page)
      field :published, :boolean
      field :range, :string

      # legacy + new tiered payloads
      field :rows, :string
      field :rows_copper, :string
      field :rows_silver, :string
      field :rows_gold, :string

      field :restrictions, :map, virtual: true
      timestamps()
    end

    def changeset(table, params \\ %{}) do
      table
      |> cast(params, [:rows, :rows_copper, :rows_silver, :rows_gold])
      |> unique_constraint(:tables_unique_id)
    end
  end

  defmodule DetailTable do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @compile {:no_warn_undefined, FastApi.Schemas.Fast.DetailFeature}

    @derive {Jason.Encoder, only: [:description, :key, :name, :rows]}
    schema "detail_tables" do
      field(:description, :string)
      belongs_to(:detail_feature, FastApi.Schemas.Fast.DetailFeature)
      field(:key, :string)
      field(:name, :string)
      field(:range, :string)

      # legacy + new tiered payloads
      field(:rows, :string)
      field(:rows_copper, :string)
      field(:rows_silver, :string)
      field(:rows_gold, :string)

      timestamps()
    end

    def changeset(table, params \\ %{}) do
      table
      |> cast(params, [:rows, :rows_copper, :rows_silver, :rows_gold])
      |> unique_constraint(:detail_tables_unique_id)
    end
  end

  defmodule DetailFeature do
    @moduledoc false
    use Ecto.Schema

    @compile {:no_warn_undefined, FastApi.Schemas.Fast.DetailTable}

    @derive {Jason.Encoder, only: [:name, :detail_tables]}
    schema "detail_features" do
      field(:name, :string)
      has_many(:detail_tables, FastApi.Schemas.Fast.DetailTable)
      field(:published, :boolean)
      timestamps()
    end
  end

  defmodule Page do
    @moduledoc false
    use Ecto.Schema

    @compile {:no_warn_undefined, FastApi.Schemas.Fast.Feature}
    @compile {:no_warn_undefined, FastApi.Schemas.Fast.Table}

    @derive {Jason.Encoder, only: [:name, :tables]}
    schema "pages" do
      belongs_to(:feature, FastApi.Schemas.Fast.Feature)
      field(:name, :string)
      field(:published, :boolean)
      has_many(:tables, FastApi.Schemas.Fast.Table)
      timestamps()
    end
  end
end
