defmodule FastApi.Guardian do
  use Guardian, otp_app: :fast_api

  alias FastApi.Auth

  @moduledoc """
  Default implementation from https://github.com/ueberauth/guardian
  """

  def subject_for_token(%{id: id}, _claims) do
    {:ok, to_string(id)}
  end

  def subject_for_token(_, _) do
    {:error, :malformed_resource}
  end

  def resource_from_claims(%{"sub" => id}) do
    resource = Auth.get_user!(id)
    {:ok, resource}
  end

  def resource_from_claims(_claims) do
    {:error, :malformed_token}
  end
end
