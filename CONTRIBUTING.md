# Contributing to Reticulum Link

Thanks for your interest in contributing! This project is a high-performance Reticulum transport node and LXMF relay built on the BEAM VM.

## Development Setup

```bash
# Clone
git clone https://github.com/synthalorian/reticulum-link.git
cd reticulum-link

# Install dependencies
mix deps.get

# Run tests
mix test

# Run code quality checks
mix credo --strict
mix dialyzer
```

## Project Structure

```
lib/reticulum_link/
  crypto/          # Ed25519, X25519, AES-256-GCM, HKDF
  transport/       # Packet, header, destination, link, path management
  lxmf/            # Message store, propagation engine, delivery tracking
  web/             # Phoenix REST API and WebSocket channels
  telemetry.ex     # Observability and metrics
```

## Testing

- All new code must include ExUnit tests
- Run the full suite: `mix test`
- Property-based tests use StreamData where applicable

## Code Style

- Follow Elixir community conventions
- Run `mix format` before committing
- Credo strict mode must pass: `mix credo --strict`

## Pull Request Process

1. Fork the repo and create a feature branch
2. Add tests for any new functionality
3. Ensure CI passes (tests, credo, dialyzer)
4. Update CHANGELOG.md under the `[Unreleased]` section
5. Submit PR with a clear description of changes

## Communication

- Open an issue for bugs or feature requests
- PRs are the preferred way to submit changes
