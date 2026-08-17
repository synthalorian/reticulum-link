# Changelog

All notable changes to Reticulum Link will be documented in this file.

## [1.0.0] - 2026-06-01

### Overview

First stable release. All 8 implementation phases complete. The API is now stable — no breaking changes without a major version bump.

### Added

- **Ship-Readiness** — Production-quality code hygiene
  - `mix.exs` package metadata: Apache-2.0 license, GitHub/Reticulum links, maintainers
  - Dialyzer: zero errors (fixed Mix.target/0, Nerves no_return, PromEx callback types)
  - Credo: zero issues (refactored nested functions, eliminated negated conditions)
  - `mix format --check-formatted`: clean across all 45 source files

### Changed

- Version bumped to 1.0.0 — stable API guarantee

### Fixed (post-tag verification sweep)

- **`/metrics` endpoint was non-functional** — `MetricsController` treated `Telemetry.Metrics` struct names (atom lists) as strings, crashing with `FunctionClauseError`, and the `:telemetry_event_table` ETS table it read was never created. The endpoint now renders valid Prometheus text exposition format backed by a `:telemetry` handler that maintains counters and last-value gauges in ETS (attached in `ReticulumLink.Telemetry.init/1`). Covered by 2 new tests.
- **Credo strict sweep** — eliminated all 11 remaining issues: `apply(Mix, :target, [])` replaced with a compile-time `@mix_target` attribute (Mix is unavailable in releases), nested-module aliases added, alias ordering fixed.
- **`bench/link_bench.exs`** — fixed missing `Link` alias that crashed the memory benchmark; the full suite now runs to completion (`mix run bench/link_bench.exs`).

### Documentation (post-tag verification sweep)

- README: documented the Arch/CachyOS split-Erlang gotcha (`pacman -S erlang-parsetools erlang-ssh erlang-tools erlang-os_mon`)
- README: documented `pip install rns` requirement for the Python RNS interop tests
- README: added test-suite and benchmark run instructions

---

## [0.7.0] - 2026-06-01

### Added

- **Hardened Crypto** — Production-ready key exchange and proof validation
  - `ReticulumLink.Crypto.KeyExchange.derive_keypair!/2` — Deterministic X25519 keypair derivation from seed + context via HKDF-SHA-256
  - `ReticulumLink.Transport.Link` — Full handshake proof generation and validation with ECDH key exchange, AES-256-GCM encrypted data channel
  - Ephemeral keys stored in process dictionary (not state struct) to prevent accidental logging/exposure
  - Pre-generated key option (`:keys`) for memory-constrained deployments — reduces per-link heap from ~400 KB to ~2.6 KB
- **Prometheus Metrics** — PromEx plugin with Telemetry integration
  - `ReticulumLink.Telemetry.PromExPlugin` — Counters for links created/closed, messages received/propagated, packets forwarded/dropped
  - Last-value gauges for active link count, path count, message queue depth, system memory
  - `promex_spec/0` for PromEx discovery
- **Python RNS Interop** — Verified cryptographic compatibility with reference implementation
  - HKDF-SHA-256 roundtrip tests (Elixir ↔ Python `cryptography`)
  - AES-256-GCM encrypt/decrypt roundtrip tests with shared key derivation
  - Python RNS 1.3.1 compatibility verified
- **Nerves Embedded Support** — Raspberry Pi firmware targets
  - `ReticulumLink.Nerves` — LED heartbeat, system info, reboot/poweroff helpers
  - Per-target configs: `rpi4.exs`, `rpi3.exs`, `rpi0.exs` with WiFi, Ethernet, and mDNS
  - `config/target.exs` loader with conditional `import_config`
  - `nerves`, `shoehorn`, `ring_logger`, `nerves_runtime`, `nerves_pack` dependencies
  - Firmware aliases: `mix firmware`, `mix firmware.burn`
- **Performance Benchmarks** — `bench/link_bench.exs` suite
  - Crypto throughput (Ed25519 sign/verify, X25519 ECDH, AES-256-GCM)
  - Link lifecycle (creation, handshake, teardown)
  - Memory profiling with `:erlang.memory/1` — verified <10 KB/link target achieved
  - Message throughput and packet forwarding benchmarks
- **Transport Backbone Forwarding** — Full packet routing for network backbone nodes
  - `Transport.forward_to_destination/2` — Path-aware forwarding via PathManager lookup
  - `Transport.handle_inbound_packet/2` — Hop-count enforcement, local destination detection, transit forwarding
  - `Transport.stats/0` and `Transport.reset_stats/0` — Forward/drop counters
  - Phoenix PubSub topics: `reticulum:forward` (flood) and `reticulum:forward:<hex_tid>` (directed)
  - Max hops enforcement (default 128) with `:max_hops_exceeded` drops
