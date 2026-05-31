defmodule ReticulumLink.Transport.Interface.AutoInterface do
  @moduledoc """
  AutoInterface for local network discovery via UDP broadcast/multicast.

  Automatically discovers other Reticulum nodes on the local network
  and establishes peer-to-peer TCP links.

  ## How it works

  1. Listens on a UDP multicast group (224.0.0.1:2970) for peer announcements
  2. Broadcasts its own presence periodically
  3. When a peer is discovered, initiates a TCP connection

  This is a stub implementation. Full mDNS/UDP discovery will be
  implemented in a future release.
  """

  use GenServer

  require Logger

  @multicast_group {224, 0, 0, 1}
  @discovery_port 2970
  @announce_interval 60_000

  # ===========================================================================
  # Client API
  # ===========================================================================

  @doc """
  Start the AutoInterface discovery service.

  ## Options

  * `:port` — UDP discovery port (default: 2970)
  * `:name` — Registered process name
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    port = Keyword.get(opts, :port, @discovery_port)
    name = Keyword.get(opts, :name, __MODULE__)

    GenServer.start_link(__MODULE__, %{port: port, socket: nil, peers: %{}, announce_timer: nil},
      name: name
    )
  end

  @doc """
  Get list of discovered peers.

  Returns a list of `{ip, port}` tuples.
  """
  @spec peers(atom()) :: [{:inet.ip_address(), :inet.port_number()}]
  def peers(name \\ __MODULE__) do
    GenServer.call(name, :peers)
  end

  # ===========================================================================
  # Server callbacks
  # ===========================================================================

  @impl true
  def init(state) do
    case :gen_udp.open(state.port, [:binary, active: true, reuseaddr: true, multicast_loop: true]) do
      {:ok, socket} ->
        # Join multicast group
        :ok = :inet.setopts(socket, add_membership: {@multicast_group, {0, 0, 0, 0}})
        timer = Process.send_after(self(), :announce, @announce_interval)
        Logger.info("AutoInterface listening on UDP port #{state.port}")
        {:ok, %{state | socket: socket, announce_timer: timer}}

      {:error, reason} ->
        Logger.warning("AutoInterface failed to bind UDP port #{state.port}: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_call(:peers, _from, state) do
    {:reply, Map.keys(state.peers), state}
  end

  @impl true
  def handle_info(:announce, state) do
    if state.socket do
      # Broadcast our presence
      announce = build_announce()
      :gen_udp.send(state.socket, @multicast_group, state.port, announce)
    end

    timer = Process.send_after(self(), :announce, @announce_interval)
    {:noreply, %{state | announce_timer: timer}}
  end

  @impl true
  def handle_info({:udp, _socket, ip, port, data}, state) do
    case parse_announce(data) do
      {:ok, peer_info} ->
        peers = Map.put(state.peers, {ip, port}, peer_info)
        {:noreply, %{state | peers: peers}}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ===========================================================================
  # Internal helpers
  # ===========================================================================

  defp build_announce do
    # Simple announce format: "RETICULUM:v0.1.0"
    "RETICULUM:v#{ReticulumLink.version()}"
  end

  defp parse_announce("RETICULUM:" <> _version = data) do
    {:ok, %{version: String.trim_leading(data, "RETICULUM:v")}}
  end

  defp parse_announce(_), do: :error
end
