# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors
#
# Laminar: High-Velocity Cloud Streaming Relay
# The Command Centre

set shell := ["bash", "-c"]
set dotenv-load := true

# =============================================================================
# VARIABLES
# =============================================================================

app_name := "laminar"
rclone_port := "5572"
graphql_port := "4000"
tier1_path := env_var_or_default("LAMINAR_TIER1", "/mnt/laminar_tier1")
tier2_path := env_var_or_default("LAMINAR_TIER2", "/mnt/laminar_tier2")

# =============================================================================
# META
# =============================================================================

# List all available recipes
default:
    @just --list --unsorted

# Show version information
version:
    @echo "Laminar v1.0.0 - High-Velocity Cloud Streaming Relay"

# =============================================================================
# SETUP & DEPENDENCIES
# =============================================================================

# Install system dependencies (Fedora/Kinoite)
setup-system:
    @echo ":: Checking system dependencies..."
    @command -v podman >/dev/null || echo "Missing: podman"
    @command -v just >/dev/null || echo "Missing: just"
    @command -v elixir >/dev/null || echo "Missing: elixir"
    @echo ":: For Fedora Kinoite, run: rpm-ostree install podman just elixir erlang git"

# Install Elixir dependencies
setup-deps:
    @echo ":: Installing Elixir dependencies..."
    cd apps/laminar_web && mix local.hex --force && mix local.rebar --force
    cd apps/laminar_web && mix deps.get

# Configure Rclone remotes (interactive)
setup-remotes:
    @echo ":: Configuring cloud remotes..."
    rclone config

# Create tiered cache architecture
setup-tiered-cache:
    @echo ":: Creating Tiered Cache Architecture..."
    sudo mkdir -p {{tier1_path}}
    sudo mkdir -p {{tier2_path}}
    @echo ":: Mounting Tier 1 (RAM Capacitor - 2GB)..."
    @mountpoint -q {{tier1_path}} || sudo mount -t tmpfs -o size=2G,mode=0700 tmpfs {{tier1_path}}
    @echo ":: Tier 2 (NVMe Stage) ready at {{tier2_path}}"
    @echo "export LAMINAR_TIER1={{tier1_path}}" > .env
    @echo "export LAMINAR_TIER2={{tier2_path}}" >> .env
    @echo "export MIX_ENV=prod" >> .env

# Full setup sequence
setup: setup-system setup-deps setup-tiered-cache
    @echo ":: Setup complete. Run 'just setup-remotes' to configure cloud providers."

# =============================================================================
# BUILD PHASE
# =============================================================================

# Build the Refinery Container (Rclone + FFmpeg + ImageMagick)
build-refinery:
    @echo ":: Building Laminar Refinery Container..."
    podman build -t laminar-refinery -f containers/Containerfile.refinery containers/

# Build minimal relay container (Rclone only)
build-relay:
    @echo ":: Building Laminar Relay Container..."
    podman build -t laminar-relay -f containers/Containerfile.relay containers/

# Compile the Elixir Logic Engine
build-logic:
    @echo ":: Compiling Elixir Intelligence..."
    cd apps/laminar_web && MIX_ENV=prod mix deps.get --only prod
    cd apps/laminar_web && MIX_ENV=prod mix compile

# Build everything
build-all: build-refinery build-logic
    @echo ":: All components built successfully."

# =============================================================================
# NETWORK PHYSICS (HOST TUNING)
# =============================================================================

# Apply Laminar Hydrodynamics (Network Tuning)
tune-network:
    @echo ":: Applying Laminar Hydrodynamics..."
    @echo ":: Enabling TCP BBR (Flow Control)..."
    sudo modprobe tcp_bbr || true
    @echo "net.core.default_qdisc = fq" | sudo tee -a /etc/sysctl.d/99-laminar.conf
    @echo "net.ipv4.tcp_congestion_control = bbr" | sudo tee -a /etc/sysctl.d/99-laminar.conf
    @echo ":: Maximizing TCP Buffers (Pipe Width)..."
    @echo "net.core.rmem_max = 16777216" | sudo tee -a /etc/sysctl.d/99-laminar.conf
    @echo "net.core.wmem_max = 16777216" | sudo tee -a /etc/sysctl.d/99-laminar.conf
    @echo "net.ipv4.tcp_rmem = 4096 87380 16777216" | sudo tee -a /etc/sysctl.d/99-laminar.conf
    @echo "net.ipv4.tcp_wmem = 4096 87380 16777216" | sudo tee -a /etc/sysctl.d/99-laminar.conf
    @echo ":: Tuning Coalescence (GRO on, LRO off)..."
    sudo ethtool -K eth0 gro on 2>/dev/null || echo "GRO not supported or eth0 not found"
    sudo ethtool -K eth0 lro off 2>/dev/null || echo "LRO already off or eth0 not found"
    @echo ":: Applying sysctl changes..."
    sudo sysctl -p /etc/sysctl.d/99-laminar.conf || true
    @echo ":: Laminar network physics applied."

# Verify network tuning
check-network:
    @echo ":: Network Physics Status:"
    @sysctl net.ipv4.tcp_congestion_control || true
    @sysctl net.core.rmem_max || true
    @ethtool -k eth0 2>/dev/null | grep -E "(gro|lro)" || echo "Cannot query eth0"

# =============================================================================
# DEPLOY PHASE
# =============================================================================

# Start the Rclone relay (basic)
up-relay:
    @echo ":: Starting Laminar Relay..."
    podman run -d --name laminar-relay \
        --network host \
        -v $(pwd)/config/rclone:/config/rclone:Z \
        laminar-relay \
        rcd --rc-web-gui --rc-addr :{{rclone_port}} --rc-no-auth --rc-serve

