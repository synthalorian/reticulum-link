# Reticulum Link — Implementation Plan

## Overview

Phased implementation of a full Reticulum transport node and LXMF relay in Elixir, targeting BEAM VM fault tolerance and Nerves embedded deployment.

## Phase 1: Crypto Foundation (Weeks 1–3)

**Goal:** Ed25519 identity, X25519 key exchange, AES-256 encryption — the cryptographic primitives Reticulum requires.

### Tasks
- [ ] `ReticulumLink.Crypto.Identity` — Ed25519 keypair generation, signing, verification
- [ ] `ReticulumLink.Crypto.KeyExchange` — X25519 ECDH for shared secret derivation
- [ ] `ReticulumLink.Crypto.Cipher` — AES-256-GCM encrypt/decrypt with HKDF key derivation
- [ ] `ReticulumLink.Crypto.Hash` — SHA-256/512 hashing, HMAC
- [ ] `ReticulumLink.Crypto.IdentityManager` — GenServer managing node identity, persistence
- [ ] Property-based tests for all crypto operations (StreamData)
- [ ] Fuzz testing against Python RNS reference implementation vectors

### File Touchpoints
```
lib/reticulum_link/crypto/identity.ex
lib/reticulum_link/crypto/key_exchange.ex
lib/reticulum_link/crypto/cipher.ex
lib/reticulum_link/crypto/hash.ex
lib/reticulum_link/crypto/identity_manager.ex
test/reticulum_link/crypto_test.exs
```

## Phase 2: Packet & Protocol (Weeks 4–6)

**Goal:** Reticulum packet format, header parsing, destination addressing.

### Tasks
- [ ] `ReticulumLink.Transport.Packet` — struct with parse/serialize (header, payload, context)
- [ ] `ReticulumLink.Transport.Destination` — hash-based addressing, destination types (single/group/link)
- [ ] `ReticulumLink.Transport.Header` — Reticulum header format parser (type, context, hop count, TTL)
- [ ] `ReticulumLink.Transport.Interface` — behaviour for all interface types
- [ ] `ReticulumLink.Transport.Interface.Tcp` — TCP client/server interface
- [ ] `ReticulumLink.Transport.Interface.Serial` — serial/UART interface (RNode support)
- [ ] `ReticulumLink.Transport.Interface.AutoInterface` — mDNS-based local discovery
- [ ] Unit tests for packet roundtrip with Python RNS interop

### File Touchpoints
```
lib/reticulum_link/transport/packet.ex
lib/reticulum_link/transport/destination.ex
lib/reticulum_link/transport/header.ex
lib/reticulum_link/transport/interface.ex
lib/reticulum_link/transport/interface/tcp.ex
lib/reticulum_link/transport/interface/serial.ex
lib/reticulum_link/transport/interface/auto_interface.ex
test/reticulum_link/transport_test.exs
```

## Phase 3: Links & Announces (Weeks 7–9)

**Goal:** Encrypted link establishment, announce propagation, path management.

### Tasks
- [ ] `ReticulumLink.Transport.LinkManager` — DynamicSupervisor spawning one GenServer per link
- [ ] `ReticulumLink.Transport.Link` — GenServer: link request → handshake → established → data → close
- [ ] `ReticulumLink.Transport.AnnounceHandler` — broadcast announces, cache, forward
- [ ] `ReticulumLink.Transport.PathManager` — routing table, path discovery, path expiration
- [ ] `ReticulumLink.Transport.Transport` — enable forwarding mode (backbone node)
- [ ] Link handoff: ping/pong keepalive, re-establishment after failure
- [ ] Integration test: two Elixir nodes establishing a link over TCP

### File Touchpoints
```
lib/reticulum_link/transport/link_manager.ex
lib/reticulum_link/transport/link.ex
lib/reticulum_link/transport/announce_handler.ex
lib/reticulum_link/transport/path_manager.ex
lib/reticulum_link/transport/transport.ex
test/reticulum_link/transport/link_test.exs
```

## Phase 4: LXMF Relay (Weeks 10–12)

**Goal:** Store-and-forward LXMF message propagation.

