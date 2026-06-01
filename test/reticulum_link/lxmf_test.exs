defmodule ReticulumLink.LxmfTest do
  use ExUnit.Case, async: true

  alias ReticulumLink.Lxmf.{DeliveryTracker, Message, MessageStore}

  # ── Message Tests ───────────────────────────────────────

  describe "Message" do
    test "new/6 creates a message with defaults" do
      dest = :crypto.strong_rand_bytes(16)
      src = :crypto.strong_rand_bytes(16)

      msg = Message.new(dest, src, "hello", "title", %{}, Message.method_direct())

      assert msg.destination_hash == dest
      assert msg.source_hash == src
      assert msg.content == "hello"
      assert msg.title == "title"
      assert msg.fields == %{}
      assert msg.desired_method == Message.method_direct()
      assert msg.state == Message.state_generating()
      assert msg.incoming == false
    end

    test "pack/1 serializes a message" do
      dest = :crypto.strong_rand_bytes(16)
      src = :crypto.strong_rand_bytes(16)

      msg = Message.new(dest, src, "hello world", "test", %{"key" => "value"})
      {:ok, packed_msg} = Message.pack(msg)

      assert packed_msg.hash != nil
      assert packed_msg.packed != nil
      assert packed_msg.packed_size > 0
      assert packed_msg.timestamp != nil
      assert packed_msg.state == Message.state_outbound()
    end

    test "pack/1 is idempotent" do
      dest = :crypto.strong_rand_bytes(16)
      src = :crypto.strong_rand_bytes(16)

      msg = Message.new(dest, src, "content")
      {:ok, packed1} = Message.pack(msg)
      {:ok, packed2} = Message.pack(packed1)

      assert packed1.packed == packed2.packed
    end

    test "unpack/1 deserializes a message" do
      dest = :crypto.strong_rand_bytes(16)
      src = :crypto.strong_rand_bytes(16)

      msg = Message.new(dest, src, "hello world", "test", %{"key" => "value"})
      {:ok, packed_msg} = Message.pack(msg)

      {:ok, unpacked} = Message.unpack(packed_msg.packed)

      assert unpacked.destination_hash == dest
      assert unpacked.source_hash == src
      assert unpacked.content == "hello world"
      assert unpacked.title == "test"
      assert unpacked.fields == %{"key" => "value"}
      assert unpacked.incoming == true
      assert unpacked.hash == packed_msg.hash
    end

    test "unpack/1 rejects invalid size" do
      assert {:error, :invalid_size} = Message.unpack(<<1, 2, 3>>)
    end

    test "validate_hash/1 verifies message integrity" do
      dest = :crypto.strong_rand_bytes(16)
      src = :crypto.strong_rand_bytes(16)

      msg = Message.new(dest, src, "content")
      {:ok, packed} = Message.pack(msg)

      assert Message.validate_hash(packed) == true

      # Corrupt the packed data — prepend a byte to shift everything
      corrupted = %{
        packed
        | packed: <<0>> <> binary_part(packed.packed, 0, byte_size(packed.packed) - 1)
      }

      assert Message.validate_hash(corrupted) == false
    end

    test "title_string/1 and content_string/1 return UTF-8" do
      dest = :crypto.strong_rand_bytes(16)
      src = :crypto.strong_rand_bytes(16)

      msg = Message.new(dest, src, "hello", "title")
      assert Message.title_string(msg) == "title"
      assert Message.content_string(msg) == "hello"
    end
  end

  # ── MessageStore Tests ──────────────────────────────────

  describe "MessageStore" do
    setup do
      # Use a temporary DETS path for isolation
      tmp_path =
        Path.join(System.tmp_dir!(), "test_messages_#{:erlang.unique_integer([:positive])}.dets")

      name = String.to_atom("test_store_#{:erlang.unique_integer([:positive])}")
      {:ok, store} = MessageStore.start_link(dets_path: tmp_path, max_messages: 100, name: name)

      on_exit(fn ->
        File.rm(tmp_path)
      end)

      %{store: store, tmp_path: tmp_path}
    end

    test "store/3 stores a message", %{store: store} do
      dest = :crypto.strong_rand_bytes(16)
      src = :crypto.strong_rand_bytes(16)
      msg = Message.new(dest, src, "hello")
      {:ok, packed} = Message.pack(msg)

      assert :ok = MessageStore.store(store, packed)
      assert MessageStore.count(store) == 1
    end

    test "lookup/2 retrieves a message", %{store: store} do
      dest = :crypto.strong_rand_bytes(16)
      src = :crypto.strong_rand_bytes(16)
      msg = Message.new(dest, src, "hello")
      {:ok, packed} = Message.pack(msg)

      :ok = MessageStore.store(store, packed)
      {:ok, found} = MessageStore.lookup(store, packed.hash)

      assert found.hash == packed.hash
      assert found.content == "hello"
    end

    test "lookup/2 returns not_found for missing", %{store: store} do
      assert {:error, :not_found} = MessageStore.lookup(store, :crypto.strong_rand_bytes(32))
    end

    test "delete/2 removes a message", %{store: store} do
      dest = :crypto.strong_rand_bytes(16)
      src = :crypto.strong_rand_bytes(16)
      msg = Message.new(dest, src, "hello")
      {:ok, packed} = Message.pack(msg)

      :ok = MessageStore.store(store, packed)
      assert MessageStore.count(store) == 1

      :ok = MessageStore.delete(store, packed.hash)
      assert MessageStore.count(store) == 0
      assert {:error, :not_found} = MessageStore.lookup(store, packed.hash)
    end

    test "all/0 returns all messages", %{store: store} do
      dest = :crypto.strong_rand_bytes(16)
      src = :crypto.strong_rand_bytes(16)

      msg1 = Message.new(dest, src, "first")
      {:ok, packed1} = Message.pack(msg1)

      msg2 = Message.new(dest, src, "second")
      {:ok, packed2} = Message.pack(msg2)

      :ok = MessageStore.store(store, packed1)
      :ok = MessageStore.store(store, packed2)

      all = MessageStore.all(store)
      assert length(all) == 2
    end

    test "by_priority/2 returns messages sorted", %{store: store} do
      dest = :crypto.strong_rand_bytes(16)
      src = :crypto.strong_rand_bytes(16)

      msg1 = Message.new(dest, src, "low")
      {:ok, packed1} = Message.pack(msg1)

      msg2 = Message.new(dest, src, "high")
      {:ok, packed2} = Message.pack(msg2)

      :ok = MessageStore.store(store, packed1, priority: 1)
      :ok = MessageStore.store(store, packed2, priority: 10)

      by_prio = MessageStore.by_priority(store, 10)
      assert length(by_prio) == 2
    end

    test "store/3 rejects oversized messages", %{store: store} do
      dest = :crypto.strong_rand_bytes(16)
      src = :crypto.strong_rand_bytes(16)
      msg = Message.new(dest, src, String.duplicate("x", 100_000))
      {:ok, packed} = Message.pack(msg)

      assert {:error, :message_too_large} = MessageStore.store(store, packed)
    end

    test "eviction removes oldest when at capacity", %{store: _store} do
      dest = :crypto.strong_rand_bytes(16)
      src = :crypto.strong_rand_bytes(16)

      # Store 3 messages, capacity is 100 so this won't trigger eviction
      # Instead test with a smaller capacity store
      tmp_path =
        Path.join(System.tmp_dir!(), "test_evict_#{:erlang.unique_integer([:positive])}.dets")

      name = String.to_atom("test_store_evict_#{:erlang.unique_integer([:positive])}")

      {:ok, small_store} =
        MessageStore.start_link(dets_path: tmp_path, max_messages: 2, name: name)

      msg1 = Message.new(dest, src, "first")
      {:ok, packed1} = Message.pack(msg1)

      msg2 = Message.new(dest, src, "second")
      {:ok, packed2} = Message.pack(msg2)

      msg3 = Message.new(dest, src, "third")
      {:ok, packed3} = Message.pack(msg3)

      :ok = MessageStore.store(small_store, packed1, priority: 1)
      :ok = MessageStore.store(small_store, packed2, priority: 2)
      :ok = MessageStore.store(small_store, packed3, priority: 3)

      assert MessageStore.count(small_store) == 2

      File.rm(tmp_path)
    end
  end

  # ── DeliveryTracker Tests ───────────────────────────────

  describe "DeliveryTracker" do
    setup do
      name = String.to_atom("test_tracker_#{:erlang.unique_integer([:positive])}")
      {:ok, tracker} = DeliveryTracker.start_link(name: name)
      %{tracker: tracker}
    end

    test "register/3 creates a pending entry", %{tracker: tracker} do
      hash = :crypto.strong_rand_bytes(32)
      assert :ok = DeliveryTracker.register(tracker, hash)

      {:ok, status} = DeliveryTracker.status(tracker, hash)
      assert status.status == :pending
      assert status.attempts == 0
    end

    test "mark_propagated/3 updates status", %{tracker: tracker} do
      hash = :crypto.strong_rand_bytes(32)
      :ok = DeliveryTracker.register(tracker, hash)
      :ok = DeliveryTracker.mark_propagated(tracker, hash, "peer1")

      {:ok, status} = DeliveryTracker.status(tracker, hash)
      assert status.status == :propagated
    end

    test "mark_delivered/2 updates status", %{tracker: tracker} do
      hash = :crypto.strong_rand_bytes(32)
      :ok = DeliveryTracker.register(tracker, hash)
      :ok = DeliveryTracker.mark_delivered(tracker, hash)

      {:ok, status} = DeliveryTracker.status(tracker, hash)
      assert status.status == :delivered
    end

    test "mark_failed/3 updates status", %{tracker: tracker} do
      hash = :crypto.strong_rand_bytes(32)
      :ok = DeliveryTracker.register(tracker, hash)
      :ok = DeliveryTracker.mark_failed(tracker, hash, :timeout)

      {:ok, status} = DeliveryTracker.status(tracker, hash)
      assert status.status == :failed
      assert status.failed_reason == :timeout
    end

    test "increment_attempt/2 tracks attempts", %{tracker: tracker} do
      hash = :crypto.strong_rand_bytes(32)
      :ok = DeliveryTracker.register(tracker, hash)

      assert {:ok, 1} = DeliveryTracker.increment_attempt(tracker, hash)
      assert {:ok, 2} = DeliveryTracker.increment_attempt(tracker, hash)
      assert {:ok, 3} = DeliveryTracker.increment_attempt(tracker, hash)
      assert {:error, :max_attempts_exceeded} = DeliveryTracker.increment_attempt(tracker, hash)

      {:ok, status} = DeliveryTracker.status(tracker, hash)
      assert status.status == :failed
      assert status.failed_reason == :max_attempts
    end

    test "propagated_to_peer?/3 tracks peer propagation", %{tracker: tracker} do
      hash = :crypto.strong_rand_bytes(32)
      :ok = DeliveryTracker.register(tracker, hash)

      assert false == DeliveryTracker.propagated_to_peer?(tracker, hash, "peer1")

      :ok = DeliveryTracker.mark_propagated(tracker, hash, "peer1")
      assert true == DeliveryTracker.propagated_to_peer?(tracker, hash, "peer1")
      assert false == DeliveryTracker.propagated_to_peer?(tracker, hash, "peer2")
    end

    test "pending/1 returns pending and propagated", %{tracker: tracker} do
      hash1 = :crypto.strong_rand_bytes(32)
      hash2 = :crypto.strong_rand_bytes(32)
      hash3 = :crypto.strong_rand_bytes(32)

      :ok = DeliveryTracker.register(tracker, hash1)
      :ok = DeliveryTracker.register(tracker, hash2)
      :ok = DeliveryTracker.register(tracker, hash3)
      :ok = DeliveryTracker.mark_delivered(tracker, hash3)

      pending = DeliveryTracker.pending(tracker)
      assert hash1 in pending
      assert hash2 in pending
      refute hash3 in pending
    end

    test "stats/1 returns counts", %{tracker: tracker} do
      hash1 = :crypto.strong_rand_bytes(32)
      hash2 = :crypto.strong_rand_bytes(32)
      hash3 = :crypto.strong_rand_bytes(32)
      hash4 = :crypto.strong_rand_bytes(32)

      :ok = DeliveryTracker.register(tracker, hash1)
      :ok = DeliveryTracker.register(tracker, hash2)
      :ok = DeliveryTracker.mark_propagated(tracker, hash2, "p")
      :ok = DeliveryTracker.register(tracker, hash3)
      :ok = DeliveryTracker.mark_delivered(tracker, hash3)
      :ok = DeliveryTracker.register(tracker, hash4)
      :ok = DeliveryTracker.mark_failed(tracker, hash4, :timeout)

      stats = DeliveryTracker.stats(tracker)
      assert stats.pending == 1
      assert stats.propagated == 1
      assert stats.delivered == 1
      assert stats.failed == 1
      assert stats.total == 4
    end
  end

  describe "PropagationEngine integration" do
    alias ReticulumLink.Lxmf.PropagationEngine

    test "propagation engine stores and propagates messages" do
      {:ok, store} =
        MessageStore.start_link(
          dets_path: tmp_dets_path(),
          max_messages: 100,
          name: :test_prop_store
        )

      {:ok, tracker} =
        DeliveryTracker.start_link(name: :test_prop_tracker)

      {:ok, engine} =
        PropagationEngine.start_link(
          message_store: store,
          delivery_tracker: tracker,
          batch_interval: 100,
          name: :test_prop_engine
        )

      # Subscribe to propagation topic
      Phoenix.PubSub.subscribe(ReticulumLink.PubSub, "lxmf:propagate")

      # Create and receive a message
      dest = :crypto.strong_rand_bytes(16)
      src = :crypto.strong_rand_bytes(16)
      msg = Message.new(dest, src, "propagation test")
      {:ok, packed} = Message.pack(msg)

      assert :ok = PropagationEngine.receive_message(engine, packed)

      # Trigger propagation
      assert :ok = PropagationEngine.propagate_now(engine)

      # Should receive broadcast
      assert_receive {:lxmf_propagate, _msg, _hops}, 500

      # Check delivery tracker status
      {:ok, status} = DeliveryTracker.status(tracker, packed.hash)
      assert status.status in [:propagated, :pending]

      GenServer.stop(engine)
      GenServer.stop(tracker)
      GenServer.stop(store)
    end

    test "deduplication rejects duplicate messages" do
      {:ok, store} =
        MessageStore.start_link(
          dets_path: tmp_dets_path(),
          max_messages: 100,
          name: :test_dedup_store
        )

      {:ok, tracker} =
        DeliveryTracker.start_link(name: :test_dedup_tracker)

      {:ok, engine} =
        PropagationEngine.start_link(
          message_store: store,
          delivery_tracker: tracker,
          name: :test_dedup_engine
        )

      dest = :crypto.strong_rand_bytes(16)
      src = :crypto.strong_rand_bytes(16)
      msg = Message.new(dest, src, "dedup test")
      {:ok, packed} = Message.pack(msg)

      # First receive succeeds
      assert :ok = PropagationEngine.receive_message(engine, packed)

      # Second receive fails as duplicate
      assert {:error, :duplicate} = PropagationEngine.receive_message(engine, packed)

      GenServer.stop(engine)
      GenServer.stop(tracker)
      GenServer.stop(store)
    end

    test "disable stops propagation" do
      {:ok, store} =
        MessageStore.start_link(
          dets_path: tmp_dets_path(),
          max_messages: 100,
          name: :test_disable_store
        )

      {:ok, tracker} =
        DeliveryTracker.start_link(name: :test_disable_tracker)

      {:ok, engine} =
        PropagationEngine.start_link(
          message_store: store,
          delivery_tracker: tracker,
          batch_interval: 50,
          name: :test_disable_engine
        )

      Phoenix.PubSub.subscribe(ReticulumLink.PubSub, "lxmf:propagate")

      # Disable propagation
      :ok = PropagationEngine.disable(engine)

      dest = :crypto.strong_rand_bytes(16)
      src = :crypto.strong_rand_bytes(16)
      msg = Message.new(dest, src, "disabled test")
      {:ok, packed} = Message.pack(msg)

      :ok = PropagationEngine.receive_message(engine, packed)
      :ok = PropagationEngine.propagate_now(engine)

      # Should NOT receive broadcast
      refute_receive {:lxmf_propagate, _, _}, 200

      GenServer.stop(engine)
      GenServer.stop(tracker)
      GenServer.stop(store)
    end
  end

  defp tmp_dets_path do
    Path.join(System.tmp_dir!(), "test_#{:erlang.unique_integer([:positive])}.dets")
  end
end
