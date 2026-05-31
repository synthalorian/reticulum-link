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
    ║      │   TCP    │    │   LoRa     │    │  Serial    │         ║
    ║      │  Server  │    │   Radio    │    │  RNode     │         ║
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
- **Multi-interface support** — TCP, LoRa, Serial, AutoInterface
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
- **Hardware support** — RNode serial, LoRa HATs, USB adapters

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

### Installation

```bash
git clone https://github.com/synthalorian/reticulum-link.git
cd reticulum-link
mix deps.get
mix compile
```

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
│       ├── Interface:Serial0
│       └── Interface:LoRa0
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

Built by **synth** (synthalorian) with **synthshark**.
