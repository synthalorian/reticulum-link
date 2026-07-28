defmodule ReticulumLink.Telemetry do
  @moduledoc """
  Telemetry events and Prometheus metrics for Reticulum Link.

  Emits events for:
  - [:reticulum_link, :link, :created] — new link established
  - [:reticulum_link, :link, :closed] — link closed
  - [:reticulum_link, :message, :received] — LXMF message received
  - [:reticulum_link, :message, :propagated] — LXMF message propagated
  - [:reticulum_link, :path, :discovered] — new path discovered
  - [:reticulum_link, :transport, :packet, :sent] — packet sent
  - [:reticulum_link, :transport, :packet, :received] — packet received

  Prometheus metrics available at /metrics via MetricsController.
  """

  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    :ok = init_metrics_table()
    :ok = attach_metrics_handler()

    children = [
      # Telemetry poller for periodic metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # ETS table backing the Prometheus text endpoint in
  # ReticulumLink.Web.MetricsController. Counters and last values for
  # every emitted [:reticulum_link | _] event are maintained here.
  @metrics_table :telemetry_event_table
  @metrics_handler_id {__MODULE__, :metrics_table}

  @doc false
  def metrics_table, do: @metrics_table

  @doc false
  def metrics_events do
    [
      [:reticulum_link, :link, :created],
      [:reticulum_link, :link, :closed],
      [:reticulum_link, :link, :active],
      [:reticulum_link, :message, :received],
      [:reticulum_link, :message, :propagated],
      [:reticulum_link, :message, :stored],
      [:reticulum_link, :path, :discovered],
      [:reticulum_link, :path, :active],
      [:reticulum_link, :transport, :packet, :sent],
      [:reticulum_link, :transport, :packet, :received],
      [:reticulum_link, :transport, :packet, :forwarded],
      [:reticulum_link, :system, :memory],
      [:reticulum_link, :system, :process]
    ]
  end

  defp init_metrics_table do
    case :ets.whereis(@metrics_table) do
      :undefined ->
        :ets.new(@metrics_table, [
          :named_table,
          :public,
          :set,
          {:write_concurrency, true},
          {:read_concurrency, true}
        ])

        :ok

      _tid ->
        :ok
    end
  end

  defp attach_metrics_handler do
    _ = :telemetry.detach(@metrics_handler_id)

    case :telemetry.attach_many(
           @metrics_handler_id,
           metrics_events(),
           &__MODULE__.handle_metrics_event/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_metrics_event(event, measurements, _metadata, _config) do
    count = Map.get(measurements, :count, 1)

    :ets.update_counter(@metrics_table, {event, :counter}, {2, count}, {{event, :counter}, 0})

    case last_measurement(measurements) do
      nil -> :ok
      value -> :ets.insert(@metrics_table, {{event, :last_value}, value})
    end

    :ok
  end

  defp last_measurement(measurements) do
    measurements[:usage] ||
      measurements[:bytes] ||
      Enum.find_value(measurements, fn
        {_key, value} when is_integer(value) or is_float(value) -> value
        _pair -> nil
      end)
  end

  def metrics do
    [
      # Link metrics
      counter("reticulum_link.link.created.count"),
      counter("reticulum_link.link.closed.count"),
      last_value("reticulum_link.link.active.count"),

      # Message metrics
      counter("reticulum_link.message.received.count"),
      counter("reticulum_link.message.propagated.count"),
      last_value("reticulum_link.message.stored.count"),

      # Path metrics
      counter("reticulum_link.path.discovered.count"),
      last_value("reticulum_link.path.active.count"),

      # Transport metrics
      counter("reticulum_link.transport.packet.sent.count"),
      counter("reticulum_link.transport.packet.received.count"),
      counter("reticulum_link.transport.packet.forwarded.count"),

      # System metrics
      last_value("reticulum_link.system.memory.usage", unit: :byte),
      last_value("reticulum_link.system.process.count")
    ]
  end

  defp periodic_measurements do
    [
      {__MODULE__, :collect_system_metrics, []}
    ]
  end

  @doc """
  Collect system-level metrics and emit telemetry events.
  """
  def collect_system_metrics do
    memory = :erlang.memory(:total)
    process_count = :erlang.system_info(:process_count)

    :telemetry.execute([:reticulum_link, :system, :memory], %{usage: memory}, %{})
    :telemetry.execute([:reticulum_link, :system, :process], %{count: process_count}, %{})
  end

  defmodule ReticulumLink.Telemetry.PromExPlugin do
    @moduledoc """
    Custom PromEx plugin that wires Telemetry events to Prometheus metrics.
    """
    use PromEx.Plugin

    alias PromEx.MetricTypes.{Event, Polling}

    @link_created_event [:reticulum_link, :link, :created]
    @link_closed_event [:reticulum_link, :link, :closed]
    @message_received_event [:reticulum_link, :message, :received]
    @message_propagated_event [:reticulum_link, :message, :propagated]
    @packet_sent_event [:reticulum_link, :transport, :packet, :sent]
    @packet_received_event [:reticulum_link, :transport, :packet, :received]
    @packet_forwarded_event [:reticulum_link, :transport, :packet, :forwarded]

    @impl true
    def event_metrics(_opts) do
      metric_prefix = [:reticulum_link]

      Event.build(
        :reticulum_link_events,
        [
          # Link counters
          counter(metric_prefix ++ [:link, :created, :total],
            event_name: @link_created_event,
            description: "Total number of links created"
          ),
          counter(metric_prefix ++ [:link, :closed, :total],
            event_name: @link_closed_event,
            description: "Total number of links closed"
          ),

          # Message counters
          counter(metric_prefix ++ [:message, :received, :total],
            event_name: @message_received_event,
            description: "Total LXMF messages received"
          ),
          counter(metric_prefix ++ [:message, :propagated, :total],
            event_name: @message_propagated_event,
            description: "Total LXMF messages propagated"
          ),

          # Packet counters
          counter(metric_prefix ++ [:packet, :sent, :total],
            event_name: @packet_sent_event,
            measurement: :bytes,
            description: "Total bytes sent"
          ),
          counter(metric_prefix ++ [:packet, :received, :total],
            event_name: @packet_received_event,
            measurement: :bytes,
            description: "Total bytes received"
          ),
          counter(metric_prefix ++ [:packet, :forwarded, :total],
            event_name: @packet_forwarded_event,
            measurement: :bytes,
            description: "Total bytes forwarded"
          )
        ]
      )
    end

    @impl true
    def polling_metrics(_opts) do
      metric_prefix = [:reticulum_link]

      Polling.build(
        :reticulum_link_polling,
        10_000,
        {__MODULE__, :collect_polling_metrics, []},
        [
          last_value(metric_prefix ++ [:link, :active],
            description: "Current number of active links"
          ),
          last_value(metric_prefix ++ [:message, :stored],
            description: "Current messages in store"
          ),
          last_value(metric_prefix ++ [:path, :active],
            description: "Current active paths"
          ),
          last_value(metric_prefix ++ [:system, :memory, :bytes],
            description: "Current memory usage in bytes"
          ),
          last_value(metric_prefix ++ [:system, :process, :count],
            description: "Current process count"
          )
        ]
      )
    end

    @doc false
    def collect_polling_metrics do
      memory = :erlang.memory(:total)
      process_count = :erlang.system_info(:process_count)

      :telemetry.execute([:reticulum_link, :system, :memory], %{bytes: memory}, %{})
      :telemetry.execute([:reticulum_link, :system, :process], %{count: process_count}, %{})
    end
  end

  @doc """
  Build PromEx specification with all plugins.
  """
  def promex_spec do
    [
      # BEAM VM metrics (processes, memory, schedulers)
      {PromEx.Plugins.Beam, otp_app: :reticulum_link},
      # Application metrics
      {ReticulumLink.Telemetry.PromExPlugin, []}
    ]
  end

  @doc "Emit link created event"
  def link_created(link_id, meta \\ %{}) do
    :telemetry.execute(
      [:reticulum_link, :link, :created],
      %{count: 1},
      Map.put(meta, :link_id, link_id)
    )
  end

  @doc "Emit link closed event"
  def link_closed(link_id, meta \\ %{}) do
    :telemetry.execute(
      [:reticulum_link, :link, :closed],
      %{count: 1},
      Map.put(meta, :link_id, link_id)
    )
  end

  @doc "Emit message received event"
  def message_received(message_hash, meta \\ %{}) do
    :telemetry.execute(
      [:reticulum_link, :message, :received],
      %{count: 1},
      Map.put(meta, :hash, message_hash)
    )
  end

  @doc "Emit message propagated event"
  def message_propagated(message_hash, meta \\ %{}) do
    :telemetry.execute(
      [:reticulum_link, :message, :propagated],
      %{count: 1},
      Map.put(meta, :hash, message_hash)
    )
  end

  @doc "Emit path discovered event"
  def path_discovered(destination_hash, hops, meta \\ %{}) do
    :telemetry.execute(
      [:reticulum_link, :path, :discovered],
      %{count: 1},
      Map.merge(meta, %{destination: destination_hash, hops: hops})
    )
  end

  @doc "Emit packet sent event"
  def packet_sent(bytes, meta \\ %{}) do
    :telemetry.execute([:reticulum_link, :transport, :packet, :sent], %{bytes: bytes}, meta)
  end

  @doc "Emit packet received event"
  def packet_received(bytes, meta \\ %{}) do
    :telemetry.execute([:reticulum_link, :transport, :packet, :received], %{bytes: bytes}, meta)
  end

  @doc "Emit packet forwarded event"
  def packet_forwarded(bytes, meta \\ %{}) do
    :telemetry.execute([:reticulum_link, :transport, :packet, :forwarded], %{bytes: bytes}, meta)
  end
end
