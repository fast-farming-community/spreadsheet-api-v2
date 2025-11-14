defmodule FastApiWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # emits vm.* metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Buckets for request/query durations (milliseconds)
  @ms_buckets [5, 10, 20, 50, 100, 250, 500, 1_000, 2_000, 5_000]

  def metrics do
    [
      # ------------------------------------
      # Phoenix Metrics (use histograms)
      # ------------------------------------
      distribution("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: @ms_buckets]
      ),
      distribution("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond},
        reporter_options: [buckets: @ms_buckets]
      ),

      # ------------------------------------
      # Database Metrics (use histograms)
      # ------------------------------------
      distribution("fast_api.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements",
        reporter_options: [buckets: @ms_buckets]
      ),
      distribution("fast_api.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database",
        reporter_options: [buckets: @ms_buckets]
      ),
      distribution("fast_api.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query",
        reporter_options: [buckets: @ms_buckets]
      ),
      distribution("fast_api.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection",
        reporter_options: [buckets: @ms_buckets]
      ),
      distribution("fast_api.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query",
        reporter_options: [buckets: @ms_buckets]
      ),

      # feature/detail request counters stay defined (no exporter uses them now)
      counter("fast_api.feature.request.count",
        tags: [:collection],
        description: "The amount of requests made to feature endpoints"
      ),
      counter("fast_api.detail.request.count",
        tags: [:collection, :item],
        description: "The amount of requests made to detail endpoints"
      ),

      # ------------------------------------
      # VM Metrics (use gauges/last_value)
      # ------------------------------------
      last_value("vm.memory.total", unit: {:byte, :kilobyte}),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {FastApiWeb, :count_users, []}
    ]
  end
end
