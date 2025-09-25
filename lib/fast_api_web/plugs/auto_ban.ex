defmodule FastApiWeb.Plugs.AutoBan do
  @moduledoc false
  import Plug.Conn
  require Logger

  @ban_table :fast_ip_banlist
  @ban_ms 24 * 60 * 60 * 1000 # 24h
  @allow MapSet.new(~w(127.0.0.1 ::1)) # add trusted proxies if needed

  def init(opts), do: opts
  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts), do: conn

  def call(conn, _opts) do
    ensure_tables!()

    ip  = client_ip(conn)
    now = System.system_time(:millisecond)

    case :ets.lookup(@ban_table, ip) do
      [{^ip, until}] when until > now ->
        return_forbidden(conn, ip, reason: "banned")
      [{^ip, _expired}] ->
        :ets.delete(@ban_table, ip)
        maybe_ban_by_request(conn, ip, now)
      [] ->
        maybe_ban_by_request(conn, ip, now)
    end
  end

  # Ban exactly when the crawler hits feature=salvageable
  defp maybe_ban_by_request(conn, ip, now) do
    qs = conn.query_string || ""
    path_qs = ((conn.request_path || "") <> "?" <> qs) |> String.downcase()

    if String.contains?(path_qs, "feature=salvageable") and not MapSet.member?(@allow, ip) do
      :ets.insert(@ban_table, {ip, now + @ban_ms})
      log_block(conn, ip, "auto-ban feature=salvageable")
      conn |> send_resp(403, "Forbidden") |> halt()
    else
      conn
    end
  end

  defp ensure_tables!() do
    case :ets.whereis(@ban_table) do
      :undefined ->
        :ets.new(@ban_table, [:set, :public, :named_table,
                              read_concurrency: true, write_concurrency: true])
      _ -> :ok
    end
  end

  defp client_ip(conn) do
    # Try X-Forwarded-For: first IP in the list
    xff =
      get_req_header(conn, "x-forwarded-for")
      |> List.first()
      |> case do
        nil -> nil
        s   ->
          s
          |> String.split(",", trim: true)
          |> List.first()
          |> String.trim()
      end

    ip =
      cond do
        xff && xff != "" -> xff
        true ->
          xr = get_req_header(conn, "x-real-ip") |> List.first()
          if xr && xr != "", do: xr, else: ip_to_string(conn.remote_ip)
      end

    # Normalize to dotted/colon notation if it's a tuple
    ip
  end

  defp return_forbidden(conn, ip, opts) do
    log_block(conn, ip, opts[:reason] || "banned")
    conn |> send_resp(403, "Forbidden") |> halt()
  end

  defp log_block(conn, ip, reason) do
    ua = get_req_header(conn, "user-agent") |> List.first() || "-"
    Logger.warning(fn ->
      ~s|BOT_AUTOBAN ip=#{ip} reason="#{reason}" method=#{conn.method} path="#{conn.request_path}" qs="#{conn.query_string}" ua="#{safe(ua)}"|
    end)
  end

  defp ip_to_string(nil), do: "-"
  defp ip_to_string(tuple) when is_tuple(tuple), do: :inet.ntoa(tuple) |> to_string()
  defp ip_to_string(str) when is_binary(str), do: str

  defp safe(nil), do: "-"
  defp safe(s), do: String.replace(s, ~r/[\r\n"]/, " ")
end
