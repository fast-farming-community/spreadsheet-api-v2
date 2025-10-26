defmodule FastApi.Schemas.Raffle do
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime]

  schema "raffles" do
    field :month_key, :date
    field :status, :string, default: "open"
    field :items,  :map
    field :winners, :map
    timestamps()
  end

  def changeset(m, params \\ %{}) do
    m
    |> cast(params, [:month_key, :status, :items, :winners])
    |> validate_required([:month_key])
  end
end