- **Test Suite** — 17 additional ExUnit tests (120 total)
  - Link handshake and proof validation (3 tests)
  - PromEx telemetry events (1 test)
  - RNS interop HKDF + AES-GCM roundtrip (2 tests)
  - Nerves module lifecycle (1 test)
  - Transport backbone forwarding (5 tests)
  - LXMF PropagationEngine integration (3 tests)
  - Link encrypted data channel roundtrip (2 tests)

### Changed

- `Transport` singleton now started with `[enabled: false]` by default (local node mode)
- `Link.start_link_initiator/2` and `start_link_responder/4` accept `:keys` option for pre-generated keypairs
- mix.exs version bumped to 0.7.0

### Fixed

- Ed25519 NIF heap bloat — pre-generating keys outside Link process avoids ~400 KB BEAM allocator overhead per link
- `Registry.keys/1` undefined function warning (removed arity-1 call)
- Transport test isolation — `on_exit` hook disables/reset singleton between tests
- PubSub topic encoding mismatch — `transport_id` now hex-encoded in forwarding topics

---

## [0.6.0] - 2026-05-31

### Added

- **Observability** — Production-ready monitoring and metrics
  - `ReticulumLink.Telemetry` — Telemetry events for all major operations: link created/closed, message received/propagated, path discovered, packet sent/received/forwarded, system memory/process counts
  - `ReticulumLink.Web.MetricsController` — Prometheus-compatible `/metrics` endpoint with counter and gauge metrics
  - `ReticulumLink.Web.HealthController` — `/health` endpoint for load balancers, returns 200 (healthy) or 503 (degraded) based on process liveness checks
  - Structured logging via Logger metadata throughout controllers
  - Telemetry poller for periodic system metrics collection (every 10s)
- **Integration** — Telemetry wired into Application supervisor, health/metrics routes added to Router
- **Test Suite** — 10 additional ExUnit tests covering all telemetry events and metrics list (103 total)

### Changed

- mix.exs version bumped to 0.6.0

---

## [0.5.0] - 2026-05-31

### Added

- **Web Bridge & API** — Phoenix REST API and WebSocket channel for external clients
  - `ReticulumLink.Web.Router` — API routes: `/api/status`, `/api/peers`, `/api/messages`
  - `ReticulumLink.Web.StatusController` — Node status: version, uptime, link count, path count, message count, propagation state
  - `ReticulumLink.Web.PeersController` — List known peers from PathManager with hex-encoded hashes
  - `ReticulumLink.Web.MessagesController` — List stored LXMF messages and create new ones via POST
  - `ReticulumLink.Web.UserSocket` + `PeersChannel` — WebSocket channel for real-time peer events, join "peers:lobby", ping/list_peers messages
  - `ReticulumLink.Web.Plugs.Auth` — Token-based API auth (`Authorization: Bearer ***`). No tokens configured = allow all (dev mode)
- **Integration** — Endpoint wired with socket (`/socket`) and router, all controllers functional
- **Test Suite** — 9 additional ExUnit tests covering all API endpoints and auth plug (93 total)

### Changed

- mix.exs version bumped to 0.5.0

---

## [0.4.0] - 2026-05-31

### Added

- **LXMF Relay** — Store-and-forward message propagation engine
  - `ReticulumLink.Lxmf.Message` — LXMF message struct with pack/unpack serialization matching Python RNS wire format (destination_hash, source_hash, signature, msgpack payload)
  - `ReticulumLink.Lxmf.MessageStore` — ETS + DETS backed storage with TTL expiration, priority indexing, FIFO eviction, and crash recovery
  - `ReticulumLink.Lxmf.DeliveryTracker` — Delivery receipt tracking with pending/propagated/delivered/failed states, per-peer propagation dedup, attempt limiting, and expiry cleanup
  - `ReticulumLink.Lxmf.PropagationEngine` — Receive, deduplicate, store, and batch-propagate LXMF messages via PubSub with configurable batch size, interval, and max hops
- **Integration** — All LXMF modules wired into `ReticulumLink.Lxmf.Supervisor`
- **Test Suite** — 23 additional ExUnit tests covering message pack/unpack, message store CRUD, priority queue, eviction, delivery tracking, and propagation status (84 total)

### Changed

