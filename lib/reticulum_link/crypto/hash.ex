defmodule ReticulumLink.Crypto.Hash do
  @moduledoc """
  Cryptographic hash functions: SHA-256, SHA-512, HMAC, and HKDF.

  These are the building blocks for all other crypto operations in
  Reticulum Link. All functions accept and return raw binaries.
  """

  @doc """
  Compute SHA-256 hash of data.

  ## Examples

      iex> ReticulumLink.Crypto.Hash.sha256(<<0>>)
      <<0xba, 0x78, 0x16, ...>>
  """
  @spec sha256(binary()) :: binary()
  def sha256(data) when is_binary(data) do
    :crypto.hash(:sha256, data)
  end

  @doc """
  Compute SHA-512 hash of data.
  """
  @spec sha512(binary()) :: binary()
  def sha512(data) when is_binary(data) do
    :crypto.hash(:sha512, data)
  end

  @doc """
  Compute HMAC-SHA-256 of data with key.

  ## Examples

      iex> key = :crypto.strong_rand_bytes(32)
      iex> hmac = ReticulumLink.Crypto.Hash.hmac_sha256(<<1, 2, 3>>, key)
      iex> byte_size(hmac)
      32
  """
  @spec hmac_sha256(binary(), binary()) :: binary()
  def hmac_sha256(data, key) when is_binary(data) and is_binary(key) do
    :crypto.mac(:hmac, :sha256, key, data)
  end

  @doc """
  Compute HMAC-SHA-512 of data with key.
  """
  @spec hmac_sha512(binary(), binary()) :: binary()
  def hmac_sha512(data, key) when is_binary(data) and is_binary(key) do
    :crypto.mac(:hmac, :sha512, key, data)
  end

  @doc """
  HKDF extract step: derives a pseudorandom key (PRK) from an
  input keying material (IKM) and optional salt.

  If salt is nil or empty, a zero-filled hash of the appropriate
  length is used (per RFC 5869 §2.2).
  """
  @spec hkdf_extract(binary(), binary()) :: binary()
  def hkdf_extract(salt, ikm) when is_binary(salt) and is_binary(ikm) do
    # SHA-256 output size in bytes
    hash_len = 32

    effective_salt =
      if byte_size(salt) == 0, do: :binary.copy(<<0>>, hash_len), else: salt

    :crypto.mac(:hmac, :sha256, effective_salt, ikm)
  end

  @doc """
  HKDF extract step with nil-safe salt (defaults to zero-filled hash).
  """
  @spec hkdf_extract(binary()) :: binary()
  def hkdf_extract(ikm) when is_binary(ikm) do
    hkdf_extract(<<>>, ikm)
  end

  @doc """
  HKDF expand step: expands a PRK into an Okm of the desired length.

  ## Examples

      iex> prk = :crypto.strong_rand_bytes(32)
      iex> okm = ReticulumLink.Crypto.Hash.hkdf_expand(prk, <<"info">>, 64)
      iex> byte_size(okm)
      64
  """
  @spec hkdf_expand(binary(), binary(), non_neg_integer()) :: binary()
  def hkdf_expand(prk, info, length)
      when is_binary(prk) and is_binary(info) and is_integer(length) and length >= 0 do
    # SHA-256 output size in bytes
    hash_len = 32
    max_length = hash_len * 255

    if length > max_length do
      raise ArgumentError,
            "HKDF output length #{length} exceeds maximum #{max_length} (255 * hash_len)"
    end

    do_hkdf_expand(prk, info, length, <<>>, 0)
  end

  defp do_hkdf_expand(_prk, _info, length, t, _n) when byte_size(t) >= length do
    :binary.part(t, 0, length)
  end

  defp do_hkdf_expand(prk, info, length, t, n) do
    t_next = :crypto.mac(:hmac, :sha256, prk, t <> info <> <<n + 1>>)
    do_hkdf_expand(prk, info, length, t <> t_next, n + 1)
  end

  @doc """
  Full HKDF (extract-and-expand) per RFC 5869.

  ## Examples

      iex> ikm = :crypto.strong_rand_bytes(32)
      iex> okm = ReticulumLink.Crypto.Hash.hkdf(ikm, <<"salt">>, <<"info">>, 32)
      iex> byte_size(okm)
      32
  """
  @spec hkdf(binary(), binary(), binary(), non_neg_integer()) :: binary()
  def hkdf(ikm, salt, info, length)
      when is_binary(ikm) and is_binary(salt) and is_binary(info) and
             is_integer(length) and length >= 0 do
    prk = hkdf_extract(salt, ikm)
    hkdf_expand(prk, info, length)
  end

  @doc """
  HKDF with nil-safe salt (defaults to zero-filled hash).
  """
  @spec hkdf(binary(), binary(), non_neg_integer()) :: binary()
  def hkdf(ikm, info, length)
      when is_binary(ikm) and is_binary(info) and is_integer(length) and
             length >= 0 do
    prk = hkdf_extract(ikm)
    hkdf_expand(prk, info, length)
  end

  @doc """
  Compute a keyed hash (HMAC) and encode the result as a
  lowercase hex string for debugging/logging.
  """
  @spec hmac_sha256_hex(binary(), binary()) :: String.t()
  def hmac_sha256_hex(data, key) do
    data
    |> hmac_sha256(key)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Compute a hash and encode the result as a lowercase hex string.
  """
  @spec sha256_hex(binary()) :: String.t()
  def sha256_hex(data) do
    data
    |> sha256()
    |> Base.encode16(case: :lower)
  end
end
