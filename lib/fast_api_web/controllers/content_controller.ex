defmodule FastApiWeb.ContentController do
  use FastApiWeb, :controller

  alias FastApi.Repo
  alias FastApi.Schemas.Fast
  import Ecto.Query
  require Logger

  @lny_dates %{
    2026 => ~D[2026-02-17],
    2027 => ~D[2027-02-06],
    2028 => ~D[2028-01-26],
    2029 => ~D[2029-02-13],
    2030 => ~D[2030-02-03],
    2031 => ~D[2031-01-23],
    2032 => ~D[2032-02-11],
    2033 => ~D[2033-01-31],
    2034 => ~D[2034-02-19],
    2035 => ~D[2035-02-08],
    2036 => ~D[2036-01-28],
    2037 => ~D[2037-02-15],
    2038 => ~D[2038-02-04],
    2039 => ~D[2039-01-24],
    2040 => ~D[2040-02-12],
    2041 => ~D[2041-02-01],
    2042 => ~D[2042-01-22],
    2043 => ~D[2043-02-10],
    2044 => ~D[2044-01-30],
    2045 => ~D[2045-02-17],
    2046 => ~D[2046-02-06],
    2047 => ~D[2047-01-26],
    2048 => ~D[2048-02-14],
    2049 => ~D[2049-02-02],
    2050 => ~D[2050-01-23]
  }

  def roll_forward_lny! do
    Fast.About
    |> where([a], a.title == "Lunar New Year")
    |> where([a], not is_nil(a.inserted_at) and not is_nil(a.updated_at))
    |> where([a], fragment("date(?) < CURRENT_DATE", a.updated_at))
    |> where(
      [a],
      fragment(
        "EXTRACT(YEAR FROM ?) >= EXTRACT(YEAR FROM CURRENT_DATE) - 1",
        a.updated_at
      )
    )
    |> Repo.all()
    |> Enum.each(fn a ->
      prev_year = (a.updated_at |> NaiveDateTime.to_date()).year
      next_year = prev_year + 1

      case Map.fetch(@lny_dates, next_year) do
        {:ok, lny_date} ->
          start_date = Date.add(lny_date, -21)
          start_dt = NaiveDateTime.new!(start_date, ~T[00:00:00])
          end_dt = NaiveDateTime.new!(lny_date, ~T[00:00:00])

          Repo.update_all(
            from(x in Fast.About, where: x.id == ^a.id),
            set: [inserted_at: start_dt, updated_at: end_dt]
          )

        :error ->
          Logger.warning("LNY roll-forward skipped: missing LNY date for #{next_year}")
      end
    end)

    :ok
  end

  def roll_forward_about! do
    roll_forward_lny!()

    Repo.query!(
      """
      WITH due AS (
        SELECT
          id,
          CASE
            WHEN date(updated_at) < CURRENT_DATE THEN
              CEIL( (CURRENT_DATE - date(updated_at))::numeric / 365 )::int
            ELSE 0
          END AS years_to_add
        FROM public.about
        WHERE inserted_at IS NOT NULL
          AND updated_at  IS NOT NULL
          AND date(updated_at) < CURRENT_DATE
          AND EXTRACT(YEAR FROM updated_at) >= EXTRACT(YEAR FROM CURRENT_DATE) - 1
          AND title <> 'Lunar New Year'
      )
      UPDATE public.about a
      SET
        inserted_at = a.inserted_at + make_interval(years => d.years_to_add),
        updated_at  = a.updated_at  + make_interval(years => d.years_to_add)
      FROM due d
      WHERE a.id = d.id
        AND d.years_to_add > 0
      """
    )

    :ok
  end

  defp active_or_published(queryable) do
    from a in queryable,
      where:
        a.published or
          (fragment("COALESCE(date(?), '-infinity'::date) <= CURRENT_DATE", a.inserted_at) and
             fragment("COALESCE(date(?), 'infinity'::date) >= CURRENT_DATE", a.updated_at))
  end

  def index(conn, _params) do
    data =
      Fast.About
      |> active_or_published()
      |> order_by([a], asc_nulls_last: a.order)
      |> Repo.all()

    json(conn, data)
  end

  def builds(conn, _params) do
    data =
      Fast.Build
      |> Repo.all()
      |> Enum.filter(& &1.published)

    json(conn, data)
  end

  def changelog(conn, _params) do
    case github_file("CHANGELOG.md") do
      {:ok, body} -> text(conn, body)
      {:error, {:upstream_timeout, msg}} ->
        Logger.warning("changelog: upstream timeout: #{msg}")
        send_resp(conn, 504, "Upstream timeout")
      {:error, {:upstream_status, status, _body}} ->
        Logger.warning("changelog: upstream status #{status}")
        send_resp(conn, 502, "Upstream returned #{status}")
      {:error, {:upstream_error, msg}} ->
        Logger.error("changelog: upstream error: #{msg}")
        send_resp(conn, 502, "Upstream error")
    end
  end

  def content_updates(conn, _params) do
    case github_file("WEBSITE_CONTENT_UPDATES.md") do
      {:ok, body} -> text(conn, body)
      {:error, {:upstream_timeout, msg}} ->
        Logger.warning("content_updates: upstream timeout: #{msg}")
        send_resp(conn, 504, "Upstream timeout")
      {:error, {:upstream_status, status, _body}} ->
        Logger.warning("content_updates: upstream status #{status}")
        send_resp(conn, 502, "Upstream returned #{status}")
      {:error, {:upstream_error, msg}} ->
        Logger.error("content_updates: upstream error: #{msg}")
        send_resp(conn, 502, "Upstream error")
    end
  end

  def todos(conn, _params) do
    case github_file("WEBSITE_TODOS.md") do
      {:ok, body} -> text(conn, body)
      {:error, {:upstream_timeout, msg}} ->
        Logger.warning("todos: upstream timeout: #{msg}")
        send_resp(conn, 504, "Upstream timeout")
      {:error, {:upstream_status, status, _body}} ->
        Logger.warning("todos: upstream status #{status}")
        send_resp(conn, 502, "Upstream returned #{status}")
      {:error, {:upstream_error, msg}} ->
        Logger.error("todos: upstream error: #{msg}")
        send_resp(conn, 502, "Upstream error")
    end
  end

  def guides(conn, _params) do
    data =
      Fast.Guide
      |> Repo.all()
      |> Enum.filter(& &1.published)
      |> Enum.sort_by(& &1.order, :asc)

    json(conn, data)
  end

  @github_raw_base "https://raw.githubusercontent.com/fast-farming-community/public/main/"
  @finch_timeout 12_000
  @headers [{"accept", "text/plain"}]

  @spec github_file(String.t()) ::
          {:ok, binary()}
          | {:error, {:upstream_timeout, String.t()}}
          | {:error, {:upstream_status, non_neg_integer(), binary()}}
          | {:error, {:upstream_error, String.t()}}
  def github_file(filename) do
    url = @github_raw_base <> filename
    req = Finch.build(:get, url, @headers, nil)

    case Finch.request(req, FastApi.FinchPublic, receive_timeout: @finch_timeout) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:upstream_status, status, body}}

      {:error, %Mint.TransportError{} = err} ->
        {:error, {:upstream_timeout, Exception.message(err)}}

      {:error, err} ->
        {:error, {:upstream_error, Exception.message(err)}}
    end
  end
end