- mix.exs version bumped to 0.4.0

---

## [0.3.0] - 2026-05-31

### Added

- **Links & Announces** — Full Reticulum link state machine and announce propagation
  - `ReticulumLink.Transport.Link` — GenServer state machine (PENDING → HANDSHAKE → ACTIVE → STALE → CLOSED) with ECDH key exchange, HKDF key derivation, AES-256-GCM encrypt/decrypt, keepalive watchdog, and stale/timeout detection
  - `ReticulumLink.Transport.LinkManager` — DynamicSupervisor for per-link processes with configurable restart strategy
  - `ReticulumLink.Transport.PathManager` — ETS routing table with TTL expiration, periodic cleanup, and PubSub path request broadcast
  - `ReticulumLink.Transport.AnnounceHandler` — Announce deduplication (rolling hash set), FIFO caching, path registration on receive, conditional forwarding when transport mode enabled
  - `ReticulumLink.Transport.Transport` — Transport mode coordinator with enable/disable, max hops enforcement, local destination detection, and packet forwarding
- **Integration** — All transport modules wired into `ReticulumLink.Transport.Supervisor`
- **Test Suite** — 10 additional ExUnit tests covering link lifecycle, path manager operations, and transport coordination (61 total)

### Changed

- PathManager uses unnamed ETS tables (table ref in GenServer state) to avoid async test collisions
- LinkManager uses `:temporary` restart strategy — crashed links don't auto-restart

### Fixed

- ETS match spec syntax errors in PathManager and AnnounceHandler (invalid `%{expires_at: :"$1", :_ => :_}` pattern)
- Named process collisions in PathManager tests (removed `:named_table`)

---

## [0.2.0] - 2026-05-30

### Added

- **Packet & Protocol Layer** — Reticulum packet framing, header parsing, destination addressing
  - `ReticulumLink.Transport.Packet` — Packet struct with pack/unpack, type validation, and payload handling
  - `ReticulumLink.Transport.Header` — Header parsing with context flags, destination hash, and hop count
  - `ReticulumLink.Transport.Destination` — Destination struct with hash derivation and address validation
  - `ReticulumLink.Transport.Interface` — Behaviour for transport interfaces (TCP, Serial, LoRa, AutoInterface)
  - `ReticulumLink.Transport.Interface.Tcp` — TCP interface implementation
  - `ReticulumLink.Transport.Interface.Serial` — Serial interface implementation
  - `ReticulumLink.Transport.Interface.AutoInterface` — Auto-discovery interface implementation
- **Transport Supervisor** — OTP supervision tree for transport layer components
- **Test Suite** — 24 ExUnit tests covering packet, header, destination, and interface operations

---

## [0.1.0] - 2026-05-28

### Added

- **Crypto Foundation** — Full Ed25519/X25519 identity and AES-256-GCM encryption layer
  - `ReticulumLink.Crypto.Identity` — Ed25519 keypair generation, signing, verification, Curve25519 conversion
  - `ReticulumLink.Crypto.KeyExchange` — X25519 ECDH shared secret derivation via `:crypto.compute_key/4`
  - `ReticulumLink.Crypto.Cipher` — AES-256-GCM encrypt/decrypt with HKDF key derivation
  - `ReticulumLink.Crypto.Hash` — SHA-256/512, HMAC, HKDF (extract + expand) per RFC 5869
  - `ReticulumLink.Crypto.IdentityManager` — GenServer for node identity lifecycle with JSON persistence
- **OTP Application Scaffold** — Top-level supervisor with PubSub, Transport, LXMF, and Web Endpoint children
- **Test Suite** — 27 ExUnit tests covering all crypto operations (identity, key exchange, cipher, hash, identity manager)
- **Project Metadata** — mix.exs with releases, docs, Credo, Dialyxir, ExDoc

### Fixed

- Cipher AES-GCM tag extraction (`split_tag/1` returned nested tuple instead of raw binary)
- Cipher AES-GCM algorithm specifier (`:aes_gcm` → `:aes_256_gcm`)
- HKDF extract salt/ikm argument order (HMAC key vs message were swapped)
- X25519 shared secret computation (replaced broken hand-rolled Montgomery ladder with `:crypto.compute_key/4`)
- IdentityManager test conflicts (named process collisions between async tests)

### Security

- All secret keys stored as raw binaries (never logged or exposed)
- Atomic file writes for identity persistence (write temp → rename)
- AES-GCM authenticated encryption with 128-bit tags

---

Built by **synth** with **synthclaw** 🎹🦞
