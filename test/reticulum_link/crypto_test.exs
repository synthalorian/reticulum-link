defmodule ReticulumLink.CryptoTest do
  use ExUnit.Case, async: true

  alias ReticulumLink.Crypto.{Cipher, Hash, Identity, IdentityManager, KeyExchange}

  describe "Hash" do
    test "sha256 returns 32-byte hash" do
      result = Hash.sha256("test")
      assert byte_size(result) == 32
    end

    test "sha512 returns 64-byte hash" do
      result = Hash.sha512("test")
      assert byte_size(result) == 64
    end

    test "sha256 is deterministic" do
      assert Hash.sha256("hello") == Hash.sha256("hello")
      assert Hash.sha256("hello") != Hash.sha256("world")
    end

    test "hmac_sha256 returns 32-byte tag" do
      key = :crypto.strong_rand_bytes(32)
      hmac = Hash.hmac_sha256("message", key)
      assert byte_size(hmac) == 32
    end

    test "hkdf extract and expand" do
      ikm = :crypto.strong_rand_bytes(32)
      salt = :crypto.strong_rand_bytes(16)
      info = "custom-info"

      okm = Hash.hkdf(ikm, salt, info, 32)
      assert byte_size(okm) == 32

      # Different info should produce different output
      okm2 = Hash.hkdf(ikm, salt, "other-info", 32)
      assert okm != okm2
    end

    test "sha256_hex returns lowercase hex string" do
      hex = Hash.sha256_hex("test")
      assert String.length(hex) == 64
      assert hex == String.downcase(hex)
      # Verify it decodes back to binary
      assert Hash.sha256("test") == Base.decode16!(hex, case: :lower)
    end
  end

  describe "Identity" do
    test "generate_keypair returns 32-byte keys" do
      {:ok, {sk, pk}} = Identity.generate_keypair()
      assert byte_size(sk) == 32
      assert byte_size(pk) == 32
    end

    test "derived public key is deterministic from secret" do
      {:ok, {sk, pk1}} = Identity.generate_keypair()
      {:ok, pk2} = Identity.derive_public_key(sk)
      assert pk1 == pk2
    end

    test "sign and verify roundtrip" do
      {:ok, {sk, pk}} = Identity.generate_keypair()
      message = "hello world"

      sig = Identity.sign(message, sk)
      # 32 for r + 32 for s
      assert byte_size(sig) == 64

      assert Identity.verify(message, sig, pk)
    end

    test "tampered message fails verification" do
      {:ok, {sk, pk}} = Identity.generate_keypair()

      sig = Identity.sign("original", sk)
      refute Identity.verify("tampered", sig, pk)
    end

    test "to_curve25519 produces 32-byte keys" do
      {:ok, {sk, pk}} = Identity.generate_keypair()

      {:ok, xsk} = Identity.to_curve25519(sk, :secret)
      {:ok, xpk} = Identity.to_curve25519(pk, :public)

      assert byte_size(xsk) == 32
      assert byte_size(xpk) == 32
    end

    test "curve25519 keys are derived correctly" do
      {:ok, {sk, pk}} = Identity.generate_keypair()

      {:ok, _xsk} = Identity.to_curve25519(sk, :secret)
      {:ok, xpk} = Identity.to_curve25519(pk, :public)

      # The public x25519 key should be deterministic
      {:ok, xpk2} = Identity.to_curve25519(pk, :public)
      assert xpk == xpk2
    end
  end

  describe "KeyExchange" do
    test "derive_keypair from Ed25519 keys" do
      {:ok, {ed_sk, ed_pk}} = Identity.generate_keypair()
      {:ok, {xsk, xpk}} = KeyExchange.derive_keypair(ed_sk, ed_pk)

      assert byte_size(xsk) == 32
      assert byte_size(xpk) == 32
    end

    test "shared secret is symmetric" do
      {:ok, {sk_a, pk_a}} = Identity.generate_keypair()
      {:ok, {sk_b, pk_b}} = Identity.generate_keypair()

      {:ok, {xsk_a, xpk_a}} = KeyExchange.derive_keypair(sk_a, pk_a)
      {:ok, {xsk_b, xpk_b}} = KeyExchange.derive_keypair(sk_b, pk_b)

      {:ok, secret_ab} = KeyExchange.derive_shared_secret(xsk_a, xpk_b)
      {:ok, secret_ba} = KeyExchange.derive_shared_secret(xsk_b, xpk_a)

      assert secret_ab == secret_ba
    end

    test "derive_shared_secret_ed25519 convenience" do
      {:ok, {sk_a, pk_a}} = Identity.generate_keypair()
      {:ok, {sk_b, pk_b}} = Identity.generate_keypair()

      {:ok, secret_ab} = KeyExchange.derive_shared_secret_ed25519(sk_a, pk_b)
      {:ok, secret_ba} = KeyExchange.derive_shared_secret_ed25519(sk_b, pk_a)

      assert secret_ab == secret_ba
    end

    test "derived shared secret is 32 bytes" do
      {:ok, {sk_a, pk_a}} = Identity.generate_keypair()
      {:ok, {sk_b, pk_b}} = Identity.generate_keypair()

      {:ok, {xsk_a, _xpk_a}} = KeyExchange.derive_keypair(sk_a, pk_a)
      {:ok, {xsk_b, _xpk_b}} = KeyExchange.derive_keypair(sk_b, pk_b)

      {:ok, secret} = KeyExchange.derive_shared_secret(xsk_a, xsk_b)
      assert byte_size(secret) == 32
    end
  end

  describe "Cipher" do
    test "encrypt and decrypt roundtrip" do
      key = :crypto.strong_rand_bytes(32)
      nonce = :crypto.strong_rand_bytes(12)
      plaintext = "hello, world!"

      {:ok, encrypted} = Cipher.encrypt(plaintext, key, nonce)
      {:ok, decrypted} = Cipher.decrypt(encrypted, key, nonce)

      assert decrypted == plaintext
    end

    test "encrypted data contains ciphertext + tag" do
      key = :crypto.strong_rand_bytes(32)
      nonce = :crypto.strong_rand_bytes(12)
      plaintext = "test"

      {:ok, encrypted} = Cipher.encrypt(plaintext, key, nonce)
      # ciphertext (4 bytes) + tag (16 bytes) = 20 bytes
      assert byte_size(encrypted) == 20
    end

    test "tampered ciphertext fails decryption" do
      key = :crypto.strong_rand_bytes(32)
      nonce = :crypto.strong_rand_bytes(12)
      plaintext = "secret"

      {:ok, encrypted} = Cipher.encrypt(plaintext, key, nonce)
      # Tamper with the last byte (tag)
      <<ciphertext_part::binary-size(byte_size(encrypted) - 1), _last>> = encrypted
      tampered = <<ciphertext_part::binary, 1>>

      assert {:error, :decrypt_failed} == Cipher.decrypt(tampered, key, nonce)
    end

    test "wrong key fails decryption" do
      key1 = :crypto.strong_rand_bytes(32)
      key2 = :crypto.strong_rand_bytes(32)
      nonce = :crypto.strong_rand_bytes(12)
      plaintext = "secret"

      {:ok, encrypted} = Cipher.encrypt(plaintext, key1, nonce)
      assert {:error, :decrypt_failed} == Cipher.decrypt(encrypted, key2, nonce)
    end

    test "derive_key from shared secret" do
      shared_secret = :crypto.strong_rand_bytes(32)

      {:ok, key1} = Cipher.derive_key(shared_secret, "info-1")
      {:ok, key2} = Cipher.derive_key(shared_secret, "info-2")

      assert byte_size(key1) == 32
      assert byte_size(key2) == 32
      assert key1 != key2
    end

    test "generate_key returns 32 bytes" do
      {:ok, key} = Cipher.generate_key()
      assert byte_size(key) == 32
    end

    test "generate_nonce returns 12 bytes" do
      {:ok, nonce} = Cipher.generate_nonce()
      assert byte_size(nonce) == 12
    end

    test "encrypt_with_nonce / decrypt_with_nonce roundtrip" do
      key = :crypto.strong_rand_bytes(32)
      plaintext = "encrypted with random nonce"

      {:ok, data} = Cipher.encrypt_with_nonce(plaintext, key)
      {:ok, decrypted} = Cipher.decrypt_with_nonce(data, key)

      assert decrypted == plaintext

      # Extract nonce and ciphertext
      <<_nonce::binary-size(12), ciphertext_and_tag::binary>> = data
      assert byte_size(ciphertext_and_tag) == byte_size(plaintext) + 16
    end

    test "aes_gcm encrypt with aad" do
      key = :crypto.strong_rand_bytes(32)
      nonce = :crypto.strong_rand_bytes(12)
      plaintext = "test"
      aad = "additional data"

      {:ok, encrypted} = Cipher.encrypt(plaintext, key, nonce, aad)
      {:ok, decrypted} = Cipher.decrypt(encrypted, key, nonce, aad)
      assert decrypted == plaintext

      # Wrong AAD should fail
      assert {:error, :decrypt_failed} ==
               Cipher.decrypt(encrypted, key, nonce, "wrong-aad")
    end
  end

  describe "IdentityManager" do
    test "starts and loads identity" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "reticulum_link_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      # Create a key file
      key_file = Path.join(tmp_dir, "identity.key")
      {:ok, {sk, pk}} = Identity.generate_keypair()
      {:ok, {xsk, xpk}} = KeyExchange.derive_keypair(sk, pk)

      # Write JSON manually
      json =
        Jason.encode!(%{
          "ed25519_secret" => Base.encode16(sk, case: :lower),
          "ed25519_public" => Base.encode16(pk, case: :lower),
          "x25519_secret" => Base.encode16(xsk, case: :lower),
          "x25519_public" => Base.encode16(xpk, case: :lower)
        })

      File.write!(key_file, json)

      # Start the manager
      opts = [data_dir: tmp_dir, key_file: "identity.key", name: :test_identity_manager_1]
      {:ok, pid} = IdentityManager.start_link(opts)

      # Should be able to get identity
      assert {:ok, identity} = IdentityManager.identity()
      assert byte_size(identity.ed25519_secret) == 32
      assert byte_size(identity.ed25519_public) == 32
      assert byte_size(identity.x25519_secret) == 32
      assert byte_size(identity.x25519_public) == 32

      # Public key hex
      assert {:ok, pk_hex} = IdentityManager.public_key_hex()
      assert String.length(pk_hex) == 64

      # X25519 public key hex
      assert {:ok, xpk_hex} = IdentityManager.x25519_public_key_hex()
      assert String.length(xpk_hex) == 64

      # Stop the manager
      :ok = GenServer.stop(pid)
    end

    test "auto-generates identity if no key file exists" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "reticulum_link_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      opts = [
        data_dir: tmp_dir,
        key_file: "identity.key",
        auto_generate: true,
        name: :test_identity_manager_2
      ]

      {:ok, pid} = IdentityManager.start_link(opts)

      assert {:ok, identity} = IdentityManager.identity()
      assert byte_size(identity.ed25519_secret) == 32

      # Key file should have been created
      key_file = Path.join(tmp_dir, "identity.key")
      assert File.exists?(key_file)

      :ok = GenServer.stop(pid)
    end
  end
end
