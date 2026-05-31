defmodule ReticulumLink.Crypto.KeyExchange do
  @moduledoc """
  X25519 Diffie-Hellman key exchange.

  Derives shared secrets using the X25519 (Curve25519) algorithm.
  Keys are derived from Ed25519 identities via `ReticulumLink.Crypto.Identity.to_curve25519/2`.

  All keys are raw binaries (32 bytes).
  """

  alias ReticulumLink.Crypto.Identity

  @typedoc """
  X25519 public key (32 bytes)
  """
  @type public_key() :: binary()

  @typedoc """
  X25519 private key (32 bytes)
  """
  @type private_key() :: binary()

  @typedoc """
  Shared secret (32 bytes)
  """
  @type shared_secret() :: binary()

  @doc """
  Derive an X25519 keypair from an Ed25519 keypair.

  Returns `{:ok, {x25519_secret, x25519_public}}`.

  ## Examples

      iex> {:ok, {ed_sk, ed_pk}} = ReticulumLink.Crypto.Identity.generate_keypair()
      iex> {:ok, {xsk, xpk}} = ReticulumLink.Crypto.KeyExchange.derive_keypair(ed_sk, ed_pk)
      iex> byte_size(xsk)
      32
      iex> byte_size(xpk)
      32
  """
  @spec derive_keypair(Identity.secret_key(), Identity.public_key()) ::
          {:ok, {private_key(), public_key()}} | {:error, atom()}
  def derive_keypair(ed_sk, ed_pk)
      when is_binary(ed_sk) and is_binary(ed_pk) and byte_size(ed_sk) == 32 and
             byte_size(ed_pk) == 32 do
    with {:ok, xsk} <- Identity.to_curve25519(ed_sk, :secret),
         {:ok, xpk} <- Identity.to_curve25519(ed_pk, :public) do
      {:ok, {xsk, xpk}}
    end
  end

  @doc """
  Derive an X25519 public key from an Ed25519 public key.

  ## Examples

      iex> {:ok, {sk, pk}} = ReticulumLink.Crypto.Identity.generate_keypair()
      iex> {:ok, xpk} = ReticulumLink.Crypto.KeyExchange.derive_public_key(pk)
      iex> byte_size(xpk)
      32
  """
  @spec derive_public_key(Identity.public_key()) :: {:ok, public_key()} | {:error, atom()}
  def derive_public_key(ed_pk) when is_binary(ed_pk) and byte_size(ed_pk) == 32 do
    Identity.to_curve25519(ed_pk, :public)
  end

  @doc """
  Derive an X25519 private key from an Ed25519 private key.

  ## Examples

      iex> {:ok, {sk, _pk}} = ReticulumLink.Crypto.Identity.generate_keypair()
      iex> {:ok, xsk} = ReticulumLink.Crypto.KeyExchange.derive_private_key(sk)
      iex> byte_size(xsk)
      32
  """
  @spec derive_private_key(Identity.secret_key()) :: {:ok, private_key()} | {:error, atom()}
  def derive_private_key(ed_sk) when is_binary(ed_sk) and byte_size(ed_sk) == 32 do
    Identity.to_curve25519(ed_sk, :secret)
  end

  @doc """
  Derive an X25519 shared secret from a private key and a public key.

  ## Examples

      iex> {:ok, {sk_a, pk_a}} = ReticulumLink.Crypto.Identity.generate_keypair()
      iex> {:ok, {sk_b, pk_b}} = ReticulumLink.Crypto.Identity.generate_keypair()
      iex> {:ok, {xsk_a, xpk_a}} = ReticulumLink.Crypto.KeyExchange.derive_keypair(sk_a, pk_a)
      iex> {:ok, {xsk_b, xpk_b}} = ReticulumLink.Crypto.KeyExchange.derive_keypair(sk_b, pk_b)
      iex> {:ok, secret_ab} = ReticulumLink.Crypto.KeyExchange.derive_shared_secret(xsk_a, xpk_b)
      iex> {:ok, secret_ba} = ReticulumLink.Crypto.KeyExchange.derive_shared_secret(xsk_b, xpk_a)
      iex> secret_ab == secret_ba
      true
  """
  @spec derive_shared_secret(private_key(), public_key()) ::
          {:ok, shared_secret()} | {:error, atom()}
  def derive_shared_secret(priv, pub)
      when is_binary(priv) and is_binary(pub) and byte_size(priv) == 32 and
             byte_size(pub) == 32 do
    try do
      secret = montgomery_ladder(pub, priv)
      {:ok, secret}
    rescue
      e -> {:error, {:shared_secret_failed, Exception.message(e)}}
    end
  end

  @doc """
  Compute the X25519 shared secret directly from Ed25519 keys.

  Convenience function that derives X25519 keys and computes the shared secret.

  ## Examples

      iex> {:ok, {sk_a, pk_a}} = ReticulumLink.Crypto.Identity.generate_keypair()
      iex> {:ok, {sk_b, pk_b}} = ReticulumLink.Crypto.Identity.generate_keypair()
      iex> {:ok, secret_ab} = ReticulumLink.Crypto.KeyExchange.derive_shared_secret_ed25519(sk_a, pk_b)
      iex> {:ok, secret_ba} = ReticulumLink.Crypto.KeyExchange.derive_shared_secret_ed25519(sk_b, pk_a)
      iex> secret_ab == secret_ba
      true
  """
  @spec derive_shared_secret_ed25519(
          Identity.secret_key(),
          Identity.public_key()
        ) ::
          {:ok, shared_secret()} | {:error, atom()}
  def derive_shared_secret_ed25519(ed_priv, ed_pub)
      when is_binary(ed_priv) and is_binary(ed_pub) and
             byte_size(ed_priv) == 32 and byte_size(ed_pub) == 32 do
    with {:ok, xsk} <- derive_private_key(ed_priv),
         {:ok, xpk} <- derive_public_key(ed_pub) do
      derive_shared_secret(xsk, xpk)
    end
  end

  # ===========================================================================
  # Montgomery ladder for Curve25519
  # ===========================================================================

  @p 2 ** 255 - 19

  # Compute (x3, z3) = (x1, z1) + (x2, z2)
  # and (x2, z2) = 2 * (x2, z2) simultaneously
  # using the Montgomery ladder differential addition.
  defp montgomery_ladder(x0, n) when is_binary(x0) and is_binary(n) do
    x0_int = :binary.decode_unsigned(x0, :little)
    n_int = :binary.decode_unsigned(n, :little)

    # Montgomery ladder using Enum.reduce to accumulate state.
    # x2 = 1, z2 = 0 (identity), x3 = x0, z3 = 1 (base point)
    {x2, z2, _x3, _z3, _swap} =
      Enum.reduce(254..0//-1, {1, 0, x0_int, 1, 0}, fn i, {x2, z2, x3, z3, swap} ->
        b = Bitwise.&&&(Bitwise.>>>(n_int, i), 1)
        swap = Bitwise.bxor(swap, b)

        # Swap x2/x3 and z2/z3 if needed
        {x2, x3} = if swap, do: {x3, x2}, else: {x2, x3}
        {z2, z3} = if swap, do: {z3, z2}, else: {z2, z3}

        # Montgomery ladder step
        # (x3, z3) = (x1, z1) + (x2, z2) — differential addition
        # (x2, z2) = 2 * (x2, z2) — doubling

        a = mod(x2 + z2, @p)
        aa = mod(a * a, @p)
        b_val = mod(x2 - z2, @p)
        bb = mod(b_val * b_val, @p)
        ha = mod(aa - bb, @p)

        x3z2 = mod((x3 + z3) * (x2 - z3), @p)

        # New x3, z3 = (x3z2 + ha) / 2, (x3z2 - ha) / 2
        x3_new = mod((x3z2 + ha) * inv(2), @p)
        z3_new = mod((x3z2 - ha) * inv(2), @p)

        # New x2, z2 = (AA + BB), (AA - BB) — after doubling
        x2_new = mod(aa + bb, @p)
        z2_new = mod(aa - bb, @p)

        {x2_new, z2_new, x3_new, z3_new, swap}
      end)

    # Result is x2 / z2 mod p
    result = mod(x2 * inv(z2), @p)
    to_binary_32(result)
  end

  defp bit_at(n, i), do: Bitwise.&&&(Bitwise.>>>(n, i), 1)

  defp mod(x, m) when x >= 0, do: rem(x, m)
  defp mod(x, m), do: rem(m + rem(x, m), m)

  defp inv(x), do: mod_pow(x, @p - 2, @p)

  defp mod_pow(b, e, m) do
    b
    |> :crypto.mod_pow(e, m)
    |> :binary.decode_unsigned()
  end

  defp to_binary_32(value) when is_integer(value) do
    <<value::little-256>>
  end
end
