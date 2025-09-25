defmodule FastApiWeb.Plugs.AutoBan do
  @moduledoc false
  import Plug.Conn
  require Logger

  @ban_table :fast_ip_banlist
  @ban_ms 24 * 60 * 60 * 1000   # 24h, tune as needed
  @allow MapSet.new(~w(127.0.0.1 ::1)) # trusted proxies if needed
  @slug_regex ~r/^[a-z0-9-]+$/

  def init(opts), do: opts
  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts), do: conn

  def call(conn, _opts) do
    ensure_table_race_safe!()
    ip = client_ip(conn)
    now = System.system_time(:millisecond)

    case :ets.lookup(@ban_table, ip) do
      [{^ip, until}] when until > now ->
        # already banned
        return_forbidden(conn, ip, reason: "banned")
      [{^ip, _expired}] ->
        :ets.delete(@ban_table, ip)
        maybe_ban_by_request(conn, ip, now)
      [] ->
        maybe_ban_by_request(conn, ip, now)
    end
  end

  # Only ban when feature=salvageable AND key exists AND key is malformed
  defp maybe_ban_by_request(conn, ip, now) do
    # parse params safely (works before Plug.Parsers)
    conn = fetch_query_params(conn)
    qs_params = conn.params
    feature = Map.get(qs_params, "feature", "") |> to_string() |> String.downcase()
    key = Map.get(qs_params, "key") || Map.get(qs_params, "id") || ""

    if feature == "salvageable" and key != "" and key_malformed?(key) and not MapSet.member?(@allow, ip) do
      :ets.insert(@ban_table, {ip, now + @ban_ms})
      log_ban(conn, ip, "auto-ban malformed-key", key)
      conn |> send_resp(403, "Forbidden") |> halt()
    else
      conn
    end
  end

  defp key_malformed?(raw_key) when is_binary(raw_key) do
    k = String.trim(raw_key)

    # common malformed signs:
    has_pct20? = String.contains?(raw_key, "%20")
    has_space?  = String.contains?(k, " ")
    not_slug?   = not Regex.match?(@slug_regex, k)

    has_pct20? or has_space? or not_slug?
  end
  defp key_malformed?(_), do: false

  # Race-safe ETS creator
  defp ensure_table_race_safe!() do
    case :ets.whereis(@ban_table) do
      :undefined ->
        try do
          :ets.new(@ban_table,
                   [:set, :public, :named_table,
                    read_concurrency: true, write_concurrency: true])
        rescue
          ArgumentError -> :ok
        end
      _ -> :ok
    end
  end

  defp client_ip(conn) do
    # Prefer X-Forwarded-For first IP, then X-Real-IP, else remote_ip tuple
    xff = get_req_header(conn, "x-forwarded-for") |> List.first()
    ip =
      cond do
        xff && xff != "" ->
          xff |> String.split(",", trim: true) |> List.first() |> String.trim()
        true ->
          xr = get_req_header(conn, "x-real-ip") |> List.first()
          if xr && xr != "", do: xr, else: ip_to_string(conn.remote_ip)
      end

    ip || "-"
  end

  defp ip_to_string(nil), do: "-"
  defp ip_to_string(tuple) when is_tuple(tuple), do: :inet.ntoa(tuple) |> to_string()
  defp ip_to_string(str) when is_binary(str), do: str

  defp return_forbidden(conn, ip, opts) do
    log_ban(conn, ip, opts[:reason] || "banned", Map.get(conn.params, "key"))
    conn |> send_resp(403, "Forbidden") |> halt()
  end

  defp log_ban(conn, ip, reason, key \\ nil) do
    ua = get_req_header(conn, "user-agent") |> List.first() || "-"
    key_part = if key, do: ~s| key="#{String.replace(key, ~r/[\r\n"]/, " ")}"|, else: ""
    Logger.warning(fn ->
      ~s|BOT_AUTOBAN ip=#{ip} reason="#{reason}" method=#{conn.method} path="#{conn.request_path}" qs="#{conn.query_string}"#{key_part} ua="#{safe(ua)}"|
    end)
  end

  defp safe(nil), do: "-"
  defp safe(s),  do: String.replace(s, ~r/[\r\n"]/, " ")
end
