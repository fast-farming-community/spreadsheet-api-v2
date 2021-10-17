defmodule FastApi.MongoPipelines do
  def build_page_document() do
    [
      %{
        "$group" => %{
          "_id" => "$relation",
          "order" => %{"$max" => "$order"},
          "name" => %{"$first" => "$relation"},
          "description" => %{"$max" => "$description"},
          "rows" => %{"$push" => "$$ROOT"}
        }
      },
      %{
        "$addFields" => %{
          "rows" => %{
            "$filter" => %{
              "input" => "$rows",
              "as" => "row",
              "cond" => %{
                "$ne" => ["$$row.type", "meta"]
              }
            }
          }
        }
      },
      %{
        "$sort" => %{"order" => 1}
      }
    ]
  end
end
