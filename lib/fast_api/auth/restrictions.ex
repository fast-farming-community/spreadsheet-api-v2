defmodule FastApi.Auth.Restrictions do
  @moduledoc "Applies restrictions to user access based on roles."

  @restrictions %{
    "soldier" => ["End of Dragons", "Secrets of the Obscure", "Janthir Wilds"],
    "legionnaire" => ["Janthir Wilds"],
    "tribune" => [],
    "khan-ur" => [],
    "champion" => []
  }

  def restricted?(%{"Requires" => requires}, %{"role" => role}) do
    requires in Map.get(@restrictions, role)
  end

  def restricted?(%{"Requires" => requires}, nil) do
    requires in Map.get(@restrictions, "soldier")
  end

  def restricted?(_, _) do
    false
  end
end
