defmodule FastApi.Auth.Restrictions do
  @restrictions %{
    "soldier" => ["Path of Fire"],
    "legionnaire" => [],
    "tribune" => [],
    "khan-ur" => []
  }

  def is_restricted(%{"Requires" => requires}, %{"role" => role}) do
    requires in Map.get(@restrictions, role)
  end

  def is_restricted(%{"Requires" => requires}, nil) do
    requires in Map.get(@restrictions, "soldier")
  end

  def is_restricted(_, _) do
    false
  end
end
