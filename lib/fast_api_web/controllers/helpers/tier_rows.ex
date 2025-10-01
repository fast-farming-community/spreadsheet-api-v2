defmodule FastApiWeb.TierRows do
  @moduledoc "Build tier-aware SQL expressions for rows selection."
  import Ecto.Query

  # Returns an Ecto SQL fragment that picks the best available rows for the tier.
  def rows_expr(:gold,   t), do: fragment("COALESCE(?, ?, ?, ?)", t.rows_gold,  t.rows_silver, t.rows_copper, t.rows)
  def rows_expr(:silver, t), do: fragment("COALESCE(?, ?, ?)",    t.rows_silver, t.rows_copper, t.rows)
  def rows_expr(:copper, t), do: fragment("COALESCE(?, ?)",       t.rows_copper, t.rows)
  def rows_expr(:free,   t), do: t.rows
end
