defmodule FastApiWeb.Plugs.AutoBan do
  @moduledoc false
  import Plug.Conn
  require Logger

  @ban_table :fast_ip_banlist
  @ban_ms 24 * 60 * 60 * 1000   # 24h
  @allow MapSet.new(~w(127.0.0.1 ::1))
  @slug_regex ~r/^[a-z0-9-]+$/

  def init(opts), do: opts
  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts), do: conn

  def call(conn, _opts) do
    ensure_table_race_safe!()

    ip_raw = client_ip(conn)
    ip = normalize_ip(ip_raw)
    now = System.system_time(:millisecond)

    case :ets.lookup(@ban_table, ip) do
      [{^ip, until}] when until > now ->
        # already banned → block quietly with 403 (no extra logs)
        conn |> send_resp(403, "Forbidden") |> halt()

      [{^ip, _expired}] ->
        :ets.delete(@ban_table, ip)
        maybe_ban_by_request(conn, ip, now)

      [] ->
        maybe_ban_by_request(conn, ip, now)
    end
  end

  # Ban only if feature=salvageable (path or query) AND key is malformed
  defp maybe_ban_by_request(conn, ip, now) do
    conn = fetch_query_params(conn)
    qs_params = conn.params
    feature_q = Map.get(qs_params, "feature", "") |> to_string() |> String.downcase()
    key_q = Map.get(qs_params, "key") || Map.get(qs_params, "id")

    path = conn.request_path || ""
    down = String.downcase(path <> "?" <> (conn.query_string || ""))

    feature_hit? =
      feature_q == "salvageable" or
      String.contains?(down, "/salvageable") or
      String.contains?(down, "feature=salvageable")

    key_p = key_q || extract_key_from_path(path)

    if feature_hit? and key_p && key_malformed?(key_p) and not MapSet.member?(@allow, ip) do
      # Atomic insert: only the very first request for this IP will succeed
      if :ets.insert_new(@ban_table, {ip, now + @ban_ms}) do
        # First offender → log once and send 410 Gone
        log_ban_once(conn, ip, "auto-ban malformed-key", key_p)
        conn |> send_resp(410, "Gone") |> halt()
      else
        # Another concurrent request already banned it → silent 403
        conn |> send_resp(403, "Forbidden") |> halt()
      end
    else
      conn
    end
  end

  # Pull key from /salvageable/<key> if present
  defp extract_key_from_path(path) when is_binary(path) do
    segs = String.split(path, "/", trim: true)
    idx = Enum.find_index(segs, fn s -> String.downcase(s) == "salvageable" end)

    cond do
      idx && idx + 1 < length(segs) -> segs |> Enum.at(idx + 1) |> URI.decode()
      segs != [] -> segs |> List.last() |> URI.decode()
      true -> nil
    end
  end
  defp extract_key_from_path(_), do: nil

  defp key_malformed?(raw_key) when is_binary(raw_key) do
    k = raw_key |> URI.decode() |> String.trim()
    has_pct20? = String.contains?(raw_key, "%20")
    has_space? = String.contains?(k, " ")
    not_slug?  = not Regex.match?(@slug_regex, k)
    has_pct20? or has_space? or not_slug?
  end
  defp key_malformed?(_), do: false

  # Create ETS table safely under concurrency
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
  # Normalize IPv6-mapped IPv4 like "::ffff:34.116.22.40" -> "34.116.22.40"
  defp normalize_ip("::ffff:" <> rest), do: rest
  defp normalize_ip(ip), do: ip

  defp ip_to_string(nil), do: "-"
  defp ip_to_string(tuple) when is_tuple(tuple), do: :inet.ntoa(tuple) |> to_string()
  defp ip_to_string(str) when is_binary(str), do: str

  # Log only on the first ban insert; repeat banned hits are silent
  defp log_ban_once(conn, ip, reason, key \\ nil) do
    ua = get_req_header(conn, "user-agent") |> List.first() || "-"
    key_part = if key, do: ~s| key="#{String.replace(to_string(key), ~r/[\r\n"]/, " ")}"|, else: ""
    Logger.warning(fn ->
      ~s|BOT_AUTOBAN ip=#{ip} reason="#{reason}" method=#{conn.method} path="#{conn.request_path}" qs="#{conn.query_string}"#{key_part} ua="#{safe(ua)}"|
    end)
  end

  defp safe(nil), do: "-"
  defp safe(s),  do: String.replace(s, ~r/[\r\n"]/, " ")
end
