defmodule FastApi.Utils.Ecto do
  @moduledoc """
  Utils for interacting with Ecto
  """

  @spec get_errors(Ecto.Changeset.t()) :: map()
  def get_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
