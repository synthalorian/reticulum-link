defmodule ReticulumLink.TelemetryTest do
  use ExUnit.Case, async: true

  alias ReticulumLink.Telemetry

  describe "telemetry events" do
    test "link_created emits event" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:reticulum_link, :link, :created]])
      Telemetry.link_created("link_123", %{type: :initiator})

      assert_receive {[:reticulum_link, :link, :created], ^ref, %{count: 1},
                      %{link_id: "link_123", type: :initiator}}
    end

    test "link_closed emits event" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:reticulum_link, :link, :closed]])
      Telemetry.link_closed("link_123")

      assert_receive {[:reticulum_link, :link, :closed], ^ref, %{count: 1},
                      %{link_id: "link_123"}}
    end

    test "message_received emits event" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:reticulum_link, :message, :received]])

      Telemetry.message_received(<<1, 2, 3>>)

      assert_receive {[:reticulum_link, :message, :received], ^ref, %{count: 1},
                      %{hash: <<1, 2, 3>>}}
    end

    test "message_propagated emits event" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:reticulum_link, :message, :propagated]])

      Telemetry.message_propagated(<<1, 2, 3>>)

      assert_receive {[:reticulum_link, :message, :propagated], ^ref, %{count: 1},
                      %{hash: <<1, 2, 3>>}}
    end

    test "path_discovered emits event" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:reticulum_link, :path, :discovered]])
      Telemetry.path_discovered(<<1, 2, 3>>, 3)

      assert_receive {[:reticulum_link, :path, :discovered], ^ref, %{count: 1},
                      %{destination: <<1, 2, 3>>, hops: 3}}
    end

    test "packet_sent emits event" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:reticulum_link, :transport, :packet, :sent]
        ])

      Telemetry.packet_sent(256)

      assert_receive {[:reticulum_link, :transport, :packet, :sent], ^ref, %{bytes: 256}, %{}}
    end

    test "packet_received emits event" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:reticulum_link, :transport, :packet, :received]
        ])

      Telemetry.packet_received(512)

      assert_receive {[:reticulum_link, :transport, :packet, :received], ^ref, %{bytes: 512}, %{}}
    end

    test "packet_forwarded emits event" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:reticulum_link, :transport, :packet, :forwarded]
        ])

      Telemetry.packet_forwarded(128)

      assert_receive {[:reticulum_link, :transport, :packet, :forwarded], ^ref, %{bytes: 128},
                      %{}}
    end

    test "collect_system_metrics emits memory and process events" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:reticulum_link, :system, :memory],
          [:reticulum_link, :system, :process]
        ])

      Telemetry.collect_system_metrics()

      assert_receive {[:reticulum_link, :system, :memory], ^ref, %{usage: _}, %{}}
      assert_receive {[:reticulum_link, :system, :process], ^ref, %{count: _}, %{}}
    end
  end

  describe "metrics list" do
    test "returns list of telemetry metrics" do
      metrics = Telemetry.metrics()
      assert is_list(metrics)
      assert metrics != []

      names = Enum.map(metrics, & &1.name)
      assert [:reticulum_link, :link, :created, :count] in names
      assert [:reticulum_link, :message, :received, :count] in names
      assert [:reticulum_link, :system, :memory, :usage] in names
    end
  end
end
