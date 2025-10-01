defmodule FastApiWeb.TierRows do
  @moduledoc "Build tier-aware Ecto dynamic() for selecting the right rows column."
  import Ecto.Query

  # Returns an Ecto.dynamic/2 that references the `t` binding in the query.
  # We use nested coalesce because Ecto only exposes 2-arg coalesce in the DSL.
  def rows_dynamic(:gold),
    do: dynamic([t], coalesce(t.rows_gold, coalesce(t.rows_silver, coalesce(t.rows_copper, t.rows))))

  def rows_dynamic(:silver),
    do: dynamic([t], coalesce(t.rows_silver, coalesce(t.rows_copper, t.rows)))

  def rows_dynamic(:copper),
    do: dynamic([t], coalesce(t.rows_copper, t.rows))

  def rows_dynamic(:free),
    do: dynamic([t], t.rows)
end
