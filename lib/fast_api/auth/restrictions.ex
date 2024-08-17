defmodule FastApi.Auth.Restrictions do
  @restrictions %{
    "soldier" => ["End of Dragons", "Secrets of the Obscure", "Janthir Wilds"],
    "legionnaire" => ["Janthir Wilds"],
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
