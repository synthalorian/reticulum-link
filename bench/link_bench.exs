defmodule ReticulumLink.Bench.LinkBench do
  @moduledoc """
  Performance benchmarks for Reticulum Link.

  Measures:
  - Link creation throughput
  - Memory per link
  - Message propagation throughput
  - Crypto operation latency

  Run with: mix run bench/link_bench.exs
  """

  alias ReticulumLink.Transport.{Link, LinkManager}
  alias ReticulumLink.Crypto.{Identity, Cipher, Hash}
  alias ReticulumLink.Lxmf.{Message, MessageStore}

  @doc "Run all benchmarks"
  def run do
    IO.puts("═══════════════════════════════════════════════════════════════")
    IO.puts("  RETICULUM LINK PERFORMANCE BENCHMARKS")
    IO.puts("═══════════════════════════════════════════════════════════════")
    IO.puts("")

    bench_crypto()
    bench_link_creation()
    bench_link_memory()
    bench_message_storage()
    bench_packet_roundtrip()

    IO.puts("")
    IO.puts("═══════════════════════════════════════════════════════════════")
    IO.puts("  BENCHMARKS COMPLETE")
    IO.puts("═══════════════════════════════════════════════════════════════")
  end

  # ── Crypto benchmarks ───────────────────────────────────

  defp bench_crypto do
    IO.puts("── Crypto Operations ────────────────────────────────────────")

    # Ed25519 key generation
    {time_us, _} = :timer.tc(fn ->
      for _ <- 1..1000 do
        Identity.generate_keypair()
      end
    end)

    per_op = time_us / 1000
    IO.puts("  Ed25519 key generation: #{:erlang.float_to_binary(per_op, decimals: 2)} µs/op (#{trunc(1_000_000 / per_op)} ops/s)")

    # Signing
    {:ok, {sk, pk}} = Identity.generate_keypair()
    message = :crypto.strong_rand_bytes(256)

    {time_us, _} = :timer.tc(fn ->
      for _ <- 1..1000 do
        Identity.sign(message, sk)
      end
    end)

    per_op = time_us / 1000
    IO.puts("  Ed25519 sign (256B):    #{:erlang.float_to_binary(per_op, decimals: 2)} µs/op (#{trunc(1_000_000 / per_op)} ops/s)")

    # Verification
    sig = Identity.sign(message, sk)

    {time_us, _} = :timer.tc(fn ->
      for _ <- 1..1000 do
        Identity.verify(message, sig, pk)
      end
    end)

    per_op = time_us / 1000
    IO.puts("  Ed25519 verify (256B):  #{:erlang.float_to_binary(per_op, decimals: 2)} µs/op (#{trunc(1_000_000 / per_op)} ops/s)")

    # AES-256-GCM encrypt
    key = :crypto.strong_rand_bytes(32)
    nonce = :crypto.strong_rand_bytes(12)
    plaintext = :crypto.strong_rand_bytes(383)

    {time_us, _} = :timer.tc(fn ->
      for _ <- 1..1000 do
        Cipher.encrypt(plaintext, key, nonce)
      end
    end)

    per_op = time_us / 1000
    IO.puts("  AES-256-GCM encrypt:    #{:erlang.float_to_binary(per_op, decimals: 2)} µs/op (#{trunc(1_000_000 / per_op)} ops/s)")

    # SHA-256
    data = :crypto.strong_rand_bytes(500)

    {time_us, _} = :timer.tc(fn ->
      for _ <- 1..1000 do
        Hash.sha256(data)
      end
    end)

    per_op = time_us / 1000
    IO.puts("  SHA-256 (500B):         #{:erlang.float_to_binary(per_op, decimals: 2)} µs/op (#{trunc(1_000_000 / per_op)} ops/s)")

    IO.puts("")
  end

  # ── Link creation benchmark ─────────────────────────────

  defp bench_link_creation do
    IO.puts("── Link Creation Throughput ─────────────────────────────────")

    {:ok, _lm} = LinkManager.start_link(name: :bench_lm)

    counts = [100, 500, 1000]

    for count <- counts do
      {time_us, _} = :timer.tc(fn ->
        for _ <- 1..count do
          dst = :crypto.strong_rand_bytes(16)
          LinkManager.start_link_initiator(dst)
        end
      end)

      time_ms = time_us / 1000
      per_link = time_us / count
      links_per_sec = trunc(count / (time_us / 1_000_000))

      IO.puts("  #{count} links: #{:erlang.float_to_binary(time_ms, decimals: 1)} ms total, #{:erlang.float_to_binary(per_link, decimals: 1)} µs/link, #{links_per_sec} links/s")
    end

    DynamicSupervisor.stop(:bench_lm)
    IO.puts("")
  end

  # ── Memory per link ─────────────────────────────────────

  defp bench_link_memory do
    IO.puts("── Memory Per Link ──────────────────────────────────────────")

    {:ok, _lm} = LinkManager.start_link(name: :bench_mem_lm)

    # Baseline memory
    :erlang.garbage_collect()
    Process.sleep(200)
    baseline = :erlang.memory(:processes_used)

    # Create 1000 links with pre-generated keys (avoids heap bloat from crypto NIFs)
    for _ <- 1..1000 do
      dst = :crypto.strong_rand_bytes(16)
      keys = Link.generate_keys()
      LinkManager.start_link_initiator(dst, keys: keys)
    end

    Process.sleep(200)
    :erlang.garbage_collect()
    Process.sleep(200)

    after_mem = :erlang.memory(:processes_used)
    used = max(after_mem - baseline, 0)
    per_link = div(used, 1000)

    IO.puts("  Baseline processes_used: #{div(baseline, 1024)} KB")
    IO.puts("  After 1000 links:        #{div(after_mem, 1024)} KB")
    IO.puts("  Memory per link:         #{per_link} bytes (#{Float.round(per_link / 1024, 2)} KB)")

    active = LinkManager.link_count()
    IO.puts("  Active links:            #{active}")

    DynamicSupervisor.stop(:bench_mem_lm)
    IO.puts("")
  end

  # ── Message storage benchmark ───────────────────────────

  defp bench_message_storage do
    IO.puts("── LXMF Message Storage ─────────────────────────────────────")

    tmp_path = Path.join(System.tmp_dir!(), "bench_messages_#{:erlang.unique_integer([:positive])}.dets")
    {:ok, store} = MessageStore.start_link(dets_path: tmp_path, max_messages: 10_000, name: :bench_store)

    dest = :crypto.strong_rand_bytes(16)
    src = :crypto.strong_rand_bytes(16)

    # Store 1000 messages
    {time_us, _} = :timer.tc(fn ->
      for i <- 1..1000 do
        msg = Message.new(dest, src, "message #{i}")
        {:ok, packed} = Message.pack(msg)
        MessageStore.store(store, packed, priority: rem(i, 10))
      end
    end)

    time_ms = time_us / 1000
    per_msg = time_us / 1000
    msgs_per_sec = trunc(1000 / (time_us / 1_000_000))

    IO.puts("  Store 1000 messages: #{:erlang.float_to_binary(time_ms, decimals: 1)} ms total")
    IO.puts("  Per message:         #{:erlang.float_to_binary(per_msg, decimals: 1)} µs")
    IO.puts("  Throughput:          #{msgs_per_sec} msgs/s")

    # Priority query
    {time_us, _} = :timer.tc(fn ->
      MessageStore.by_priority(store, 100)
    end)

    IO.puts("  Priority query top 100: #{time_us} µs")

    GenServer.stop(:bench_store)
    File.rm(tmp_path)
    IO.puts("")
  end

  # ── Packet roundtrip benchmark ──────────────────────────

  defp bench_packet_roundtrip do
    IO.puts("── Packet Pack/Unpack ───────────────────────────────────────")

    alias ReticulumLink.Transport.{Destination, Packet}

    {:ok, dest} = Destination.create(:plain, :out, "bench", [], nil)
    data = :crypto.strong_rand_bytes(400)
    packet = Packet.new(dest, data)

    # Pack
    {pack_time, _packed} = :timer.tc(fn ->
      for _ <- 1..1000 do
        {:ok, p} = Packet.pack(packet)
        p
      end
    end)

    # Unpack
    {:ok, packed_packet} = Packet.pack(packet)
    raw = packed_packet.raw

    {unpack_time, _} = :timer.tc(fn ->
      for _ <- 1..1000 do
        Packet.unpack(raw)
      end
    end)

    IO.puts("  Pack 1000 packets:   #{:erlang.float_to_binary(pack_time / 1000, decimals: 1)} µs/packet")
    IO.puts("  Unpack 1000 packets: #{:erlang.float_to_binary(unpack_time / 1000, decimals: 1)} µs/packet")
    IO.puts("")
  end
end

# Run benchmarks
ReticulumLink.Bench.LinkBench.run()
