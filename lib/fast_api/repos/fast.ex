defmodule FastApi.Repos.Fast do
  use Ecto.Repo, otp_app: :fast_api, adapter: Ecto.Adapters.Postgres

  #########################################################################################
  # CONTENT
  #########################################################################################
  defmodule About do
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
    use Ecto.Schema

    @derive {Jason.Encoder,
             only: [
               :armor,
               :burstRotation,
               :multiTarget,
               :name,
               :notice,
               :overview,
               :profession,
               :published,
               :singleTarget,
               :skills,
               :specialization,
               :template,
               :traits,
               :traitsInfo,
               :trinkets,
               :utilitySkills,
               :weapons
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
    use Ecto.Schema

    @derive {Jason.Encoder, only: [:name, :published, :type]}
    schema "contributors" do
      field(:name, :string)
      field(:published, :boolean)
      field(:type, :string)

      timestamps()
    end
  end

  defmodule Feature do
    use Ecto.Schema

    @derive {Jason.Encoder, only: [:name, :pages]}
    schema "features" do
      field(:name, :string)
      has_many(:pages, FastApi.Repos.Fast.Page)
      field(:published, :boolean)

      timestamps()
    end
  end

  defmodule Guide do
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
    use Ecto.Schema
    import Ecto.Changeset

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

  defmodule Page do
    use Ecto.Schema

    @derive {Jason.Encoder, only: [:name, :tables]}
    schema "pages" do
      belongs_to(:feature, FastApi.Repos.Fast.Feature)
      field(:name, :string)
      field(:published, :boolean)
      has_many(:tables, FastApi.Repos.Fast.Table)

      timestamps()
    end
  end

  defmodule Table do
    use Ecto.Schema
    import Ecto.Changeset

    @derive {Jason.Encoder, only: [:description, :name, :order, :rows]}
    schema "tables" do
      field(:description, :string)
      field(:name, :string)
      field(:order, :integer)
      belongs_to(:page, FastApi.Repos.Fast.Page)
      field(:published, :boolean)
      field(:range, :string)
      field(:rows, :string)

      timestamps()
    end

    def changeset(table, params \\ %{}) do
      table
      |> cast(params, [:rows])
      |> unique_constraint(:tables_unique_id)
    end
  end
end
