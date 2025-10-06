defmodule FastApiWeb.Plugs.AutoBan do
  @moduledoc false
  import Plug.Conn

  @ban_table :fast_ip_banlist
  @ban_ms 24 * 60 * 60 * 1000   # 24h
  @allow MapSet.new(~w(127.0.0.1 ::1))
  @slug_regex ~r/^[a-z0-9-]+$/

  def init(opts), do: opts
  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts), do: conn

  def call(conn, _opts) do
    # don't create ETS here; fail open if missing
    ip = conn |> client_ip() |> normalize_ip()
    now = System.system_time(:millisecond)

    banned? =
      case :ets.info(@ban_table) do
        :undefined ->
          false

        _ ->
          # Guard against races / hot reloads
          try do
            case :ets.lookup(@ban_table, ip) do
              [{^ip, until}] when until > now ->
                true

              [{^ip, _expired}] ->
                # cleanup stale entry, then allow
                :ets.delete(@ban_table, ip)
                false

              [] ->
                false
            end
          rescue
            ArgumentError -> false
          end
      end

    if banned? do
      conn |> send_resp(403, "Forbidden") |> halt()
    else
      # don’t ever ban on the fly anymore
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

  # no longer used in call/2
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
  defp normalize_ip("::ffff:" <> rest), do: rest
  defp normalize_ip(ip), do: ip

  defp ip_to_string(nil), do: "-"
  defp ip_to_string(tuple) when is_tuple(tuple), do: :inet.ntoa(tuple) |> to_string()
  defp ip_to_string(str) when is_binary(str), do: str
end
