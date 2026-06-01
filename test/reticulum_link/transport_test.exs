defmodule ReticulumLink.TransportTest do
  use ExUnit.Case, async: true

  alias ReticulumLink.Transport.{Destination, Header, Packet}

  describe "Header" do
    test "pack and parse flags roundtrip" do
      for header_type <- [0, 1],
          context_flag <- [0, 1],
          transport_type <- [0, 1],
          destination_type <- [0, 1, 2, 3],
          packet_type <- [0, 1, 2, 3] do
        flags =
          Header.pack_flags(
            header_type,
            context_flag,
            transport_type,
            destination_type,
            packet_type
          )

        assert is_integer(flags)
        assert flags >= 0 and flags <= 255

        {parsed_ht, parsed_cf, parsed_tt, parsed_dt, parsed_pt} = Header.parse_flags(flags)

        assert parsed_ht == header_type
        assert parsed_cf == context_flag
        assert parsed_tt == transport_type
        assert parsed_dt == destination_type
        assert parsed_pt == packet_type
      end
    end

    test "HEADER_1 pack and parse roundtrip" do
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

      serialized = Header.serialize(header)
      assert byte_size(serialized) == 19

      {:ok, parsed} = Header.parse(serialized)
      assert parsed.header_type == header.header_type
      assert parsed.context_flag == header.context_flag
      assert parsed.transport_type == header.transport_type
      assert parsed.destination_type == header.destination_type
      assert parsed.packet_type == header.packet_type
      assert parsed.hops == header.hops
      assert parsed.transport_id == nil
      assert parsed.destination_hash == dst_hash
      assert parsed.context == header.context
    end

    test "HEADER_2 pack and parse roundtrip" do
      dst_hash = :crypto.strong_rand_bytes(16)
      transport_id = :crypto.strong_rand_bytes(16)

      header = %Header{
        header_type: 1,
        context_flag: 1,
        transport_type: 1,
        destination_type: 3,
        packet_type: 2,
        hops: 10,
        transport_id: transport_id,
        destination_hash: dst_hash,
        context: 0xFA
      }

      serialized = Header.serialize(header)
      assert byte_size(serialized) == 35

      {:ok, parsed} = Header.parse(serialized)
      assert parsed.header_type == 1
      assert parsed.transport_id == transport_id
      assert parsed.destination_hash == dst_hash
      assert parsed.hops == 10
      assert parsed.context == 0xFA
    end

    test "increment_hops caps at 255" do
      header = %Header{
        header_type: 0,
        context_flag: 0,
        transport_type: 0,
        destination_type: 0,
        packet_type: 0,
        hops: 255,
        transport_id: nil,
        destination_hash: :crypto.strong_rand_bytes(16),
        context: 0
      }

      incremented = Header.increment_hops(header)
      assert incremented.hops == 255
    end

    test "parse rejects invalid header sizes" do
      assert {:error, :invalid_header_size} = Header.parse(<<1, 2, 3>>)
      assert {:error, :invalid_header_size} = Header.parse(:crypto.strong_rand_bytes(20))
      assert {:error, :invalid_header_size} = Header.parse(:crypto.strong_rand_bytes(36))
    end
  end

  describe "Destination" do
    test "create plain destination without identity" do
      {:ok, dest} = Destination.create(:plain, :out, "test", ["app"], nil)
      assert byte_size(dest.hash) == 16
      assert dest.type == :plain
      assert dest.direction == :out
      assert dest.app_name == "test"
      assert dest.aspects == ["app"]
      assert dest.identity_hash == nil
    end

    test "create single destination requires identity hash" do
      assert {:error, :single_requires_identity} =
               Destination.create(:single, :in, "test", [], nil)
    end

    test "create single destination with identity hash" do
      identity_hash = :crypto.strong_rand_bytes(16)
      {:ok, dest} = Destination.create(:single, :in, "test", ["app"], identity_hash)
      assert byte_size(dest.hash) == 16
      assert dest.type == :single
      assert dest.identity_hash == identity_hash
    end

    test "destination hash is deterministic" do
      identity_hash = :crypto.strong_rand_bytes(16)
      {:ok, dest1} = Destination.create(:single, :in, "test", ["app"], identity_hash)
      {:ok, dest2} = Destination.create(:single, :in, "test", ["app"], identity_hash)
      assert dest1.hash == dest2.hash
    end

    test "different names produce different hashes" do
      identity_hash = :crypto.strong_rand_bytes(16)
      {:ok, dest1} = Destination.create(:single, :in, "test", ["app"], identity_hash)
      {:ok, dest2} = Destination.create(:single, :in, "test", ["other"], identity_hash)
      assert dest1.hash != dest2.hash
    end

    test "name validation rejects dots" do
      assert {:error, :name_contains_dots} = Destination.create(:plain, :out, "test.app", [], nil)
    end

    test "aspect validation rejects dots" do
      assert {:error, :aspect_contains_dots} =
               Destination.create(:plain, :out, "test", ["a.b"], nil)
    end

    test "expand_name without identity" do
      assert Destination.expand_name("test", ["app", "v1"], nil) == "test.app.v1"
    end

    test "expand_name with identity" do
      hash = <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>
      result = Destination.expand_name("test", ["app"], hash)
      assert result == "test.app.000102030405060708090a0b0c0d0e0f"
    end

    test "hash_to_hex and hex_to_hash roundtrip" do
      hash = :crypto.strong_rand_bytes(16)
      hex = Destination.hash_to_hex(hash)
      assert String.length(hex) == 32
      assert {:ok, ^hash} = Destination.hex_to_hash(hex)
    end

    test "type_to_int and int_to_type roundtrip" do
      for type <- [:single, :group, :plain, :link] do
        int = Destination.type_to_int(type)
        assert Destination.int_to_type(int) == type
      end
    end
  end

  describe "Packet" do
    test "new creates a packet with correct defaults" do
      {:ok, dest} = Destination.create(:plain, :out, "test", [], nil)
      packet = Packet.new(dest, "hello")

      assert packet.header.destination_hash == dest.hash
      assert packet.header.packet_type == 0
      assert packet.header.context == 0
      assert packet.header.hops == 0
      assert packet.header.header_type == 0
      assert packet.ciphertext == "hello"
      assert packet.packed == false
    end

    test "pack and unpack roundtrip" do
      {:ok, dest} = Destination.create(:plain, :out, "test", [], nil)

      packet =
        Packet.new(dest, "hello world", packet_type: 0, context: 0x01, hops: 3)

      {:ok, packed} = Packet.pack(packet)
      assert packed.packed == true
      assert is_binary(packed.raw)
      assert byte_size(packed.packet_hash) == 32

      {:ok, unpacked} = Packet.unpack(packed.raw)
      assert unpacked.header.destination_hash == dest.hash
      assert unpacked.header.packet_type == 0
      assert unpacked.header.context == 0x01
      assert unpacked.header.hops == 3
      assert unpacked.ciphertext == "hello world"
      assert unpacked.packet_hash == packed.packet_hash
    end

    test "pack rejects packets exceeding MTU" do
      {:ok, dest} = Destination.create(:plain, :out, "test", [], nil)
      # 500 byte MTU - 19 byte header = 481 bytes max payload for HEADER_1
      oversized_data = :binary.copy("x", 490)
      packet = Packet.new(dest, oversized_data)
      assert {:error, :mtu_exceeded} = Packet.pack(packet)
    end

    test "unpack rejects data too short for header" do
      assert {:error, :packet_too_short} = Packet.unpack(<<1, 2, 3>>)
    end

    test "increment_hops increments packet header" do
      {:ok, dest} = Destination.create(:plain, :out, "test", [], nil)
      packet = Packet.new(dest, "data")
      incremented = Packet.increment_hops(packet)
      assert incremented.header.hops == 1
    end

    test "mdu returns correct values per destination type" do
      assert Packet.mdu(:plain) == 464
      assert Packet.mdu(:single) == 383
      assert Packet.mdu(:group) == 383
      assert Packet.mdu(:link) == 383
    end

    test "encrypt? returns false for unencrypted packet types" do
      header = %Header{
        header_type: 0,
        context_flag: 0,
        transport_type: 0,
        destination_type: 0,
        packet_type: 1,
        hops: 0,
        transport_id: nil,
        destination_hash: :crypto.strong_rand_bytes(16),
        context: 0
      }

      refute Packet.encrypt?(header)

      header_lr = %{header | packet_type: 2}
      refute Packet.encrypt?(header_lr)

      header_keepalive = %{header | context: 0xFA}
      refute Packet.encrypt?(header_keepalive)
    end

    test "encrypt? returns true for normal data" do
      header = %Header{
        header_type: 0,
        context_flag: 0,
        transport_type: 0,
        destination_type: 0,
        packet_type: 0,
        hops: 0,
        transport_id: nil,
        destination_hash: :crypto.strong_rand_bytes(16),
        context: 0
      }

      assert Packet.encrypt?(header)
    end
  end

  describe "Transport backbone forwarding" do
    alias ReticulumLink.Transport.{Transport, PathManager}

    setup do
      on_exit(fn ->
        Transport.disable()
        Transport.reset_stats()
      end)

      :ok
    end

    test "disabled transport drops transit packets" do
      {:ok, _pm} = PathManager.start_link(name: :test_tr_pm)

      Transport.disable()
      Transport.reset_stats()

      packet = %{destination_hash: :crypto.strong_rand_bytes(16), hops: 1}
      assert {:drop, :transport_disabled} = Transport.handle_inbound_packet(packet, "eth0")

      stats = Transport.stats()
      assert stats.dropped >= 1
      assert stats.forwarded == 0

      GenServer.stop(:test_tr_pm)
    end

    test "enabled transport forwards non-local packets" do
      {:ok, _pm} = PathManager.start_link(name: :test_tr_pm2)

      Transport.enable()
      Transport.reset_stats()

      # Subscribe to forwarding topic
      Phoenix.PubSub.subscribe(ReticulumLink.PubSub, "reticulum:forward")

      packet = %{destination_hash: :crypto.strong_rand_bytes(16), hops: 1}
      assert :ok = Transport.handle_inbound_packet(packet, "eth0")

      assert_receive {:forward_packet, ^packet}, 500

      stats = Transport.stats()
      assert stats.forwarded == 1
      assert stats.dropped == 0

      GenServer.stop(:test_tr_pm2)
    end

    test "max_hops exceeded drops packet" do
      {:ok, _pm} = PathManager.start_link(name: :test_tr_pm3)

      Transport.enable()
      Transport.reset_stats()

      packet = %{destination_hash: :crypto.strong_rand_bytes(16), hops: 128}
      assert {:drop, :max_hops_exceeded} = Transport.handle_inbound_packet(packet, "eth0")

      stats = Transport.stats()
      assert stats.dropped == 1

      GenServer.stop(:test_tr_pm3)
    end

    test "forward_to_destination uses path when available" do
      {:ok, pm} = PathManager.start_link(name: :test_tr_pm4)

      Transport.enable()
      Transport.reset_stats()

      dst = :crypto.strong_rand_bytes(16)
      tid = :crypto.strong_rand_bytes(16)

      :ok = PathManager.register_path(dst, tid, 2, 3600)

      Phoenix.PubSub.subscribe(ReticulumLink.PubSub, "reticulum:forward:#{Base.encode16(tid)}")

      packet = %{destination_hash: dst, hops: 1}
      assert :ok = Transport.forward_to_destination(dst, packet)

      assert_receive {:forward_packet, forwarded, path_entry}, 500
      assert forwarded.hops == 2
      assert path_entry.hops == 2

      GenServer.stop(pm)
    end

    test "stats and reset_stats work" do
      {:ok, _pm} = PathManager.start_link(name: :test_tr_pm5)

      Transport.enable()
      Transport.reset_stats()

      packet = %{destination_hash: :crypto.strong_rand_bytes(16), hops: 1}
      Transport.handle_inbound_packet(packet, "eth0")

      stats = Transport.stats()
      assert stats.forwarded == 1
      assert stats.enabled == true

      :ok = Transport.reset_stats()
      stats2 = Transport.stats()
      assert stats2.forwarded == 0

      GenServer.stop(:test_tr_pm5)
    end
  end
end
