# Multi-stage build for Reticulum Link
# Stage 1: Build
FROM hexpm/elixir:1.17.3-erlang-27.2-debian-bookworm-20250101 AS builder

WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install Hex and Rebar
RUN mix local.hex --force && mix local.rebar --force

# Set build environment
ENV MIX_ENV=prod

# Copy dependency files first for layer caching
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

# Copy source code
COPY lib lib
COPY config config

# Compile and build release
RUN mix compile
RUN mix release

# Stage 2: Runtime
FROM debian:bookworm-slim AS runtime

WORKDIR /app

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -r reticulum && useradd -r -g reticulum reticulum

# Copy release from builder
COPY --from=builder /app/_build/prod/rel/reticulum_link .

# Create data directory
RUN mkdir -p /var/lib/reticulum-link && chown reticulum:reticulum /var/lib/reticulum-link

# Switch to non-root user
USER reticulum

# Expose ports (HTTP API + TCP transport)
EXPOSE 4000 4242

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD /app/bin/reticulum_link rpc "ReticulumLink.Web.HealthController.process_alive? ReticulumLink.Crypto.IdentityManager" || exit 1

# Start the release
CMD ["/app/bin/reticulum_link", "start"]
