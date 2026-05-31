defmodule ReticulumLink.Transport.Interface do
  @moduledoc """
  Behaviour for all Reticulum transport interfaces.

  An interface is any physical or logical medium that can carry Reticulum
  packets: TCP sockets, serial ports, LoRa radios, UDP, etc.

  Each interface runs as a supervised process and communicates with the
  Transport layer via message passing.
  """

  alias ReticulumLink.Transport.Packet

  @typedoc "Interface name (atom or string)"
  @type name :: atom() | String.t()

  @typedoc "Interface state"
  @type state :: term()

  @typedoc "Interface options"
  @type opts :: Keyword.t()

  @doc """
  Start the interface process.

  Returns `{:ok, pid}` on success.
  """
  @callback start_link(opts()) :: GenServer.on_start()

  @doc """
  Send a packet out through this interface.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @callback send_packet(name(), Packet.t()) :: :ok | {:error, atom()}

  @doc """
  Get interface status information.

  Returns a map with keys like `:connected`, `:bytes_tx`, `:bytes_rx`, etc.
  """
  @callback status(name()) :: map()

  @doc """
  Close the interface.

  Returns `:ok`.
  """
  @callback close(name()) :: :ok

  @doc """
  Check if the interface is currently connected/ready.
  """
  @callback connected?(name()) :: boolean()
end
