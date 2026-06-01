defmodule ReticulumLink.Crypto.Cipher do
  @moduledoc """
  AES-256-GCM encryption with HKDF key derivation.

  Provides authenticated encryption using AES-256 in GCM mode, with
  key derivation via HKDF-SHA-256. Nonces are 96-bit (12 bytes) as
  recommended for GCM.

  ## Key sizes

  AES-256 requires a 256-bit (32-byte) key.

  ## Nonces

  GCM recommends 96-bit (12-byte) nonces for optimal performance.
  Nonces must never be reused with the same key.

  ## Authentication tags

  AES-GCM produces a 128-bit (16-byte) authentication tag by default.

  ## Examples

      iex> key = :crypto.strong_rand_bytes(32)
      iex> nonce = :crypto.strong_rand_bytes(12)
      iex> {:ok, encrypted} = ReticulumLink.Crypto.Cipher.encrypt(plaintext, key, nonce)
      iex> {:ok, plaintext} = ReticulumLink.Crypto.Cipher.decrypt(encrypted, key, nonce)
  """

  alias ReticulumLink.Crypto.Hash

  @doc """
  Encrypt a message using AES-256-GCM.

  ## Parameters

  * `plaintext` — The message to encrypt (binary)
  * `key` — A 256-bit (32-byte) encryption key
  * `nonce` — A 96-bit (12-byte) nonce, unique per key
  * `aad` — Optional additional authenticated data (binary, default: `<<>>`)

  ## Returns

  `{:ok, <<ciphertext, tag::binary()>>}` where the tag is 16 bytes appended
  after the ciphertext. Returns `{:error, reason}` on failure.

  ## Examples

      iex> key = :crypto.strong_rand_bytes(32)
      iex> nonce = :crypto.strong_rand_bytes(12)
      iex> {:ok, encrypted} = ReticulumLink.Crypto.Cipher.encrypt("hello", key, nonce)
      iex> {ciphertext, tag} = :erlang.split_binary(encrypted, byte_size("hello"))
      iex> byte_size(tag)
      16
  """
  @spec encrypt(binary(), binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, atom()}
  def encrypt(plaintext, key, nonce, aad \\ <<>>)
      when is_binary(plaintext) and is_binary(key) and is_binary(nonce) and is_binary(aad) do
    with {:ok, _} <- validate_key(key),
         {:ok, _} <- validate_nonce(nonce) do
      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key,
          nonce,
          plaintext,
          aad,
          true
        )

      {:ok, ciphertext <> tag}
    end
  end

  @doc """
  Decrypt a message encrypted with AES-256-GCM.

  ## Parameters

  * `ciphertext_with_tag` — The ciphertext with the 16-byte GCM tag appended
  * `key` — A 256-bit (32-byte) encryption key
  * `nonce` — The same 96-bit (12-byte) nonce used for encryption
  * `aad` — The same additional authenticated data used for encryption

  ## Returns

  `{:ok, plaintext}` on success. Returns `{:error, :decrypt_failed}` if the
  authentication tag doesn't match (tampered or wrong key). Returns `{:error, reason}`
  on other failures.

  ## Examples

      iex> key = :crypto.strong_rand_bytes(32)
      iex> nonce = :crypto.strong_rand_bytes(12)
      iex> {:ok, encrypted} = ReticulumLink.Crypto.Cipher.encrypt("hello", key, nonce)
      iex> {:ok, "hello"} = ReticulumLink.Crypto.Cipher.decrypt(encrypted, key, nonce)
  """
  @spec decrypt(binary(), binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, atom()}
  def decrypt(ciphertext_with_tag, key, nonce, aad \\ <<>>)
      when is_binary(ciphertext_with_tag) and is_binary(key) and is_binary(nonce) and
             is_binary(aad) do
    with {:ok, _} <- validate_key(key),
         {:ok, _} <- validate_nonce(nonce),
         {:ok, ciphertext, tag} <- split_tag(ciphertext_with_tag) do
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             ciphertext,
             aad,
             tag,
             false
           ) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> {:error, :decrypt_failed}
        _ -> {:error, :decrypt_failed}
      end
    end
  end

  @doc """
  Derive an AES-256 encryption key from a shared secret using HKDF.

  ## Parameters

  * `shared_secret` — The shared secret from key exchange (binary)
  * `info` — Context/info string for key derivation (binary)
  * `length` — Desired key length in bytes (default: 32 for AES-256)

  ## Returns

  `{:ok, key}` where key is `length` bytes.

  ## Examples

      iex> {:ok, secret} = ReticulumLink.Crypto.KeyExchange.derive_shared_secret(
      ...>   :crypto.strong_rand_bytes(32),
      ...>   :crypto.strong_rand_bytes(32)
      ...> )
      iex> {:ok, key} = ReticulumLink.Crypto.Cipher.derive_key(secret, "reticulum-link")
      iex> byte_size(key)
      32
  """
  @spec derive_key(binary(), binary(), non_neg_integer()) :: {:ok, binary()} | {:error, atom()}
  def derive_key(shared_secret, info, length \\ 32)
      when is_binary(shared_secret) and is_binary(info) and
             is_integer(length) and length > 0 do
    key = Hash.hkdf(shared_secret, info, length)
    {:ok, key}
  rescue
    e -> {:error, {:key_derivation_failed, Exception.message(e)}}
  end

  @doc """
  Generate a random encryption key (32 bytes for AES-256).

  ## Examples

      iex> {:ok, key} = ReticulumLink.Crypto.Cipher.generate_key()
      iex> byte_size(key)
      32
  """
  @spec generate_key() :: {:ok, binary()}
  def generate_key do
    {:ok, :crypto.strong_rand_bytes(32)}
  end

  @doc """
  Generate a random nonce (12 bytes for GCM).

  ## Examples

      iex> {:ok, nonce} = ReticulumLink.Crypto.Cipher.generate_nonce()
      iex> byte_size(nonce)
      12
  """
  @spec generate_nonce() :: {:ok, binary()}
  def generate_nonce do
    {:ok, :crypto.strong_rand_bytes(12)}
  end

  @doc """
  Encrypt with auto-generated nonce.

  Convenience function that generates a random nonce for each encryption.
  Useful for one-off encryption where nonce uniqueness is guaranteed.

  ## Returns

  `{:ok, <<nonce, ciphertext, tag::binary()>>}` — the nonce is prepended
  to the ciphertext so the receiver can extract it.

  ## Examples

      iex> key = :crypto.strong_rand_bytes(32)
      iex> {:ok, data} = ReticulumLink.Crypto.Cipher.encrypt_with_nonce("hello", key)
      iex> <<nonce::binary-size(12), ciphertext::binary>> = data
      iex> byte_size(nonce)
      12
  """
  @spec encrypt_with_nonce(binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, atom()}
  def encrypt_with_nonce(plaintext, key, aad \\ <<>>)
      when is_binary(plaintext) and is_binary(key) and is_binary(aad) do
    with {:ok, nonce} <- generate_nonce(),
         {:ok, encrypted} <- encrypt(plaintext, key, nonce, aad) do
      {:ok, nonce <> encrypted}
    end
  end

  @doc """
  Decrypt data encrypted with `encrypt_with_nonce/3`.

  ## Returns

  `{:ok, plaintext}` on success.

  ## Examples

      iex> key = :crypto.strong_rand_bytes(32)
      iex> {:ok, data} = ReticulumLink.Crypto.Cipher.encrypt_with_nonce("hello", key)
      iex> <<nonce::binary-size(12), ciphertext::binary>> = data
      iex> {:ok, "hello"} = ReticulumLink.Crypto.Cipher.decrypt_with_nonce(data, key)
  """
  @spec decrypt_with_nonce(binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, atom()}
  def decrypt_with_nonce(data, key, aad \\ <<>>)
      when is_binary(data) and is_binary(key) and is_binary(aad) do
    with <<nonce::binary-size(12), ciphertext_and_tag::binary>> <- data,
         {:ok, plaintext} <- decrypt(ciphertext_and_tag, key, nonce, aad) do
      {:ok, plaintext}
    else
      _ -> {:error, :invalid_encrypted_data}
    end
  end

  # ===========================================================================
  # Internal helpers
  # ===========================================================================

  defp validate_key(key) when byte_size(key) == 32, do: {:ok, key}
  defp validate_key(key), do: {:error, {:invalid_key_size, byte_size(key)}}

  defp validate_nonce(nonce) when byte_size(nonce) == 12, do: {:ok, nonce}
  defp validate_nonce(nonce), do: {:error, {:invalid_nonce_size, byte_size(nonce)}}

  defp split_tag(data) do
    tag_size = 16

    if byte_size(data) < tag_size do
      {:error, :invalid_tag_size}
    else
      {ciphertext, tag} = :erlang.split_binary(data, byte_size(data) - tag_size)
      {:ok, ciphertext, tag}
    end
  end
end
