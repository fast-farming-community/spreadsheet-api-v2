defmodule FastApi.Test.Support.HttpClient do
  @moduledoc false

  def post(path, body) do
    :post
    |> Finch.build(
      "#{url()}/#{path}",
      [{"Content-Type", "application/json"}],
      Jason.encode!(body)
    )
    |> Finch.request(FastApi.Finch)
    |> then(fn {:ok, %Finch.Response{body: body}} ->
      {:ok, Jason.decode!(body, keys: :atoms)}
    end)
  end

  defp url do
    http_opts = Application.fetch_env!(:fast_api, FastApiWeb.Endpoint) |> Keyword.fetch!(:http)
    ip = http_opts |> Keyword.fetch!(:ip) |> Tuple.to_list() |> Enum.join(".")
    "http://#{ip}:#{Keyword.fetch!(http_opts, :port)}/api/v1"
  end
end
