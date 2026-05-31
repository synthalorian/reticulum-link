defmodule ReticulumLink.Lxmf.Message do
  @moduledoc """
  LXMF message struct with pack/unpack serialization.

  Matches Python RNS LXMessage wire format:
  - destination_hash (16 bytes)
  - source_hash (16 bytes)
  - signature (64 bytes)
  - msgpack payload: [timestamp, title_bytes, content_bytes, fields]

  Message hash = SHA-256(destination_hash || source_hash || msgpack(payload))
  """

  alias ReticulumLink.Crypto.Hash

  @destination_length 16
  @signature_length 64
  @timestamp_size 8
  @struct_overhead 8

  # Delivery methods
  @method_unknown 0
  @method_opportunistic 1
  @method_direct 2
  @method_propagated 3

  # Representations
  @representation_unknown 0
  @representation_packet 1
  @representation_resource 2

  # States
  @state_generating 0
  @state_outbound 1
  @state_sending 2
  @state_sent 4
  @state_delivered 8
  @state_failed 255

  # Unverified reasons
  @reason_none 0
  @reason_source_unknown 1
  @reason_signature_invalid 2

  defstruct [
    :destination_hash,
    :source_hash,
    :title,
    :content,
    :fields,
    :timestamp,
    :signature,
    :hash,
    :stamp,
    :state,
    :method,
    :representation,
    :desired_method,
    :incoming,
    :signature_validated,
    :unverified_reason,
    :delivery_attempts,
    :packed,
    :packed_size
  ]

  @type t :: %__MODULE__{
          destination_hash: binary(),
          source_hash: binary(),
          title: binary(),
          content: binary(),
          fields: map() | nil,
          timestamp: float() | nil,
          signature: binary() | nil,
          hash: binary() | nil,
          stamp: binary() | nil,
          state: non_neg_integer(),
          method: non_neg_integer(),
          representation: non_neg_integer(),
          desired_method: non_neg_integer() | nil,
          incoming: boolean(),
          signature_validated: boolean(),
          unverified_reason: non_neg_integer(),
          delivery_attempts: non_neg_integer(),
          packed: binary() | nil,
          packed_size: non_neg_integer() | nil
        }

  @doc """
  Create a new outgoing LXMF message.
  """
  @spec new(binary(), binary(), String.t(), String.t(), map() | nil, non_neg_integer() | nil) ::
          t()
  def new(
        destination_hash,
        source_hash,
        content \\ "",
        title \\ "",
        fields \\ nil,
        desired_method \\ nil
      ) do
    %__MODULE__{
      destination_hash: destination_hash,
      source_hash: source_hash,
      title: :unicode.characters_to_binary(title),
      content: :unicode.characters_to_binary(content),
      fields: fields,
      timestamp: nil,
      signature: nil,
      hash: nil,
      stamp: nil,
      state: @state_generating,
      method: @method_unknown,
      representation: @representation_unknown,
      desired_method: desired_method || @method_direct,
      incoming: false,
      signature_validated: false,
      unverified_reason: @reason_none,
      delivery_attempts: 0,
      packed: nil,
      packed_size: nil
    }
  end

  @doc """
  Pack a message into its wire format.
  Returns {:ok, packed_binary} or {:error, reason}.
  """
  @spec pack(t()) :: {:ok, t()} | {:error, atom()}
  def pack(%__MODULE__{packed: packed} = msg) when is_binary(packed) do
    {:ok, msg}
  end

  def pack(%__MODULE__{} = msg) do
    timestamp = msg.timestamp || System.system_time(:second) / 1.0

    payload = [timestamp, msg.title, msg.content, msg.fields || %{}]
    packed_payload = :erlang.term_to_binary(payload)

    hashed_part = msg.destination_hash <> msg.source_hash <> packed_payload
    message_hash = Hash.sha256(hashed_part)

    signature = msg.signature || <<0::size(@signature_length * 8)>>

    packed =
      msg.destination_hash <>
        msg.source_hash <>
        signature <>
        packed_payload

    packed_size = byte_size(packed)
    content_size = byte_size(packed_payload) - @timestamp_size - @struct_overhead

    {method, representation} = resolve_method(msg.desired_method, content_size)

    {:ok,
     %{
       msg
       | timestamp: timestamp,
         hash: message_hash,
         signature: signature,
         packed: packed,
         packed_size: packed_size,
         method: method,
         representation: representation,
         state: @state_outbound
     }}
  end

  defp resolve_method(@method_opportunistic, content_size) do
    if content_size > 295 do
      {@method_direct, @representation_resource}
    else
      {@method_opportunistic, @representation_packet}
    end
  end

  defp resolve_method(@method_direct, content_size) do
    if content_size <= 319 do
      {@method_direct, @representation_packet}
    else
      {@method_direct, @representation_resource}
    end
  end

  defp resolve_method(@method_propagated, _content_size) do
    {@method_propagated, @representation_packet}
  end

  defp resolve_method(_, _content_size) do
    {@method_direct, @representation_packet}
  end

  @doc """
  Unpack a message from its wire format.
  Returns {:ok, message} or {:error, reason}.
  """
  @spec unpack(binary()) :: {:ok, t()} | {:error, atom()}
  def unpack(lxmf_bytes) when is_binary(lxmf_bytes) do
    min_size = @destination_length * 2 + @signature_length + @timestamp_size + @struct_overhead

    if byte_size(lxmf_bytes) < min_size do
      {:error, :invalid_size}
    else
      <<destination_hash::binary-size(@destination_length),
        source_hash::binary-size(@destination_length), signature::binary-size(@signature_length),
        packed_payload::binary>> = lxmf_bytes

      try do
        payload = :erlang.binary_to_term(packed_payload)
        [timestamp, title_bytes, content_bytes, fields] = payload

        hashed_part = destination_hash <> source_hash <> packed_payload
        message_hash = Hash.sha256(hashed_part)

        msg = %__MODULE__{
          destination_hash: destination_hash,
          source_hash: source_hash,
          title: title_bytes,
          content: content_bytes,
          fields: fields,
          timestamp: timestamp,
          signature: signature,
          hash: message_hash,
          stamp: nil,
          state: @state_outbound,
          method: @method_unknown,
          representation: @representation_unknown,
          desired_method: nil,
          incoming: true,
          signature_validated: false,
          unverified_reason: @reason_source_unknown,
          delivery_attempts: 0,
          packed: lxmf_bytes,
          packed_size: byte_size(lxmf_bytes)
        }

        {:ok, msg}
      rescue
        _ -> {:error, :invalid_payload}
      end
    end
  end

  @doc """
  Set the signature on a message (called after signing).
  """
  @spec set_signature(t(), binary()) :: t()
  def set_signature(%__MODULE__{} = msg, signature)
      when byte_size(signature) == @signature_length do
    %{msg | signature: signature}
  end

  @doc """
  Validate that the message hash matches recomputed hash.
  """
  @spec validate_hash(t()) :: boolean()
  def validate_hash(%__MODULE__{packed: nil}), do: false

  def validate_hash(%__MODULE__{} = msg) do
    <<_::binary-size(@destination_length * 2), _signature::binary-size(@signature_length),
      packed_payload::binary>> = msg.packed

    hashed_part = msg.destination_hash <> msg.source_hash <> packed_payload
    computed = Hash.sha256(hashed_part)
    computed == msg.hash
  end

  @doc """
  Get the message ID (same as hash).
  """
  @spec message_id(t()) :: binary() | nil
  def message_id(%__MODULE__{hash: hash}), do: hash

  @doc """
  Get title as UTF-8 string.
  """
  @spec title_string(t()) :: String.t() | nil
  def title_string(%__MODULE__{title: title}) do
    case String.valid?(title) do
      true -> title
      false -> nil
    end
  end

  @doc """
  Get content as UTF-8 string.
  """
  @spec content_string(t()) :: String.t() | nil
  def content_string(%__MODULE__{content: content}) do
    case String.valid?(content) do
      true -> content
      false -> nil
    end
  end

  # State helpers
  def state_generating, do: @state_generating
  def state_outbound, do: @state_outbound
  def state_sending, do: @state_sending
  def state_sent, do: @state_sent
  def state_delivered, do: @state_delivered
  def state_failed, do: @state_failed

  # Method helpers
  def method_unknown, do: @method_unknown
  def method_opportunistic, do: @method_opportunistic
  def method_direct, do: @method_direct
  def method_propagated, do: @method_propagated

  # Representation helpers
  def representation_unknown, do: @representation_unknown
  def representation_packet, do: @representation_packet
  def representation_resource, do: @representation_resource

  # Reason helpers
  def reason_none, do: @reason_none
  def reason_source_unknown, do: @reason_source_unknown
  def reason_signature_invalid, do: @reason_signature_invalid
end
