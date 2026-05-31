defmodule ReticulumLink.Transport.Packet do
  @moduledoc """
  Reticulum packet struct with pack/unpack operations.

  A Reticulum packet consists of a header and ciphertext payload.
  The header contains routing information (destination hash, packet type,
  context, hops, etc.) and the payload contains the encrypted or plaintext
  data.

  ## Packet structure

      +--------+----------------------------------+
      | Header |           Ciphertext             |
      | 19-35B |         variable length          |
      +--------+----------------------------------+

  ## Maximum sizes

  | Type      | Max Data Unit |
  |-----------|---------------|
  | Plain     | 464 bytes     |
  | Encrypted | 383 bytes     |

  MTU is 500 bytes total (header + ciphertext).
  """

  alias ReticulumLink.Transport.Header
  alias ReticulumLink.Transport.Destination

  @typedoc "Packet struct"
  @type t :: %__MODULE__{
          header: Header.t(),
          ciphertext: binary(),
          raw: binary() | nil,
          packed: boolean(),
          packet_hash: binary() | nil
        }

  defstruct [
    :header,
    :ciphertext,
    :raw,
    packed: false,
    packet_hash: nil
  ]

  # Maximum payload sizes
  @mtu 500
  @plain_mdu 464
  @encrypted_mdu 383

  @doc """
  Create a new packet from a destination, data, and options.

  ## Parameters

  * `destination` — `%Destination{}` struct
  * `data` — Payload data (binary)
  * `opts` — Keyword options:
    * `:packet_type` — 0=data, 1=announce, 2=link_request, 3=proof (default: 0)
    * `:context` — Context byte (default: 0)
    * `:transport_type` — 0=broadcast, 1=transport, 2=relay, 3=tunnel (default: 0)
    * `:header_type` — 0=HEADER_1, 1=HEADER_2 (default: 0)
    * `:transport_id` — 128-bit transport hash (required for HEADER_2)
    * `:hops` — Hop count (default: 0)
    * `:context_flag` — 0 or 1 (default: 0)

  ## Examples

      iex> {:ok, dest} = Destination.create(:plain, :out, "test", [], nil)
      iex> packet = Packet.new(dest, "hello")
      iex> packet.header.packet_type
      0
  """
  @spec new(Destination.t(), binary(), Keyword.t()) :: t()
  def new(%Destination{} = destination, data, opts \\ []) do
    packet_type = Keyword.get(opts, :packet_type, 0)
    context = Keyword.get(opts, :context, 0)
    transport_type = Keyword.get(opts, :transport_type, 0)
    header_type = Keyword.get(opts, :header_type, 0)
    transport_id = Keyword.get(opts, :transport_id, nil)
    hops = Keyword.get(opts, :hops, 0)
    context_flag = Keyword.get(opts, :context_flag, 0)

    header = %Header{
      header_type: header_type,
      context_flag: context_flag,
      transport_type: transport_type,
      destination_type: Destination.type_to_int(destination.type),
      packet_type: packet_type,
      hops: hops,
      transport_id: transport_id,
      destination_hash: destination.hash,
      context: context
    }

    %__MODULE__{
      header: header,
      ciphertext: data
    }
  end

  @doc """
  Pack a packet into its raw binary form.

  The ciphertext is used as-is (encryption is handled at a higher layer).
  Returns `{:ok, %Packet{}}` with `raw` and `packet_hash` populated.

  Returns `{:error, :mtu_exceeded}` if the total size exceeds 500 bytes.
  """
  @spec pack(t()) :: {:ok, t()} | {:error, atom()}
  def pack(%__MODULE__{header: header, ciphertext: ciphertext} = packet) do
    header_bin = Header.serialize(header)
    raw = header_bin <> ciphertext

    if byte_size(raw) > @mtu do
      {:error, :mtu_exceeded}
    else
      packet_hash = compute_packet_hash(raw)

      {:ok,
       %{
         packet
         | raw: raw,
           packed: true,
           packet_hash: packet_hash
       }}
    end
  end

  @doc """
  Unpack a raw binary packet into a `%Packet{}` struct.

  Returns `{:ok, %Packet{}}` on success, `{:error, reason}` on failure.
  """
  @spec unpack(binary()) :: {:ok, t()} | {:error, atom()}
  def unpack(raw) when is_binary(raw) do
    header_size = Header.size(0)

    if byte_size(raw) < header_size do
      {:error, :packet_too_short}
    else
      <<header_bin::binary-size(header_size), ciphertext::binary>> = raw

      case Header.parse(header_bin) do
        {:ok, header} ->
          packet_hash = compute_packet_hash(raw)

          {:ok,
           %__MODULE__{
             header: header,
             ciphertext: ciphertext,
             raw: raw,
             packed: true,
             packet_hash: packet_hash
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Unpack a packet with HEADER_2 (transport forwarding).

  HEADER_2 has a 35-byte header instead of 19 bytes.
  """
  @spec unpack(binary(), Header.header_type()) :: {:ok, t()} | {:error, atom()}
  def unpack(raw, header_type) when is_binary(raw) do
    header_size = Header.size(header_type)

    if byte_size(raw) < header_size do
      {:error, :packet_too_short}
    else
      <<header_bin::binary-size(header_size), ciphertext::binary>> = raw

      case Header.parse(header_bin) do
        {:ok, header} ->
          packet_hash = compute_packet_hash(raw)

          {:ok,
           %__MODULE__{
             header: header,
             ciphertext: ciphertext,
             raw: raw,
             packed: true,
             packet_hash: packet_hash
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Compute the SHA-256 hash of a raw packet.

  This is used for deduplication and receipt tracking.
  """
  @spec compute_packet_hash(binary()) :: binary()
  def compute_packet_hash(raw) when is_binary(raw) do
    ReticulumLink.Crypto.Hash.sha256(raw)
  end

  @doc """
  Get the maximum data unit for a given destination type.

  Encrypted destinations (SINGLE, GROUP, LINK) have smaller MDU due to
  encryption overhead.
  """
  @spec mdu(Destination.type()) :: non_neg_integer()
  def mdu(:single), do: @encrypted_mdu
  def mdu(:group), do: @encrypted_mdu
  def mdu(:link), do: @encrypted_mdu
  def mdu(:plain), do: @plain_mdu
  def mdu(_), do: @plain_mdu

  @doc """
  Check if a packet's ciphertext should be encrypted based on packet type
  and context.

  Some packet types/contexts bypass encryption (announces, link requests,
  keepalives, etc.).
  """
  @spec encrypt?(Header.t()) :: boolean()
  def encrypt?(%Header{packet_type: 1}), do: false
  def encrypt?(%Header{packet_type: 2}), do: false
  def encrypt?(%Header{context: 0x08}), do: false
  def encrypt?(%Header{context: 0xFA}), do: false
  def encrypt?(%Header{packet_type: 3, context: 0x05}), do: false
  def encrypt?(%Header{packet_type: 3, destination_type: 3}), do: false
  def encrypt?(%Header{context: 0x01}), do: false
  def encrypt?(%Header{}), do: true

  @doc """
  Increment the hop count on a packet's header.
  """
  @spec increment_hops(t()) :: t()
  def increment_hops(%__MODULE__{header: header} = packet) do
    %{packet | header: Header.increment_hops(header)}
  end
end
