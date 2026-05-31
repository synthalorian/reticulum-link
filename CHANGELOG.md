# Changelog

All notable changes to Reticulum Link will be documented in this file.

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

Built by **synth** (synthalorian) with **synthshark** 🎹🦈
