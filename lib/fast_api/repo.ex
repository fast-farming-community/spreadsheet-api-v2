defmodule FastApi.Repo do
  use Ecto.Repo, otp_app: :fast_api, adapter: Ecto.Adapters.Postgres
end
