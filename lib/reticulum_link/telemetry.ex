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
    children = [
      # Telemetry poller for periodic metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
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

  # ── Helper functions to emit events from other modules ──

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
