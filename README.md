# ⟠ Reticulum Link

> High-performance Reticulum transport node and LXMF relay — built on the BEAM

```
    ╔════════════════════════════════════════════════════════════════════╗
    ║                    R E T I C U L U M   L I N K                    ║
    ║                                                                    ║
    ║   ┌──────────────────────────────────────────────────────────┐    ║
    ║   │               BEAM VM (Erlang Runtime)                   │    ║
    ║   │                                                          │    ║
    ║   │  ┌─────────────┐  ┌──────────────┐  ┌──────────────┐   │    ║
    ║   │  │ Supervisor  │  │ Supervisor    │  │ Supervisor   │   │    ║
    ║   │  │ Transport   │  │ LXMF Relay   │  │ Web Bridge   │   │    ║
    ║   │  └──────┬──────┘  └──────┬───────┘  └──────┬───────┘   │    ║
    ║   │         │                │                  │            │    ║
    ║   │  ┌──────┴──────┐  ┌─────┴──────┐  ┌───────┴────────┐  │    ║
    ║   │  │ Link Gen    │  │ Propagation│  │ Phoenix        │  │    ║
    ║   │  │ Servers     │  │ Store+Fwd  │  │ WebSocket      │  │    ║
    ║   │  │ (per-link)  │  │ Engine     │  │ + REST API     │  │    ║
    ║   │  └──────┬──────┘  └─────┬──────┘  └───────┬────────┘  │    ║
    ║   │         │                │                  │            │    ║
    ║   │  ┌──────┴────────────────┴──────────────────┴────────┐  │    ║
    ║   │  │              Reticulum Protocol Engine             │  │    ║
    ║   │  │  ┌─────────┐ ┌──────────┐ ┌───────────────────┐  │  │    ║
    ║   │  │  │ Identity│ │ Announce │ │ Routing & Path    │  │  │    ║
    ║   │  │  │ & Crypto │ │ Handler  │ │ Management        │  │  │    ║
    ║   │  │  └─────────┘ └──────────┘ └───────────────────┘  │  │    ║
    ║   │  └──────────────────────┬────────────────────────────┘  │    ║
    ║   └─────────────────────────┼───────────────────────────────┘    ║
    ║                             │                                     ║
    ║           ┌─────────────────┼─────────────────┐                 ║
    ║      ┌────┴─────┐    ┌─────┴──────┐    ┌─────┴──────┐         ║
    ║      │   TCP    │    │   RNode    │    │  Auto      │         ║
    ║      │  Server  │    │  (LoRa)    │    │ Interface  │         ║
    ║      └──────────┘    └────────────┘    └────────────┘         ║
    ╚════════════════════════════════════════════════════════════════════╝
```

## Overview

Reticulum Link is a high-performance Reticulum transport node and LXMF relay built in **Elixir**, leveraging the BEAM VM's actor model for fault-tolerant management of thousands of concurrent encrypted links. It serves as a network backbone node, message propagation relay, and service gateway.

Designed for 24/7 unattended operation on everything from cloud servers to Raspberry Pi (via Nerves firmware).

## Features

### 🔗 Transport Node
- **Full Reticulum protocol** reimplementation in Elixir (Identity, Link, Announce, Path, Packet)
- **Concurrent link management** — one lightweight Erlang process per link
- **Automatic path discovery** — builds and maintains routing tables
- **Multi-interface support** — TCP, Serial (RNode), AutoInterface; LoRa via RNode over serial
- **Transport mode** — full routing/forwarding for network backbone operation

### 📨 LXMF Relay
- **Store-and-forward** — propagates messages for offline peers
- **Priority queuing** — urgent messages get fast-path delivery
- **Message deduplication** — prevents relay storms
- **Delivery receipts** — tracks message propagation status
- **Configurable propagation** — TTL, max storage, priority rules

### 🌐 WebSocket Bridge
- **Phoenix WebSocket** — real-time event stream for web clients
- **REST API** — send messages, query status, manage interfaces
- **Authentication** — token-based API access with scoped permissions
- **Prometheus metrics** — `/metrics` endpoint for monitoring

### 🛡️ Fault Tolerance
- **OTP supervision trees** — any component crash is isolated and auto-recovered
- **Connection resilience** — automatic reconnection with exponential backoff
- **Hot code reloading** — upgrade without dropping links
- **Process isolation** — one link crash doesn't affect others

### 🍓 Nerves Deployment
- **Raspberry Pi firmware** — pre-built Nerves images for zero-config deployment
- **OTA updates** — push firmware updates over the network
- **Minimal footprint** — runs on Pi Zero 2W with 512MB RAM
- **Hardware support** — RNode serial (LoRa), USB adapters (via optional `circuits_uart`)

## Tech Stack

