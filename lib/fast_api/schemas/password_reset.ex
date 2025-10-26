defmodule FastApi.Schemas.PasswordReset do
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime]

  schema "password_resets" do
    field :token_hash, :binary
    field :sent_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    belongs_to :user, FastApi.Schemas.Auth.User
    timestamps(updated_at: false)  # inserted_at will now be UTC
  end

  def insert_changeset(pr, attrs) do
    pr
    |> cast(attrs, [:user_id, :token_hash, :sent_at, :expires_at])
    |> validate_required([:user_id, :token_hash, :sent_at, :expires_at])
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:token_hash)
  end

  def mark_used_changeset(pr) do
    change(pr, used_at: DateTime.utc_now())
  end
end
