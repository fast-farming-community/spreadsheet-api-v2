defmodule FastApi.Auth.Restrictions do
  @moduledoc "Applies restrictions to user access based on roles."

  @restrictions %{
    "free" => [],
    "copper" => [],
    "silver" => [],
    "gold" => [],
    "premium" => [],
    "admin" => []
  }

  def restricted?(%{"Requires" => requires}, %{"role" => role}) do
    requires in Map.get(@restrictions, role)
  end

  def restricted?(%{"Requires" => requires}, nil) do
    requires in Map.get(@restrictions, "free")
  end

  def restricted?(_, _) do
    false
  end
end
