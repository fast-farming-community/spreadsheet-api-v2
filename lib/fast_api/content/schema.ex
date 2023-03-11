defmodule FastApi.Content.Schema do
  defmodule About do
    @derive Jason.Encoder
    defstruct content: "", published: false, title: ""
  end

  defmodule Build do
    @derive Jason.Encoder
    defstruct armor: "",
              burstRotation: "",
              multiTarget: "",
              name: "",
              notice: "",
              overview: "",
              profession: "",
              singleTarget: "",
              skills: "",
              specialization: "",
              template: "",
              traits: "",
              traitsInfo: "",
              trinkets: "",
              utilitySkills: "",
              weapons: ""
  end

  defmodule Contributor do
    @derive Jason.Encoder
    defstruct commanders: [], developers: [], supporters: []
  end

  defmodule DetailedSpreadsheet do
    @derive Jason.Encoder
    defstruct category: "", entries: [], published: false
  end

  defmodule DetailedSpreadsheetEntry do
    @derive Jason.Encoder
    defstruct name: "", key: "", range: ""
  end

  defmodule Guide do
    @derive Jason.Encoder
    defstruct farmtrain: "", image: "", info: "", published: false, title: ""
  end

  defmodule Spreadsheet do
    @derive Jason.Encoder
    defstruct entries: [], feature: "", published: false
  end

  defmodule SpreadsheetEntry do
    @derive Jason.Encoder
    defstruct name: "", tables: []
  end

  defmodule SpreadsheetTable do
    @derive Jason.Encoder
    defstruct description: "", name: "", range: ""
  end
end
