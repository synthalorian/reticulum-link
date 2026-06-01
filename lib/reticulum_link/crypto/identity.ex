defmodule ReticulumLink.Crypto.Identity do
  @moduledoc """
  Ed25519 identity management: keypair generation, signing, and verification.

  Uses the `ed25519` hex package for Ed25519 operations and derives
  X25519 keys via `to_curve25519/2` for key exchange.

  All keys are raw binaries (32 bytes each for Ed25519).
  """

  @type secret_key() :: binary()
  @type public_key() :: binary()
  @type signature() :: binary()

  @doc """
  Generate an Ed25519 keypair.

  Returns `{:ok, {secret_key, public_key}}` where both are 32-byte binaries.

  ## Examples

      iex> {:ok, {sk, pk}} = ReticulumLink.Crypto.Identity.generate_keypair()
      iex> byte_size(sk)
      32
      iex> byte_size(pk)
      32
  """
  @spec generate_keypair() :: {:ok, {secret_key(), public_key()}} | {:error, atom()}
  def generate_keypair do
    {sk, pk} = Ed25519.generate_key_pair()
    {:ok, {sk, pk}}
  rescue
    e -> {:error, {:generation_failed, Exception.message(e)}}
  end

  @doc """
  Derive the public signing key from a secret key.

  ## Examples

      iex> {:ok, {sk, _pk}} = ReticulumLink.Crypto.Identity.generate_keypair()
      iex> {:ok, {_, pk}} = ReticulumLink.Crypto.Identity.derive_public_key(sk)
      iex> byte_size(pk)
      32
  """
  @spec derive_public_key(secret_key()) :: {:ok, public_key()} | {:error, atom()}
  def derive_public_key(sk) when is_binary(sk) and byte_size(sk) == 32 do
    pk = Ed25519.derive_public_key(sk)
    {:ok, pk}
  rescue
    e -> {:error, {:derivation_failed, Exception.message(e)}}
  end

  @doc """
  Sign a message with a secret key.

  The public key is derived from the secret key if not provided.

  ## Examples

      iex> {:ok, {sk, _pk}} = ReticulumLink.Crypto.Identity.generate_keypair()
      iex> sig = ReticulumLink.Crypto.Identity.sign("hello", sk)
      iex> byte_size(sig)
      64
  """
  @spec sign(binary(), secret_key()) :: signature()
  def sign(message, sk) when is_binary(message) and is_binary(sk) do
    Ed25519.signature(message, sk)
  end

  @doc """
  Verify a signature against a message and public key.

  ## Examples

      iex> {:ok, {sk, pk}} = ReticulumLink.Crypto.Identity.generate_keypair()
      iex> sig = ReticulumLink.Crypto.Identity.sign("hello", sk, pk)
      iex> ReticulumLink.Crypto.Identity.verify("hello", sig, pk)
      true
      iex> ReticulumLink.Crypto.Identity.verify("world", sig, pk)
      false
  """
  @spec verify(binary(), signature(), public_key()) :: boolean()
  def verify(message, sig, pk) when is_binary(message) and is_binary(sig) and is_binary(pk) do
    Ed25519.valid_signature?(sig, message, pk)
  end

  @doc """
  Convert an Ed25519 key to an X25519 (Curve25519) key for encryption.

  Handles both `:secret` and `:public` key conversions.

  See: https://blog.filippo.io/using-ed25519-keys-for-encryption

  ## Examples

      iex> {:ok, {sk, pk}} = ReticulumLink.Crypto.Identity.generate_keypair()
      iex> {:ok, xsk} = ReticulumLink.Crypto.Identity.to_curve25519(sk, :secret)
      iex> {:ok, xpk} = ReticulumLink.Crypto.Identity.to_curve25519(pk, :public)
      iex> byte_size(xsk)
      32
      iex> byte_size(xpk)
      32
  """
  @spec to_curve25519(binary(), :secret | :public) :: {:ok, binary()} | {:error, atom()}
  def to_curve25519(key, type) when is_binary(key) and type in [:secret, :public] do
    xkey = Ed25519.to_curve25519(key, type)
    {:ok, xkey}
  rescue
    e -> {:error, {:conversion_failed, Exception.message(e)}}
  end
end
