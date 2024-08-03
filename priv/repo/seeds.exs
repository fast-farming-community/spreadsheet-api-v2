# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     FastApi.Repo.insert!(%FastApi.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.
alias FastApi.Schemas.Auth.Role

Enum.each(
  ["soldier", "legionnaire", "tribune", "khan-ur"],
  fn role ->
    case FastApi.Repo.get_by(Role, name: role) do
      %Role{} -> :ok
      _ -> FastApi.Repo.insert!(%Role{name: role})
    end
  end
)
