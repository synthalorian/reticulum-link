# Changelog

All notable changes to Reticulum Link will be documented in this file.

## [0.1.0] - 2026-05-31

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
