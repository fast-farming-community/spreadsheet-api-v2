defmodule FastApiWeb.Plugs.AutoBan do
  @moduledoc false
  import Plug.Conn

  @ban_table :fast_ip_banlist

  def init(opts), do: opts
  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts), do: conn

  def call(conn, _opts) do
    ip = conn |> client_ip() |> normalize_ip()
    now = System.system_time(:millisecond)

    banned? =
      case :ets.info(@ban_table) do
        :undefined -> false
        _ ->
          try do
            case :ets.lookup(@ban_table, ip) do
              [{^ip, until}] when until > now -> true
              [{^ip, _expired}] -> :ets.delete(@ban_table, ip); false
              [] -> false
            end
          rescue
            ArgumentError -> false
          end
      end

    if banned?, do: send_resp(conn, 403, "Forbidden") |> halt(), else: conn
  end

  # Prefer X-Forwarded-For first IP, then X-Real-IP, else remote_ip tuple
  defp client_ip(conn) do
    xff = get_req_header(conn, "x-forwarded-for") |> List.first()

    cond do
      xff && xff != "" ->
        xff |> String.split(",", trim: true) |> List.first() |> String.trim()

      true ->
        xr = get_req_header(conn, "x-real-ip") |> List.first()
        if xr && xr != "", do: xr, else: ip_to_string(conn.remote_ip)
    end
  end

  defp normalize_ip(nil), do: "-"
  defp normalize_ip("::ffff:" <> rest), do: rest
  defp normalize_ip(ip), do: ip

  defp ip_to_string(nil), do: "-"
  defp ip_to_string(tuple) when is_tuple(tuple), do: :inet.ntoa(tuple) |> to_string()
  defp ip_to_string(str) when is_binary(str), do: str
end
