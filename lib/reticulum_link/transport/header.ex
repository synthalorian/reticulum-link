defmodule ReticulumLink.Transport.Header do
  @moduledoc """
  Reticulum packet header parser and builder.

  Reticulum uses a compact 2-byte header with flags and hop count,
  followed by a destination hash and context byte.

  ## Header format (HEADER_1)

      +--------+--------+--------------------------------+--------+
      | Flags  |  Hops  |      Destination Hash          | Context|
      | 1 byte | 1 byte |      16 bytes (128-bit)        | 1 byte |
      +--------+--------+--------------------------------+--------+

  ## Flags byte layout

      Bit 7-6: header_type  (0 = HEADER_1, 1 = HEADER_2)
      Bit 5:   context_flag (0 = UNSET, 1 = SET)
      Bit 4:   transport_type (0 = BROADCAST, 1 = TRANSPORT, 2 = RELAY, 3 = TUNNEL)
      Bit 3-2: destination_type (0 = SINGLE, 1 = GROUP, 2 = PLAIN, 3 = LINK)
      Bit 1-0: packet_type (0 = DATA, 1 = ANNOUNCE, 2 = LINKREQUEST, 3 = PROOF)

  ## Header format (HEADER_2 — transport forwarding)

      +--------+--------+---------------+---------------+--------+
      | Flags  |  Hops  |  Transport ID | Dest Hash     | Context|
      | 1 byte | 1 byte |  16 bytes     | 16 bytes      | 1 byte |
      +--------+--------+---------------+---------------+--------+

  Total HEADER_1 size: 19 bytes (2 + 16 + 1)
  Total HEADER_2 size: 35 bytes (2 + 16 + 16 + 1)
  """

  @typedoc "Header type: 0 = HEADER_1, 1 = HEADER_2"
  @type header_type :: 0 | 1

  @typedoc "Transport type: 0 = broadcast, 1 = transport, 2 = relay, 3 = tunnel"
  @type transport_type :: 0 | 1 | 2 | 3

  @typedoc "Destination type: 0 = single, 1 = group, 2 = plain, 3 = link"
  @type destination_type :: 0 | 1 | 2 | 3

  @typedoc "Packet type: 0 = data, 1 = announce, 2 = link_request, 3 = proof"
  @type packet_type :: 0 | 1 | 2 | 3

  @typedoc "Context flag: 0 = unset, 1 = set"
  @type context_flag :: 0 | 1

  @typedoc "Hop count (0-255)"
  @type hops :: non_neg_integer()

  @typedoc "Context byte (0-255)"
  @type context :: non_neg_integer()

  @typedoc "128-bit truncated hash"
  @type hash128 :: <<_::128>>

  @typedoc "Parsed header struct"
  @type t :: %__MODULE__{
          header_type: header_type(),
          context_flag: context_flag(),
          transport_type: transport_type(),
          destination_type: destination_type(),
          packet_type: packet_type(),
          hops: hops(),
          transport_id: hash128() | nil,
          destination_hash: hash128(),
          context: context()
        }

  defstruct [
    :header_type,
    :context_flag,
    :transport_type,
    :destination_type,
    :packet_type,
    :hops,
    :transport_id,
    :destination_hash,
    :context
  ]

  # Constants
  @dst_hash_len 16
  @header_1_size 19
  @header_2_size 35

  # Packet types
  @data 0
  @announce 1
  @link_request 2
  @proof 3

  # Header types
  @header_1 0
  @header_2 1

  # Destination types
  @single 0
  @group 1
  @plain 2
  @link 3

  # Transport types
  @broadcast 0
  @transport 1

  @doc "Packet type: data"
  def packet_type_data, do: @data
  @doc "Packet type: announce"
  def packet_type_announce, do: @announce
  @doc "Packet type: link request"
  def packet_type_link_request, do: @link_request
  @doc "Packet type: proof"
  def packet_type_proof, do: @proof

  @doc "Header type: normal"
  def header_type_1, do: @header_1
  @doc "Header type: transport forwarding"
  def header_type_2, do: @header_2

  @doc "Destination type: single"
  def dest_type_single, do: @single
  @doc "Destination type: group"
  def dest_type_group, do: @group
  @doc "Destination type: plain"
  def dest_type_plain, do: @plain
  @doc "Destination type: link"
  def dest_type_link, do: @link

  @doc "Transport type: broadcast"
  def transport_type_broadcast, do: @broadcast
  @doc "Transport type: transport"
  def transport_type_transport, do: @transport

  @doc """
  Build a flags byte from header components.

  ## Examples

      iex> Header.pack_flags(0, 0, 0, 0, 0)
      0x00

      iex> Header.pack_flags(0, 0, 0, 0, 1)
      0x01
  """
  @spec pack_flags(
          header_type(),
          context_flag(),
          transport_type(),
          destination_type(),
          packet_type()
        ) ::
          byte()
  def pack_flags(header_type, context_flag, transport_type, destination_type, packet_type) do
    Bitwise.bor(
      Bitwise.<<<(header_type, 6),
      Bitwise.bor(
        Bitwise.<<<(context_flag, 5),
        Bitwise.bor(
          Bitwise.<<<(transport_type, 4),
          Bitwise.bor(Bitwise.<<<(destination_type, 2), packet_type)
        )
      )
    )
  end

  @doc """
  Parse a flags byte into its components.

  Returns `{header_type, context_flag, transport_type, destination_type, packet_type}`.
  """
  @spec parse_flags(byte()) ::
          {header_type(), context_flag(), transport_type(), destination_type(), packet_type()}
  def parse_flags(flags) do
    header_type = Bitwise.>>>(Bitwise.band(flags, 0b11000000), 6)
    context_flag = Bitwise.>>>(Bitwise.band(flags, 0b00100000), 5)
    transport_type = Bitwise.>>>(Bitwise.band(flags, 0b00010000), 4)
    destination_type = Bitwise.>>>(Bitwise.band(flags, 0b00001100), 2)
    packet_type = Bitwise.band(flags, 0b00000011)
    {header_type, context_flag, transport_type, destination_type, packet_type}
  end

  @doc """
  Build a HEADER_1 binary from components.

  HEADER_1 format: flags(1) + hops(1) + dst_hash(16) + context(1) = 19 bytes
  """
  @spec pack_header_1(byte(), hops(), hash128(), context()) :: binary()
  def pack_header_1(flags, hops, destination_hash, context) do
    <<flags::8, hops::8, destination_hash::binary-size(@dst_hash_len), context::8>>
  end

  @doc """
  Build a HEADER_2 binary from components.

  HEADER_2 format: flags(1) + hops(1) + transport_id(16) + dst_hash(16) + context(1) = 35 bytes
  """
  @spec pack_header_2(byte(), hops(), hash128(), hash128(), context()) :: binary()
  def pack_header_2(flags, hops, transport_id, destination_hash, context) do
    <<flags::8, hops::8, transport_id::binary-size(@dst_hash_len),
      destination_hash::binary-size(@dst_hash_len), context::8>>
  end

  @doc """
  Parse a raw header binary into a `%Header{}` struct.

  Returns `{:ok, %Header{}}` on success, `{:error, reason}` on failure.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, atom()}
  def parse(raw) when is_binary(raw) do
    cond do
      byte_size(raw) == @header_1_size ->
        <<flags::8, hops::8, destination_hash::binary-size(@dst_hash_len), context::8>> = raw

        {header_type, context_flag, transport_type, destination_type, packet_type} =
          parse_flags(flags)

        {:ok,
         %__MODULE__{
           header_type: header_type,
           context_flag: context_flag,
           transport_type: transport_type,
           destination_type: destination_type,
           packet_type: packet_type,
           hops: hops,
           transport_id: nil,
           destination_hash: destination_hash,
           context: context
         }}

      byte_size(raw) == @header_2_size ->
        <<flags::8, hops::8, transport_id::binary-size(@dst_hash_len),
          destination_hash::binary-size(@dst_hash_len), context::8>> = raw

        {header_type, context_flag, transport_type, destination_type, packet_type} =
          parse_flags(flags)

        {:ok,
         %__MODULE__{
           header_type: header_type,
           context_flag: context_flag,
           transport_type: transport_type,
           destination_type: destination_type,
           packet_type: packet_type,
           hops: hops,
           transport_id: transport_id,
           destination_hash: destination_hash,
           context: context
         }}

      true ->
        {:error, :invalid_header_size}
    end
  end

  @doc """
  Serialize a `%Header{}` struct back to binary.

  Returns the header binary.
  """
  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{} = header) do
    flags =
      pack_flags(
        header.header_type,
        header.context_flag,
        header.transport_type,
        header.destination_type,
        header.packet_type
      )

    case header.header_type do
      @header_2 when not is_nil(header.transport_id) ->
        pack_header_2(
          flags,
          header.hops,
          header.transport_id,
          header.destination_hash,
          header.context
        )

      _ ->
        pack_header_1(flags, header.hops, header.destination_hash, header.context)
    end
  end

  @doc """
  Increment the hop count, capping at 255.
  """
  @spec increment_hops(t()) :: t()
  def increment_hops(%__MODULE__{hops: hops} = header) do
    %{header | hops: min(hops + 1, 255)}
  end

  @doc """
  Get the expected header size for a given header type.
  """
  @spec size(header_type()) :: pos_integer()
  def size(@header_1), do: @header_1_size
  def size(@header_2), do: @header_2_size
  def size(_), do: @header_1_size

  # Context constants for reference
  @doc "Context: generic data packet"
  def context_none, do: 0x00
  @doc "Context: packet is part of a resource"
  def context_resource, do: 0x01
  @doc "Context: resource advertisement"
  def context_resource_adv, do: 0x02
  @doc "Context: resource part request"
  def context_resource_req, do: 0x03
  @doc "Context: resource hashmap update"
  def context_resource_hmu, do: 0x04
  @doc "Context: resource proof"
  def context_resource_prf, do: 0x05
  @doc "Context: resource initiator cancel"
  def context_resource_icl, do: 0x06
  @doc "Context: resource receiver cancel"
  def context_resource_rcl, do: 0x07
  @doc "Context: cache request"
  def context_cache_request, do: 0x08
  @doc "Context: request"
  def context_request, do: 0x09
  @doc "Context: response"
  def context_response, do: 0x0A
  @doc "Context: path response"
  def context_path_response, do: 0x0B
  @doc "Context: command"
  def context_command, do: 0x0C
  @doc "Context: command status"
  def context_command_status, do: 0x0D
  @doc "Context: channel data"
  def context_channel, do: 0x0E
  @doc "Context: keepalive"
  def context_keepalive, do: 0xFA
  @doc "Context: link identify"
  def context_link_identify, do: 0xFB
  @doc "Context: link close"
  def context_link_close, do: 0xFC
  @doc "Context: link proof"
  def context_link_proof, do: 0xFD
  @doc "Context: link request RTT"
  def context_lrrtt, do: 0xFE
  @doc "Context: link request proof"
  def context_lrproof, do: 0xFF
end
