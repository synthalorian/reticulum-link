defmodule ReticulumLink.Transport.Destination do
  @moduledoc """
  Reticulum destination addressing.

  Destinations are identified by a 128-bit truncated hash computed from:
  1. A name hash (SHA-256 of the expanded name, truncated to 80 bits)
  2. Optionally, an identity hash (for SINGLE destinations)

  ## Destination types

  | Type  | Value | Description                                    |
  |-------|-------|------------------------------------------------|
  | SINGLE| 0     | Unique, identity-bound destination             |
  | GROUP | 1     | Shared-key destination (pre-shared AES key)    |
  | PLAIN | 2     | Unencrypted, anonymous destination             |
  | LINK  | 3     | Ephemeral link destination                     |

  ## Name format

      app_name.aspect1.aspect2...identity_hexhash

  For example: `reticulum.link.example.a1b2c3...`

  The expanded name is hashed with SHA-256, truncated to 80 bits.
  For SINGLE destinations, the identity's public key hash (128-bit)
  is appended before the final hash.
  """

  alias ReticulumLink.Crypto.Hash

  @typedoc "Destination type"
  @type type :: :single | :group | :plain | :link

  @typedoc "128-bit destination hash"
  @type hash :: <<_::128>>

  @typedoc "80-bit name hash"
  @type name_hash :: <<_::80>>

  @typedoc "Direction: :in or :out"
  @type direction :: :in | :out

  @typedoc "Destination struct"
  @type t :: %__MODULE__{
          hash: hash(),
          name_hash: name_hash(),
          type: type(),
          direction: direction(),
          app_name: String.t(),
          aspects: [String.t()],
          identity_hash: hash() | nil
        }

  defstruct [
    :hash,
    :name_hash,
    :type,
    :direction,
    :app_name,
    :aspects,
    :identity_hash
  ]

  # Constants
  @name_hash_length 10
  @dst_hash_length 16
  @app_name_max_len 255
  @aspect_max_len 255

  @doc """
  Create a new destination.

  ## Parameters

  * `type` — `:single`, `:group`, `:plain`, or `:link`
  * `direction` — `:in` (receiving) or `:out` (sending)
  * `app_name` — Application name (no dots allowed)
  * `aspects` — List of aspect strings (no dots allowed)
  * `identity_hash` — 128-bit identity hash (required for `:single`, optional for others)

  ## Examples

      iex> {:ok, identity} = ReticulumLink.Crypto.Identity.generate_keypair()
      iex> {_sk, pk} = identity
      iex> identity_hash = ReticulumLink.Crypto.Hash.sha256(pk) |> binary_part(0, 16)
      iex> {:ok, dest} = Destination.create(:single, :in, "test", ["app"], identity_hash)
      iex> byte_size(dest.hash)
      16
  """
  @spec create(type(), direction(), String.t(), [String.t()], hash() | nil) ::
          {:ok, t()} | {:error, atom()}
  def create(type, direction, app_name, aspects \\ [], identity_hash \\ nil)
      when type in [:single, :group, :plain, :link] and
             direction in [:in, :out] do
    with :ok <- validate_name(app_name),
         :ok <- validate_aspects(aspects),
         :ok <- validate_identity_hash(type, identity_hash) do
      expanded_name = expand_name(app_name, aspects, identity_hash)
      name_hash = compute_name_hash(expanded_name)
      dst_hash = compute_destination_hash(name_hash, identity_hash)

      {:ok,
       %__MODULE__{
         hash: dst_hash,
         name_hash: name_hash,
         type: type,
         direction: direction,
         app_name: app_name,
         aspects: aspects,
         identity_hash: identity_hash
       }}
    end
  end

  @doc """
  Compute the destination hash from name hash and optional identity hash.

  This is the core addressing function used by Reticulum.
  """
  @spec compute_destination_hash(name_hash(), hash() | nil) :: hash()
  def compute_destination_hash(name_hash, nil) do
    Hash.sha256(name_hash) |> binary_part(0, @dst_hash_length)
  end

  def compute_destination_hash(name_hash, identity_hash)
      when is_binary(identity_hash) and byte_size(identity_hash) == @dst_hash_length do
    Hash.sha256(name_hash <> identity_hash) |> binary_part(0, @dst_hash_length)
  end

  @doc """
  Compute the 80-bit name hash from an expanded name string.
  """
  @spec compute_name_hash(String.t()) :: name_hash()
  def compute_name_hash(expanded_name) when is_binary(expanded_name) do
    Hash.sha256(expanded_name) |> binary_part(0, @name_hash_length)
  end

  @doc """
  Expand a destination name into its full string form.

  ## Examples

      iex> Destination.expand_name("test", ["app"], nil)
      "test.app"

      iex> Destination.expand_name("test", ["app"], <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>)
      "test.app.0102030405060708090a0b0c0d0e0f10"
  """
  @spec expand_name(String.t(), [String.t()], hash() | nil) :: String.t()
  def expand_name(app_name, aspects, identity_hash) do
    base = Enum.join([app_name | aspects], ".")

    case identity_hash do
      nil ->
        base

      hash when is_binary(hash) and byte_size(hash) == @dst_hash_length ->
        base <> "." <> Base.encode16(hash, case: :lower)
    end
  end

  @doc """
  Convert a destination type atom to its integer value.
  """
  @spec type_to_int(type()) :: non_neg_integer()
  def type_to_int(:single), do: 0
  def type_to_int(:group), do: 1
  def type_to_int(:plain), do: 2
  def type_to_int(:link), do: 3

  @doc """
  Convert an integer destination type to its atom.
  """
  @spec int_to_type(non_neg_integer()) :: type()
  def int_to_type(0), do: :single
  def int_to_type(1), do: :group
  def int_to_type(2), do: :plain
  def int_to_type(3), do: :link
  def int_to_type(_), do: :single

  @doc """
  Get the hex string representation of a destination hash.
  """
  @spec hash_to_hex(hash()) :: String.t()
  def hash_to_hex(hash) when is_binary(hash) and byte_size(hash) == @dst_hash_length do
    Base.encode16(hash, case: :lower)
  end

  @doc """
  Parse a hex string into a destination hash binary.
  """
  @spec hex_to_hash(String.t()) :: {:ok, hash()} | {:error, atom()}
  def hex_to_hash(hex) when is_binary(hex) and byte_size(hex) == 32 do
    {:ok, Base.decode16!(hex, case: :lower)}
  rescue
    _ -> {:error, :invalid_hash_hex}
  end

  def hex_to_hash(_), do: {:error, :invalid_hash_length}

  # ===========================================================================
  # Validation
  # ===========================================================================

  defp validate_name(name) when is_binary(name) do
    cond do
      String.contains?(name, ".") -> {:error, :name_contains_dots}
      String.length(name) > @app_name_max_len -> {:error, :name_too_long}
      String.length(name) == 0 -> {:error, :name_empty}
      true -> :ok
    end
  end

  defp validate_aspects(aspects) when is_list(aspects) do
    Enum.reduce_while(aspects, :ok, fn aspect, _ ->
      cond do
        not is_binary(aspect) -> {:halt, {:error, :aspect_not_string}}
        String.contains?(aspect, ".") -> {:halt, {:error, :aspect_contains_dots}}
        String.length(aspect) > @aspect_max_len -> {:halt, {:error, :aspect_too_long}}
        true -> {:cont, :ok}
      end
    end)
  end

  defp validate_identity_hash(:single, nil) do
    {:error, :single_requires_identity}
  end

  defp validate_identity_hash(:single, hash)
       when is_binary(hash) and byte_size(hash) == @dst_hash_length do
    :ok
  end

  defp validate_identity_hash(:single, _) do
    {:error, :invalid_identity_hash}
  end

  defp validate_identity_hash(_, nil), do: :ok

  defp validate_identity_hash(_, hash)
       when is_binary(hash) and byte_size(hash) == @dst_hash_length, do: :ok

  defp validate_identity_hash(_, _), do: {:error, :invalid_identity_hash}
end
