defmodule ReticulumLink.Interop.RnsCompatTest do
  @moduledoc """
  Interoperability tests against Python RNS reference implementation.

  These tests verify that Reticulum Link produces wire-compatible output
  with the Python RNS library for key operations:

  - Ed25519 key generation and signing
  - X25519 key derivation from Ed25519
  - SHA-256 hashing
  - Packet header serialization

  Requires Python RNS to be installed: `pip install rns`
  """

  use ExUnit.Case

  alias ReticulumLink.Crypto.{Cipher, Hash, Identity}
  alias ReticulumLink.Transport.Header

  @python_script Path.join(__DIR__, "rns_compat.py")

  setup_all do
    # Ensure Python RNS is available
    case System.cmd("python", ["-c", "import RNS; print(RNS.__version__)"]) do
      {version, 0} ->
        IO.puts("Python RNS version: #{String.trim(version)}")
        :ok

      {_, _} ->
        raise "Python RNS not installed. Run: pip install rns"
    end

    :ok
  end

  describe "Ed25519 compatibility" do
    test "signatures verify against Python RNS" do
      # Generate keys in Elixir
      {:ok, {sk, pk}} = Identity.generate_keypair()
      message = " interoperability test message "

      # Sign in Elixir
      sig = Identity.sign(message, sk)

      # Verify in Python
      python_verify =
        run_python("verify_sig", %{
          "public_key" => Base.encode16(pk, case: :lower),
          "message" => message,
          "signature" => Base.encode16(sig, case: :lower)
        })

      assert python_verify["valid"] == true
    end

    test "Python signatures verify in Elixir" do
      message = "cross-implementation signature test"

      # Generate and sign in Python
      result = run_python("generate_and_sign", %{"message" => message})

      pk = Base.decode16!(result["public_key"], case: :lower)
      sig = Base.decode16!(result["signature"], case: :lower)

      # Verify in Elixir
      assert Identity.verify(message, sig, pk)
    end

    # NOTE: RNS keeps separate X25519 and Ed25519 keys.
    # It does NOT derive X25519 from Ed25519 (unlike our Elixir code).
    # This test verifies our Ed25519-to-X25519 derivation produces valid keys,
    # not that they match RNS (which uses independent key generation).
    test "X25519 key derivation produces valid 32-byte keys" do
      {:ok, {sk, pk}} = Identity.generate_keypair()

      {:ok, xsk} = Identity.to_curve25519(sk, :secret)
      {:ok, xpk} = Identity.to_curve25519(pk, :public)

      assert byte_size(xsk) == 32
      assert byte_size(xpk) == 32

      # Keys should be deterministic
      {:ok, xsk2} = Identity.to_curve25519(sk, :secret)
      {:ok, xpk2} = Identity.to_curve25519(pk, :public)
      assert xsk == xsk2
      assert xpk == xpk2
    end
  end

  describe "Hash compatibility" do
    test "HKDF-SHA-256 matches Python cryptography" do
      ikm = :crypto.strong_rand_bytes(32)
      salt = :crypto.strong_rand_bytes(32)
      info = "reticulum-link-test"
      length = 32

      elixir_okm = Hash.hkdf(ikm, salt, info, length)

      result =
        run_python("hkdf", %{
          "ikm" => Base.encode16(ikm, case: :lower),
          "salt" => Base.encode16(salt, case: :lower),
          "info" => info,
          "length" => length
        })

      python_okm = Base.decode16!(result["okm"], case: :lower)

      assert elixir_okm == python_okm
    end

    test "AES-256-GCM encrypt/decrypt roundtrip" do
      key = :crypto.strong_rand_bytes(32)
      nonce = :crypto.strong_rand_bytes(12)
      plaintext = "secret reticulum message"

      {:ok, encrypted} = Cipher.encrypt(plaintext, key, nonce)
      {:ok, decrypted} = Cipher.decrypt(encrypted, key, nonce)

      assert decrypted == plaintext
    end
  end

  describe "Header compatibility" do
    test "HEADER_1 serialization matches Python RNS" do
      dst_hash = :crypto.strong_rand_bytes(16)

      header = %Header{
        header_type: 0,
        context_flag: 0,
        transport_type: 0,
        destination_type: 0,
        packet_type: 0,
        hops: 5,
        transport_id: nil,
        destination_hash: dst_hash,
        context: 0x01
      }

      elixir_serialized = Header.serialize(header)

      result =
        run_python("serialize_header", %{
          "header_type" => 0,
          "destination_hash" => Base.encode16(dst_hash, case: :lower),
          "packet_type" => 0,
          "hops" => 5,
          "context" => 0x01
        })

      python_serialized = Base.decode16!(result["header"], case: :lower)

      assert elixir_serialized == python_serialized
    end
  end

  # ── Helpers ─────────────────────────────────────────────

  defp run_python(function, args) do
    json_args = Jason.encode!(args)

    {output, exit_code} =
      System.cmd("python", [@python_script, function, json_args])

    if exit_code != 0 do
      raise "Python script failed: #{output}"
    end

    case Jason.decode(output) do
      {:ok, result} -> result
      {:error, _} -> raise "Failed to decode Python output: #{output}"
    end
  end
end
