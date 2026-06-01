defmodule ReticulumLink.Transport.Interface.Tcp do
  @moduledoc """
  TCP interface for Reticulum transport.

  Supports both client (outbound) and server (inbound) modes.
  Server mode listens on a port and accepts incoming connections,
  spawning a handler process for each.

  ## Configuration

      config :reticulum_link, ReticulumLink.Transport.Interface.Tcp,
        server: [
          enabled: true,
          bind: "0.0.0.0",
          port: 4242
        ],
        clients: [
          [host: "192.168.1.100", port: 4242]
        ]

  ## Packet framing

  TCP is a stream protocol, so we need framing. Each packet is prefixed
  with a 2-byte big-endian length header:

      +--------+--------+------------------+
      | Length | Length |     Packet       |
      |  MSB   |  LSB   |   (Length bytes) |
      +--------+--------+------------------+

  Max packet size: 500 bytes (Reticulum MTU) + 2 bytes length = 502 bytes.
  """

  use GenServer

  alias ReticulumLink.Transport.Packet

  require Logger

  @length_header_size 2

  # ===========================================================================
  # Client API
  # ===========================================================================

  @doc """
  Start a TCP server interface.

  ## Options

  * `:bind` — IP address to bind to (default: "0.0.0.0")
  * `:port` — Port to listen on (default: 4242)
  * `:name` — Registered process name
  """
  @spec start_server(Keyword.t()) :: GenServer.on_start()
  def start_server(opts \\ []) do
    bind = Keyword.get(opts, :bind, "0.0.0.0")
    port = Keyword.get(opts, :port, 4242)
    name = Keyword.get(opts, :name, __MODULE__)

    GenServer.start_link(
      __MODULE__,
      %{
        mode: :server,
        bind: bind,
        port: port,
        socket: nil,
        clients: %{},
        bytes_tx: 0,
        bytes_rx: 0
      },
      name: name
    )
  end

  @doc """
  Start a TCP client interface.

  ## Options

  * `:host` — Remote host to connect to
  * `:port` — Remote port (default: 4242)
  * `:name` — Registered process name
  * `:reconnect` — Auto-reconnect on disconnect (default: true)
  * `:reconnect_interval` — Seconds between reconnection attempts (default: 5)
  """
  @spec start_client(Keyword.t()) :: GenServer.on_start()
  def start_client(opts) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.get(opts, :port, 4242)
    name = Keyword.get(opts, :name, __MODULE__)
    reconnect = Keyword.get(opts, :reconnect, true)
    reconnect_interval = Keyword.get(opts, :reconnect_interval, 5)

    GenServer.start_link(
      __MODULE__,
      %{
        mode: :client,
        host: host,
        port: port,
        socket: nil,
        reconnect: reconnect,
        reconnect_interval: reconnect_interval,
        bytes_tx: 0,
        bytes_rx: 0
      },
      name: name
    )
  end

  @doc """
  Send a packet through the TCP interface.
  """
  @spec send_packet(atom(), Packet.t()) :: :ok | {:error, atom()}
  def send_packet(name \\ __MODULE__, %Packet{} = packet) do
    GenServer.call(name, {:send_packet, packet})
  end

  @doc """
  Get interface status.
  """
  @spec status(atom()) :: map()
  def status(name \\ __MODULE__) do
    GenServer.call(name, :status)
  end

  @doc """
  Close the interface.
  """
  @spec close(atom()) :: :ok
  def close(name \\ __MODULE__) do
    GenServer.call(name, :close)
  end

  @doc """
  Check if the interface is connected.
  """
  @spec connected?(atom()) :: boolean()
  def connected?(name \\ __MODULE__) do
    GenServer.call(name, :connected?)
  catch
    :exit, _ -> false
  end

  # ===========================================================================
  # Server callbacks
  # ===========================================================================

  @impl true
  def init(%{mode: :server} = state) do
    case :gen_tcp.listen(state.port, [
           :binary,
           packet: 0,
           active: true,
           reuseaddr: true,
           ip: parse_ip(state.bind)
         ]) do
      {:ok, listen_socket} ->
        Logger.info("TCP server listening on #{state.bind}:#{state.port}")
        accept_loop(self(), listen_socket)
        {:ok, %{state | socket: listen_socket}}

      {:error, reason} ->
        Logger.error(
          "TCP server failed to listen on #{state.bind}:#{state.port}: #{inspect(reason)}"
        )

        {:stop, reason}
    end
  end

  @impl true
  def init(%{mode: :client} = state) do
    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call({:send_packet, %Packet{} = packet}, _from, state) do
    case do_send_packet(state, packet) do
      :ok -> {:reply, :ok, increment_tx(state, byte_size(packet.raw || <<>>))}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, build_status(state), state}
  end

  @impl true
  def handle_call(:close, _from, state) do
    if state.socket do
      :gen_tcp.close(state.socket)
    end

    {:stop, :normal, :ok, %{state | socket: nil}}
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, state.socket != nil, state}
  end

  @impl true
  def handle_info(:connect, %{mode: :client} = state) do
    case :gen_tcp.connect(to_charlist(state.host), state.port, [:binary, packet: 0, active: true]) do
      {:ok, socket} ->
        Logger.info("TCP client connected to #{state.host}:#{state.port}")
        {:noreply, %{state | socket: socket}}

      {:error, reason} ->
        Logger.warning(
          "TCP client connection to #{state.host}:#{state.port} failed: #{inspect(reason)}"
        )

        if state.reconnect do
          Process.send_after(self(), :connect, state.reconnect_interval * 1000)
        end

        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    new_state = process_received_data(state, data)
    {:noreply, increment_rx(new_state, byte_size(data))}
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, %{mode: :client, reconnect: true} = state) do
    Logger.warning("TCP client connection closed, reconnecting...")
    Process.send_after(self(), :connect, state.reconnect_interval * 1000)
    {:noreply, %{state | socket: nil}}
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, state) do
    Logger.info("TCP connection closed")
    {:noreply, %{state | socket: nil}}
  end

  @impl true
  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.error("TCP error: #{inspect(reason)}")
    {:noreply, %{state | socket: nil}}
  end

  @impl true
  def handle_info({:new_client, socket, client_pid}, %{mode: :server} = state) do
    clients = Map.put(state.clients, client_pid, %{socket: socket, buffer: <<>>})
    {:noreply, %{state | clients: clients}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{mode: :server} = state) do
    clients = Map.delete(state.clients, pid)
    {:noreply, %{state | clients: clients}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ===========================================================================
  # Internal helpers
  # ===========================================================================

  defp accept_loop(parent, listen_socket) do
    spawn_link(fn -> do_accept(parent, listen_socket) end)
  end

  defp do_accept(parent, listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        client_pid = spawn_link(fn -> client_handler(parent, socket) end)
        Process.monitor(client_pid)
        send(parent, {:new_client, socket, client_pid})
        do_accept(parent, listen_socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.error("TCP accept error: #{inspect(reason)}")
        Process.sleep(1000)
        do_accept(parent, listen_socket)
    end
  end

  defp client_handler(parent, socket) do
    receive do
      {:tcp, ^socket, data} ->
        # Forward to parent for processing
        send(parent, {:tcp, socket, data})
        client_handler(parent, socket)

      {:tcp_closed, ^socket} ->
        :ok

      {:tcp_error, ^socket, _reason} ->
        :ok
    end
  end

  defp do_send_packet(%{socket: nil}, _packet) do
    {:error, :not_connected}
  end

  defp do_send_packet(%{socket: socket}, %Packet{raw: raw}) when is_binary(raw) do
    length_prefix = <<byte_size(raw)::big-16>>
    :gen_tcp.send(socket, length_prefix <> raw)
  end

  defp do_send_packet(_state, _packet) do
    {:error, :packet_not_packed}
  end

  defp process_received_data(state, data) do
    buffer = Map.get(state, :buffer, <<>>) <> data
    process_buffer(state, buffer)
  end

  defp process_buffer(state, buffer) when byte_size(buffer) < @length_header_size do
    Map.put(state, :buffer, buffer)
  end

  defp process_buffer(state, buffer) do
    <<length::big-16, rest::binary>> = buffer

    if byte_size(rest) < length do
      Map.put(state, :buffer, buffer)
    else
      <<packet_data::binary-size(length), remaining::binary>> = rest

      # Dispatch packet to transport layer
      dispatch_packet(packet_data)

      process_buffer(state, remaining)
    end
  end

  defp dispatch_packet(packet_data) do
    case Packet.unpack(packet_data) do
      {:ok, packet} ->
        Phoenix.PubSub.broadcast(
          ReticulumLink.PubSub,
          "reticulum:packets",
          {:packet_received, :tcp, packet}
        )

      {:error, reason} ->
        Logger.debug("Failed to unpack packet: #{inspect(reason)}")
    end
  end

  defp parse_ip("0.0.0.0"), do: {0, 0, 0, 0}
  defp parse_ip("127.0.0.1"), do: {127, 0, 0, 1}

  defp parse_ip(ip) when is_binary(ip) do
    ip
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()
  end

  defp increment_tx(state, bytes), do: %{state | bytes_tx: state.bytes_tx + bytes}
  defp increment_rx(state, bytes), do: %{state | bytes_rx: state.bytes_rx + bytes}

  defp build_status(state) do
    %{
      mode: state.mode,
      connected: state.socket != nil,
      bytes_tx: state.bytes_tx,
      bytes_rx: state.bytes_rx,
      host: Map.get(state, :host),
      port: Map.get(state, :port),
      bind: Map.get(state, :bind),
      client_count: map_size(Map.get(state, :clients, %{}))
    }
  end
end