### Tasks
- [ ] `ReticulumLink.Lxmf.PropagationEngine` — receive, store, propagate LXMF messages
- [ ] `ReticulumLink.Lxmf.MessageStore` — ETS + DETS backed message storage with TTL
- [ ] `ReticulumLink.Lxmf.Message` — LXMF message struct (sender, destination, content, timestamp, signatures)
- [ ] `ReticulumLink.Lxmf.DeliveryTracker` — track delivery receipts and propagation status
- [ ] Priority queue — urgent messages get priority in propagation
- [ ] Message deduplication — hash-based dedup to prevent relay storms
- [ ] Configurable propagation limits — max storage, TTL, max message size
- [ ] Integration test: send message from Python RNS → Elixir relay → Python RNS

### File Touchpoints
```
lib/reticulum_link/lxmf/propagation_engine.ex
lib/reticulum_link/lxmf/message_store.ex
lib/reticulum_link/lxmf/message.ex
lib/reticulum_link/lxmf/delivery_tracker.ex
test/reticulum_link/lxmf_test.exs
```

## Phase 5: Web Bridge & API (Weeks 13–14)

**Goal:** Phoenix WebSocket bridge and REST API for external clients.

### Tasks
- [ ] Phoenix endpoint with WebSocket channel for real-time events
- [ ] REST API: `GET /api/status`, `POST /api/messages`, `GET /api/peers`
- [ ] Token-based API authentication
- [ ] `ReticulumLink.Web.StatusController` — node status, uptime, peer count
- [ ] `ReticulumLink.Web.MessagesController` — send/list LXMF messages
- [ ] `ReticulumLink.Web.PeersChannel` — WebSocket channel for peer events
- [ ] OpenAPI spec for API documentation

### File Touchpoints
```
lib/reticulum_link/web/endpoint.ex
lib/reticulum_link/web/router.ex
lib/reticulum_link/web/controllers/status_controller.ex
lib/reticulum_link/web/controllers/messages_controller.ex
lib/reticulum_link/web/channels/peers_channel.ex
lib/reticulum_link/web/channels/user_socket.ex
```

## Phase 6: Observability (Week 15)

**Goal:** Production-ready monitoring and metrics.

### Tasks
- [ ] Telemetry events for all major operations
- [ ] Prometheus metrics endpoint (`/metrics`)
- [ ] Key metrics: active links, messages propagated, bandwidth per interface, memory/CPU
- [ ] Structured logging with Logger metadata
- [ ] Health check endpoint for load balancers

### File Touchpoints
```
lib/reticulum_link/telemetry.ex
lib/reticulum_link/web/controllers/metrics_controller.ex
```

## Phase 7: Nerves & Embedded (Weeks 16–17)

**Goal:** Bootable Raspberry Pi firmware.

### Tasks
- [ ] Nerves project setup with `mix nerves.new` integration
- [ ] Target configs: `rpi4`, `rpi3`, `rpi0` (Pi Zero 2W)
- [ ] Hardware integration: RNode serial, LoRa HAT (SX1276/SX1262)
- [ ] VintageNet configuration for WiFi/Ethernet
- [ ] SSH firmware push (`mix firmware.push`)
- [ ] OTA update support
- [ ] Minimal default config for headless operation

### File Touchpoints
```
config/target/rpi4.exs
config/target/rpi3.exs
rel/config.exs
rootfs_overlay/etc/iex.exs
```

## Phase 8: Release & Polish (Week 18)

**Goal:** v1.0.0 release.

### Tasks
- [ ] Comprehensive documentation (ExDoc with guides)
- [ ] Interop test suite against Python RNS reference
- [ ] Docker image for server deployment
- [ ] GitHub Actions CI (test, dialyzer, credo)
- [ ] Contribution guide and issue templates
- [ ] Hex.pm package publication
- [ ] Release v1.0.0

## Success Metrics

| Metric | Target |
|--------|--------|
| Concurrent links | > 10,000 |
| Message throughput | > 1,000 msg/s |
| Memory per link | < 10 KB |
| Link establishment | < 2s |
| Crash recovery | < 500ms |
| Pi Zero 2W memory | < 200 MB total |
| Uptime | 99.99% |
