defmodule FastApi.Repos.Fast do
  use Ecto.Repo, otp_app: :fast_api, adapter: Ecto.Adapters.Postgres

  defmodule Page do
    use Ecto.Schema

    schema "pages" do
      field(:name, :string)
      has_many(:table_definitions, FastApi.Repo.TableDefinition)

      timestamps()
    end
  end

  defmodule TableDefinition do
    use Ecto.Schema

    schema "table_definitions" do
      field(:name, :string)
      field(:description, :string)
      field(:module, :string)
      field(:feature, :string)
      field(:range, :string)
      belongs_to(:page, FastApi.Repo.Page)

      timestamps()
    end
  end

  #########################################################################################
  # CONTENT
  #########################################################################################
  defmodule About do
    use Ecto.Schema

    @derive {Jason.Encoder, only: [:content, :published, :title]}
    schema "about" do
      field(:content, :string)
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

  defmodule Guide do
    use Ecto.Schema

    @derive {Jason.Encoder, only: [:farmtrain, :image, :info, :published, :title]}
    schema "guides" do
      field(:farmtrain, :string)
      field(:image, :string)
      field(:info, :string)
      field(:published, :boolean)
      field(:title, :string)

      timestamps()
    end
  end
end