# Start the Refinery relay with caching
up-refinery:
    @echo ":: Starting Laminar Refinery..."
    podman run -d --name laminar \
        --network host \
        --env-file .env \
        -v {{tier1_path}}:/cache/ram:Z \
        -v {{tier2_path}}:/cache/nvme:Z \
        -v $(pwd)/config/rclone:/config/rclone:Z \
        laminar-refinery \
        rcd --rc-web-gui --rc-addr :{{rclone_port}} --rc-no-auth \
        --cache-dir /cache/ram \
        --vfs-cache-mode full \
        --vfs-cache-max-size 1500M

# Alias for up-refinery
up: up-refinery

# Start the Elixir Control Plane
start-brain:
    @echo ":: Starting Elixir Control Plane..."
    cd apps/laminar_web && iex -S mix phx.server

# Stop all services
down:
    @echo ":: Stopping Laminar services..."
    podman stop laminar 2>/dev/null || podman stop laminar-relay 2>/dev/null || true
    podman rm laminar 2>/dev/null || podman rm laminar-relay 2>/dev/null || true

# Restart services
restart: down up

# =============================================================================
# THE LAMINAR FLOW (TRANSFER OPERATIONS)
# =============================================================================

# Direct stream (basic)
stream source dest:
    @echo ":: Starting Laminar Flow: {{source}} -> {{dest}}"
    podman exec -it laminar rclone copy {{source}} {{dest}} \
        --transfers 32 \
        --multi-thread-streams 8 \
        --buffer-size 128M \
        --drive-chunk-size 128M \
        --use-mmap \
        --stats 1s \
        --progress

# Smart stream with filtering and latency optimization
smart-stream source dest:
    @echo ":: Starting Smart Laminar Stream..."
    @echo ":: Source: {{source}} -> Dest: {{dest}}"
    podman exec -it laminar rclone copy {{source}} {{dest}} \
        --transfers 32 \
        --checkers 64 \
        --fast-list \
        --tpslimit 10 \
        --filter-from /config/rclone/filters.txt \
        --track-renames \
        --checksum \
        --use-mmap \
        --progress

# BitTorrent-logic stream (maximum parallelism)
torrent-stream source dest:
    @echo ":: Initiating Parallel Stream (BitTorrent Logic)..."
    podman exec -it laminar rclone copy {{source}} {{dest}} \
        --transfers 32 \
        --multi-thread-streams 8 \
        --multi-thread-cutoff 64M \
        --buffer-size 128M \
        --drive-chunk-size 128M \
        --checksum \
        --progress

# Sync (mirror with deletes)
sync source dest:
    @echo ":: Synchronizing {{source}} -> {{dest}}"
    podman exec -it laminar rclone sync {{source}} {{dest}} \
        --transfers 32 \
        --fast-list \
        --filter-from /config/rclone/filters.txt \
        --checksum \
        --progress

# =============================================================================
# OPERATIONS & MONITORING
# =============================================================================

# Check transfer status
status:
    @podman exec laminar rclone rc core/stats 2>/dev/null || \
     podman exec laminar-relay rclone rc core/stats 2>/dev/null || \
     echo "No relay running"

# View logs
logs:
    podman logs -f laminar 2>/dev/null || podman logs -f laminar-relay 2>/dev/null

# List configured remotes
remotes:
    podman exec laminar rclone listremotes 2>/dev/null || \
    podman exec laminar-relay rclone listremotes 2>/dev/null || \
    rclone listremotes

# Check relay health
health:
    @curl -s http://localhost:{{rclone_port}}/ >/dev/null && echo ":: Relay: HEALTHY" || echo ":: Relay: DOWN"

# Show active jobs
jobs:
    podman exec laminar rclone rc job/list 2>/dev/null || echo "No relay running"

# Stop a specific job
stop-job id:
    podman exec laminar rclone rc job/stop jobid={{id}}

# =============================================================================
# DEVELOPMENT
# =============================================================================

# Run Elixir tests
test:
    cd apps/laminar_web && mix test

# Run specific test file
test-file file:
    cd apps/laminar_web && mix test {{file}}

# Format Elixir code
format:
    cd apps/laminar_web && mix format

# Run linter
lint:
    cd apps/laminar_web && mix credo --strict

# Generate documentation
docs:
    cd apps/laminar_web && mix docs

# Interactive Elixir shell
iex:
    cd apps/laminar_web && iex -S mix

# =============================================================================
# CLEANUP
# =============================================================================

# Clean build artifacts
clean:
    @echo ":: Cleaning build artifacts..."
    cd apps/laminar_web && mix clean
    podman rmi laminar-refinery 2>/dev/null || true
    podman rmi laminar-relay 2>/dev/null || true

# Clean everything including dependencies
clean-all: clean
    cd apps/laminar_web && rm -rf deps _build

# Unmount RAM disk
unmount-cache:
    @echo ":: Unmounting Tier 1 cache..."
    sudo umount {{tier1_path}} 2>/dev/null || echo "Not mounted"

# =============================================================================
# UTILITIES
# =============================================================================

# Generate shell completions
completions shell="bash":
    @just --completions {{shell}}

# Validate configuration
validate:
    @echo ":: Validating configuration..."
    @test -f config/rclone/rclone.conf && echo ":: rclone.conf: OK" || echo ":: rclone.conf: MISSING"
    @test -f config/filters.txt && echo ":: filters.txt: OK" || echo ":: filters.txt: MISSING"
    @test -f .env && echo ":: .env: OK" || echo ":: .env: MISSING"

# Show disk usage of caches
cache-usage:
    @echo ":: Tier 1 (RAM):"
    @df -h {{tier1_path}} 2>/dev/null || echo "Not mounted"
    @echo ":: Tier 2 (NVMe):"
    @du -sh {{tier2_path}} 2>/dev/null || echo "Not available"
