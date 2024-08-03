defmodule FastApi.Auth.Token do
  use Guardian, otp_app: :fast_api

  alias FastApi.Auth

  def subject_for_token(user, _claims) do
    {:ok, to_string(user.id)}
  end

  def resource_from_claims(%{"sub" => id}) do
    user = Auth.get_user!(id)
    {:ok, user}
  rescue
    Ecto.NoResultsError -> {:error, :resource_not_found}
  end

  def access_token(user, opts \\ []) do
    encode_and_sign(
      user,
      %{role: Auth.get_user_role(user)},
      [ttl: Application.fetch_env!(:fast_api, :access_token_ttl)] ++ opts
    )
  end

  def refresh_token(user, opts \\ []) do
    encode_and_sign(
      user,
      %{role: Auth.get_user_role(user)},
      [token_type: "refresh", ttl: Application.fetch_env!(:fast_api, :refresh_token_ttl)] ++ opts
    )
  end
end
