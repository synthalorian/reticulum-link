defmodule ReticulumLink.Transport.Interface.Serial do
  @moduledoc """
  Serial/UART interface for Reticulum transport (RNode support).

  Communicates with RNode firmware over a serial port. RNode handles
  the LoRa/RF layer; this module handles the serial protocol.

  ## Configuration

      config :reticulum_link, ReticulumLink.Transport.Interface.Serial,
        device: "/dev/ttyUSB0",
        baud: 115200

  ## RNode Serial Protocol

  RNode uses a simple framed protocol over serial:
  - KISS-like framing with FEND (0xC0) bytes
  - Each frame contains a Reticulum packet

  This is a stub implementation. Full RNode protocol support requires
  the `circuits_uart` dependency (marked as optional in mix.exs).
  """

  use GenServer

  require Logger

  @fend 0xC0

  # ===========================================================================
  # Client API
  # ===========================================================================

  @doc """
  Start a serial interface.

  ## Options

  * `:device` — Serial device path (default: "/dev/ttyUSB0")
  * `:baud` — Baud rate (default: 115200)
  * `:name` — Registered process name
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    device = Keyword.get(opts, :device, "/dev/ttyUSB0")
    baud = Keyword.get(opts, :baud, 115_200)
    name = Keyword.get(opts, :name, __MODULE__)

    GenServer.start_link(
      __MODULE__,
      %{device: device, baud: baud, uart: nil, connected: false, bytes_tx: 0, bytes_rx: 0},
      name: name
    )
  end

  @doc """
  Send raw data through the serial interface.
  """
  @spec send_raw(atom(), binary()) :: :ok | {:error, atom()}
  def send_raw(name \\ __MODULE__, data) when is_binary(data) do
    GenServer.call(name, {:send_raw, data})
  end

  @doc """
  Get interface status.
  """
  @spec status(atom()) :: map()
  def status(name \\ __MODULE__) do
    GenServer.call(name, :status)
  end

  # ===========================================================================
  # Server callbacks
  # ===========================================================================

  @impl true
  def init(state) do
    if Code.ensure_loaded?(Circuits.UART) do
      init_with_uart(state)
    else
      Logger.info("Serial interface stub: circuits_uart not available")
      {:ok, state}
    end
  end

  defp init_with_uart(state) do
    case Circuits.UART.start_link() do
      {:ok, uart} ->
        init_open_uart(state, uart)

      {:error, reason} ->
        Logger.warning("Serial UART start failed: #{inspect(reason)}")
        {:ok, state}
    end
  end

  defp init_open_uart(state, uart) do
    case Circuits.UART.open(uart, state.device, speed: state.baud, active: true) do
      :ok ->
        Logger.info("Serial interface opened: #{state.device} @ #{state.baud} baud")
        {:ok, %{state | uart: uart, connected: true}}

      {:error, reason} ->
        Logger.warning("Serial interface failed to open #{state.device}: #{inspect(reason)}")

        {:ok, %{state | uart: uart}}
    end
  end

  @impl true
  def handle_call({:send_raw, data}, _from, %{connected: true} = state) do
    framed = frame_kiss(data)
    Circuits.UART.write(state.uart, framed)
    {:reply, :ok, %{state | bytes_tx: state.bytes_tx + byte_size(data)}}
  end

  @impl true
  def handle_call({:send_raw, _data}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       device: state.device,
       baud: state.baud,
       connected: state.connected,
       bytes_tx: state.bytes_tx,
       bytes_rx: state.bytes_rx
     }, state}
  end

  @impl true
  def handle_info({:circuits_uart, _uart, data}, state) when is_binary(data) do
    # Process received KISS-framed data
    {:noreply, %{state | bytes_rx: state.bytes_rx + byte_size(data)}}
  end

  @impl true
  def handle_info({:circuits_uart, _uart, {:error, reason}}, state) do
    Logger.error("Serial error: #{inspect(reason)}")
    {:noreply, %{state | connected: false}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ===========================================================================
  # KISS framing
  # ===========================================================================

  defp frame_kiss(data) do
    escaped = escape_kiss(data)
    <<@fend, escaped::binary, @fend>>
  end

  defp escape_kiss(data) do
    data
    |> :binary.replace(<<0xC0>>, <<0xDB, 0xDC>>, [:global])
    |> :binary.replace(<<0xDB>>, <<0xDB, 0xDD>>, [:global])
  end
end
