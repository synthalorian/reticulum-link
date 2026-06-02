defmodule ReticulumLink.Transport.Transport do
  @moduledoc """
  Transport mode coordinator — enables backbone node operation.

  When transport mode is enabled, the node:
  - Forwards packets between interfaces
  - Participates in path discovery
  - Relays announces
  - Maintains routing tables

  When disabled (default), the node only handles local traffic.

  ## Configuration

      config :reticulum_link, ReticulumLink.Transport.Transport,
        enabled: true,
        max_hops: 128
  """

  use GenServer

  require Logger

  @default_max_hops 128

  # ===========================================================================
  # Client API
  # ===========================================================================

  @doc """
  Start the transport coordinator.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Check if transport mode is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    GenServer.call(__MODULE__, :enabled?)
  end

  @doc """
  Enable transport mode.
  """
  @spec enable() :: :ok
  def enable do
    GenServer.call(__MODULE__, :enable)
  end

  @doc """
  Disable transport mode.
  """
  @spec disable() :: :ok
  def disable do
    GenServer.call(__MODULE__, :disable)
  end

  @doc """
  Process an inbound packet for forwarding.

  If transport mode is enabled and the packet is not for a local
  destination, it will be forwarded to the appropriate interface.
  """
  @spec handle_inbound_packet(map(), binary()) :: :ok | {:drop, atom()}
  def handle_inbound_packet(packet, interface) do
    GenServer.call(__MODULE__, {:handle_inbound, packet, interface})
  end

  @doc """
  Forward a packet to a specific destination hash via the best path.

  Looks up the path in PathManager and broadcasts on the forwarding topic.
  """
  @spec forward_to_destination(binary(), map()) :: :ok | {:error, atom()}
  def forward_to_destination(destination_hash, packet) do
    GenServer.call(__MODULE__, {:forward_to, destination_hash, packet})
  end

  @doc """
  Get transport statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Reset statistics counters.
  """
  @spec reset_stats() :: :ok
  def reset_stats do
    GenServer.call(__MODULE__, :reset_stats)
  end

  # ===========================================================================
  # Server callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    enabled = Keyword.get(opts, :enabled, false)
    max_hops = Keyword.get(opts, :max_hops, @default_max_hops)

    if enabled do
      Logger.info("Transport mode enabled (max_hops: #{max_hops})")
    else
      Logger.info("Transport mode disabled (local node only)")
    end

    {:ok, %{enabled: enabled, max_hops: max_hops, forwarded: 0, dropped: 0}}
  end

  @impl true
  def handle_call(:enabled?, _from, state) do
    {:reply, state.enabled, state}
  end

  @impl true
  def handle_call(:enable, _from, state) do
    Logger.info("Transport mode enabled")
    {:reply, :ok, %{state | enabled: true}}
  end

  @impl true
  def handle_call(:disable, _from, state) do
    Logger.info("Transport mode disabled")
    {:reply, :ok, %{state | enabled: false}}
  end

  @impl true
  def handle_call({:handle_inbound, _packet, _interface}, _from, %{enabled: false} = state) do
    # Local node only — drop transit packets
    {:reply, {:drop, :transport_disabled}, %{state | dropped: state.dropped + 1}}
  end

  @impl true
  def handle_call({:handle_inbound, packet, _interface}, _from, state) do
    hops = Map.get(packet, :hops, 0)

    cond do
      hops >= state.max_hops ->
        {:reply, {:drop, :max_hops_exceeded}, %{state | dropped: state.dropped + 1}}

      local_destination?(packet) ->
        {:reply, :ok, state}

      true ->
        forward_packet(packet)
        {:reply, :ok, %{state | forwarded: state.forwarded + 1}}
    end
  end

  @impl true
  def handle_call({:forward_to, destination_hash, packet}, _from, state) do
    if state.enabled do
      do_forward_to(destination_hash, packet, state)
    else
      {:reply, {:error, :transport_disabled}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       enabled: state.enabled,
       max_hops: state.max_hops,
       forwarded: state.forwarded,
       dropped: state.dropped
     }, state}
  end

  @impl true
  def handle_call(:reset_stats, _from, state) do
    {:reply, :ok, %{state | forwarded: 0, dropped: 0}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ===========================================================================
  # Internal helpers
  # ===========================================================================

  defp local_destination?(packet) do
    dst_hash = Map.get(packet, :destination_hash)

    if dst_hash do
      # Check if we have a local destination matching this hash
      case Registry.lookup(ReticulumLink.DestinationRegistry, dst_hash) do
        [] -> false
        _ -> true
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp do_forward_to(destination_hash, packet, state) do
    hops = Map.get(packet, :hops, 0)

    if hops >= state.max_hops do
      {:reply, {:error, :max_hops_exceeded}, %{state | dropped: state.dropped + 1}}
    else
      try_path_forward(destination_hash, packet, state)
    end
  end

  defp try_path_forward(destination_hash, packet, state) do
    case ReticulumLink.Transport.PathManager.lookup_path(destination_hash) do
      {:ok, path_entry} ->
        forwarded = increment_hops(packet)
        broadcast_forward(forwarded, path_entry)
        {:reply, :ok, %{state | forwarded: state.forwarded + 1}}

      {:error, :no_path} ->
        forward_packet(packet)
        {:reply, :ok, %{state | forwarded: state.forwarded + 1}}
    end
  end

  defp broadcast_forward(packet, path_entry) do
    tid = path_entry.transport_id

    topic =
      if tid,
        do: "reticulum:forward:#{Base.encode16(tid)}",
        else: "reticulum:forward:broadcast"

    Phoenix.PubSub.broadcast(
      ReticulumLink.PubSub,
      topic,
      {:forward_packet, packet, path_entry}
    )
  end

  defp forward_packet(packet) do
    # Increment hop count and broadcast to forwarding topic
    Phoenix.PubSub.broadcast(
      ReticulumLink.PubSub,
      "reticulum:forward",
      {:forward_packet, packet}
    )
  end

  defp increment_hops(packet) do
    Map.update(packet, :hops, 1, &(&1 + 1))
  end
end
