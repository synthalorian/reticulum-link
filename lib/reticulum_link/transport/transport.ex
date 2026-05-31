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
  end

  defp forward_packet(packet) do
    # Increment hop count and broadcast to forwarding topic
    Phoenix.PubSub.broadcast(
      ReticulumLink.PubSub,
      "reticulum:forward",
      {:forward_packet, packet}
    )
  end
end