| Component       | Technology                           |
|-----------------|--------------------------------------|
| Language        | Elixir 1.17+                         |
| Framework       | Phoenix 1.7+                         |
| Runtime         | BEAM VM (Erlang/OTP 27+)             |
| Concurrency     | OTP GenServer, Supervisor, Task      |
| Crypto          | :crypto (Erlang), Ed25519, X25519    |
| Database        | ETS + DETS (in-memory + persistent)  |
| Embedded        | Nerves for Raspberry Pi              |
| Monitoring      | Prometheus, Telemetry                |

## Quick Start

### Prerequisites

- Elixir 1.17+
- Erlang/OTP 27+
- Rustler (for NIFs if needed)

> **Arch Linux / CachyOS note:** Arch-based distros split Erlang/OTP into many
> packages. Reticulum Link needs several that are not pulled in by the base
> `erlang` package. Install them explicitly:
>
> ```bash
> sudo pacman -S erlang-parsetools erlang-ssh erlang-tools erlang-os_mon
> ```
>
> Without these, `mix compile`/`mix test` fail with missing-application errors
> (`:parsetools`, `:ssh`, `:os_mon`, ...). On Debian/Ubuntu and asdf/mise
> installs, Erlang ships as one bundle and this step is unnecessary.

> **Interop tests:** the Python RNS compatibility tests
> (`test/interop/rns_compat_test.exs`) require the reference Reticulum
> implementation on your `PATH`:
>
> ```bash
> pip install rns
> ```
>
> Without it those 6 tests are marked invalid/skipped; the rest of the suite
> runs fine without Python.

### Installation

```bash
git clone https://github.com/synthalorian/reticulum-link.git
cd reticulum-link
mix deps.get
mix compile
```

### Running the test suite

```bash
MIX_ENV=test mix test        # 122 tests (includes Python RNS interop if `rns` is installed)
mix credo --strict           # lint: zero issues
mix format --check-formatted # formatting gate
mix dialyzer                 # static analysis (first run builds the PLT — slow)
```

### Benchmarks

```bash
mix run bench/link_bench.exs
```

Measures crypto throughput, link creation rate, memory per link (verified
~6.5 KB/link), LXMF storage throughput, and packet pack/unpack latency.
There is no dedicated `mix bench` task; the script runs the full app.

### Running

```bash
# Development
mix phx.server

# With interactive console
iex -S mix phx.server

# Production release
MIX_ENV=prod mix release
_build/prod/rel/reticulum_link/bin/reticulum_link start
```

### Nerves (Raspberry Pi)

```bash
# Build firmware for Raspberry Pi 4
export MIX_TARGET=rpi4
mix deps.get
mix firmware
mix firmware.burn  # Write to SD card
```

## Architecture

The application is structured as a set of OTP supervision trees:

```
ReticulumLink.Supervisor (top-level)
├── ReticulumLink.Transport.Supervisor
│   ├── ReticulumLink.Transport.LinkManager (GenServer)
│   ├── ReticulumLink.Transport.PathManager (GenServer)
│   ├── ReticulumLink.Transport.AnnounceHandler (GenServer)
│   └── ReticulumLink.Transport.InterfaceSupervisor
│       ├── Interface:TcpServer (DynamicSupervisor children)
│       └── Interface:Serial0 (RNode/LoRa via circuits_uart, optional)
├── ReticulumLink.Lxmf.Supervisor
│   ├── ReticulumLink.Lxmf.PropagationEngine (GenServer)
│   ├── ReticulumLink.Lxmf.MessageStore (GenServer, ETS-backed)
│   └── ReticulumLink.Lxmf.DeliveryTracker (GenServer)
├── ReticulumLink.Web.Endpoint (Phoenix)
├── ReticulumLink.Crypto.IdentityManager (GenServer)
└── ReticulumLink.Telemetry (Telemetry metrics)
```

Each link is an independent `GenServer` — if one crashes, others continue unaffected.

## Project Structure

```
reticulum-link/
├── config/              # Environment configs
├── lib/
│   ├── reticulum_link/
│   │   ├── transport/   # Reticulum protocol implementation
│   │   ├── lxmf/        # LXMF relay and propagation
│   │   ├── crypto/      # Identity, encryption, signing
│   │   └── web/         # Phoenix controllers, channels
│   └── reticulum_link.ex  # Application module
├── test/                # ExUnit tests
├── mix.exs              # Project definition
└── README.md
```

## License

Apache License 2.0 — see [LICENSE](LICENSE).

## Credits

Built by **synthalorian 🎹🤺** (synthalorian) with **synthclaw**.

---

## ☕ Support the Developer

If this project saved you time, solved a problem, or just made your day a little more neon, you can fuel the next one:

[![Buy Me A Coffee](https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png)](https://buymeacoffee.com/synthalorian)
