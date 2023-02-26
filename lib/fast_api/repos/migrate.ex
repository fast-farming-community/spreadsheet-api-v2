defmodule FastApi.Repos.Migrate do
  alias FastApi.Repos.{Content, Fast}

  def migrate_about() do
    Content.About
    |> Content.all()
    |> Enum.map(&__MODULE__.Utils.parse_content/1)
    |> Enum.each(&Fast.insert(&1))
  end

  def migrate_builds() do
    Content.FarmingBuild
    |> Content.all()
    |> Enum.map(&__MODULE__.Utils.parse_content/1)
    |> Enum.each(&Fast.insert(&1))
  end

  def migrate_contributors() do
    Content.Contributor
    |> Content.get(1)
    |> __MODULE__.Utils.parse_content()
    |> Enum.each(&Fast.insert(&1))
  end

  def migrate_guides() do
    Content.FarmingGuide
    |> Content.all()
    |> Enum.map(&__MODULE__.Utils.parse_content/1)
    |> Enum.each(&Fast.insert(&1))
  end

  def migrate_spreadsheets() do
    Content.Spreadsheet
    |> Content.all()
    |> Enum.map(&__MODULE__.Utils.parse_content/1)
    |> Enum.each(&Fast.insert(&1))
  end
end

defmodule FastApi.Repos.Migrate.Utils do
  alias FastApi.Repos.Fast.{About, Build, Contributor, Feature, Guide, Page, Table}

  def parse_content(%{document: document}) do
    document
    |> Jason.decode!()
    |> to_struct()
  end

  defp to_struct(%{"Published" => published, "content" => content, "title" => title}) do
    %About{content: content, published: published, title: title}
  end

  defp to_struct(%{
         "armor" => armor,
         "burstRotation" => burstRotation,
         "multiTarget" => multiTarget,
         "name" => name,
         "notice" => notice,
         "overview" => overview,
         "profession" => profession,
         "singleTarget" => singleTarget,
         "skills" => skills,
         "specialization" => specialization,
         "template" => template,
         "traits" => traits,
         "traitsInfo" => traitsInfo,
         "trinkets" => trinkets,
         "utilitySkills" => utilitySkills,
         "weapons" => weapons
       }) do
    %Build{
      armor: armor,
      burstRotation: burstRotation,
      multiTarget: multiTarget,
      name: name,
      notice: notice,
      overview: overview,
      profession: profession,
      published: true,
      singleTarget: singleTarget,
      skills: skills,
      specialization: specialization,
      template: template,
      traits: traits,
      traitsInfo: traitsInfo,
      trinkets: trinkets,
      utilitySkills: utilitySkills,
      weapons: weapons
    }
  end

  defp to_struct(%{
         "commanders" => commanders,
         "developers" => developers,
         "supporters" => supporters
       }) do
    Enum.map(commanders, &%Contributor{name: &1, published: true, type: "commander"}) ++
      Enum.map(developers, &%Contributor{name: &1, published: true, type: "developer"}) ++
      Enum.map(supporters, &%Contributor{name: &1, published: true, type: "supporter"})
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

  defp to_struct(%{"Entries" => entries, "Feature" => feature}) do
    %Feature{
      pages: Enum.map(entries, &to_struct/1),
      name: feature,
      published: true
    }
  end

  defp to_struct(%{"name" => name, "tables" => tables}) do
    %Page{name: name, published: true, tables: Enum.with_index(tables, &to_struct/2)}
  end

  defp to_struct(%{"description" => description, "name" => name, "range" => range}, index) do
    %Table{
      description: description,
      name: name,
      order: index,
      published: true,
      range: range,
      rows: ""
    }
  end

  defp to_struct(map), do: map
end
