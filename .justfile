# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors
#
# Laminar: High-Velocity Cloud Streaming Relay
# The Comprehensive Command Centre
#
# Usage: just <recipe> [arguments...]
# Help:  just --list

set shell := ["bash", "-c"]
set dotenv-load := true
set positional-arguments := true

# =============================================================================
# VARIABLES & DEFAULTS
# =============================================================================

app_name := "laminar"
version := "1.0.0"

# Ports
rclone_port := env_var_or_default("RCLONE_PORT", "5572")
graphql_port := env_var_or_default("GRAPHQL_PORT", "4000")
metrics_port := env_var_or_default("METRICS_PORT", "9090")

# Paths
tier1_path := env_var_or_default("LAMINAR_TIER1", "/mnt/laminar_tier1")
tier2_path := env_var_or_default("LAMINAR_TIER2", "/mnt/laminar_tier2")
config_path := env_var_or_default("LAMINAR_CONFIG", "config")
log_path := env_var_or_default("LAMINAR_LOG", "/var/log/laminar")

# Container settings
container_name := env_var_or_default("CONTAINER_NAME", "laminar")
container_image := env_var_or_default("CONTAINER_IMAGE", "laminar-refinery")
container_runtime := env_var_or_default("CONTAINER_RUNTIME", "podman")

# Transfer defaults
default_transfers := "32"
default_checkers := "64"
default_buffer := "128M"
default_chunk := "128M"
default_streams := "8"
default_cutoff := "64M"
default_tpslimit := "0"
default_bwlimit := "off"

# =============================================================================
# META & HELP
# =============================================================================

# List all recipes (default)
@default:
    just --list --unsorted

# Show version and system info
@version:
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║  Laminar v{{version}} - High-Velocity Cloud Streaming Relay   ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "System: $(uname -s) $(uname -r)"
    echo "Container: $({{container_runtime}} --version 2>/dev/null || echo 'not installed')"
    echo "Elixir: $(elixir --version 2>/dev/null | head -1 || echo 'not installed')"
    echo "Rclone: $(rclone version 2>/dev/null | head -1 || echo 'not installed')"

# Show detailed help for a topic
@help topic="":
    #!/usr/bin/env bash
    case "{{topic}}" in
        "transfer"|"transfers")
            echo "Transfer Recipes:"
            echo "  just stream <src> <dst>           - Basic parallel transfer"
            echo "  just smart-stream <src> <dst>     - Filtered transfer"
            echo "  just sync <src> <dst>             - Mirror sync (deletes!)"
            echo "  just copy-* variants              - Specialized transfers"
            echo ""
            echo "Options (set via environment):"
            echo "  TRANSFERS=64 just stream ...      - Parallel file count"
            echo "  BWLIMIT=10M just stream ...       - Bandwidth limit"
            ;;
        "container"|"containers")
            echo "Container Recipes:"
            echo "  just build-relay                  - Minimal rclone container"
            echo "  just build-refinery               - Full container with ffmpeg"
            echo "  just build-distroless             - Google distroless variant"
            echo "  just up / just down               - Start/stop containers"
            ;;
        "config"|"configuration")
            echo "Configuration:"
            echo "  just setup-remotes                - Configure cloud remotes"
            echo "  just validate                     - Check configuration"
            echo "  just nickel-export                - Export Nickel config to JSON"
            ;;
        *)
            echo "Usage: just help <topic>"
            echo ""
            echo "Topics: transfer, container, config"
            ;;
    esac

# =============================================================================
# SETUP & INSTALLATION
# =============================================================================

# Full system setup
setup: setup-system setup-deps setup-tiered-cache setup-config
    @echo ":: Setup complete! Run 'just setup-remotes' to configure cloud providers."

# Check and report system dependencies
@setup-system:
    echo ":: Checking system dependencies..."
    command -v {{container_runtime}} >/dev/null && echo "✓ {{container_runtime}}" || echo "✗ {{container_runtime}} (required)"
    command -v just >/dev/null && echo "✓ just" || echo "✗ just (required)"
    command -v rclone >/dev/null && echo "✓ rclone" || echo "✗ rclone (optional - runs in container)"
    command -v elixir >/dev/null && echo "✓ elixir" || echo "✗ elixir (optional - for control plane)"
    command -v nickel >/dev/null && echo "✓ nickel" || echo "✗ nickel (optional - for config)"
    command -v curl >/dev/null && echo "✓ curl" || echo "✗ curl (required)"
    echo ""
    echo "For Fedora: sudo dnf install podman just curl"
    echo "For Ubuntu: sudo apt install podman just curl"

# Install Elixir dependencies
setup-deps:
    @echo ":: Installing Elixir dependencies..."
    cd apps/laminar_web && mix local.hex --force --if-missing
    cd apps/laminar_web && mix local.rebar --force --if-missing
    cd apps/laminar_web && mix deps.get

# Install only production dependencies
setup-deps-prod:
    @echo ":: Installing production dependencies..."
    cd apps/laminar_web && MIX_ENV=prod mix deps.get --only prod

# Create tiered cache architecture
setup-tiered-cache size="2G":
    @echo ":: Creating Tiered Cache Architecture..."
    sudo mkdir -p {{tier1_path}} {{tier2_path}}
    @echo ":: Mounting Tier 1 (RAM Capacitor - {{size}})..."
    @mountpoint -q {{tier1_path}} || sudo mount -t tmpfs -o size={{size}},mode=0700 tmpfs {{tier1_path}}
    @echo ":: Tier 2 (NVMe Stage) ready at {{tier2_path}}"
    chmod 700 {{tier2_path}} 2>/dev/null || sudo chmod 700 {{tier2_path}}

# Create configuration directory structure
setup-config:
    @echo ":: Setting up configuration..."
    mkdir -p {{config_path}}/rclone {{config_path}}/nickel
    @test -f {{config_path}}/rclone/rclone.conf || echo "# Run 'just setup-remotes' to configure" > {{config_path}}/rclone/rclone.conf
    @test -f .env || just _generate-env

# Generate environment file
@_generate-env:
    echo ":: Generating .env file..."
    cat > .env << 'ENVEOF'
    # Laminar Environment Configuration
    export LAMINAR_TIER1={{tier1_path}}
    export LAMINAR_TIER2={{tier2_path}}
    export RCLONE_RC_URL=http://localhost:{{rclone_port}}
    export MIX_ENV=prod
    export SECRET_KEY_BASE=$(head -c 64 /dev/urandom | base64 | tr -d '\n')
    ENVEOF

# Configure Rclone remotes (interactive)
setup-remotes:
    @echo ":: Configuring cloud remotes..."
    @echo ":: This will launch an interactive wizard."
    rclone config --config {{config_path}}/rclone/rclone.conf

# Configure a specific remote type
setup-remote-dropbox:
    rclone config create dropbox dropbox --config {{config_path}}/rclone/rclone.conf

setup-remote-gdrive:
    rclone config create gdrive drive scope=drive --config {{config_path}}/rclone/rclone.conf

setup-remote-s3 access_key secret_key region="us-east-1":
    rclone config create s3 s3 provider=AWS access_key_id={{access_key}} secret_access_key={{secret_key}} region={{region}} --config {{config_path}}/rclone/rclone.conf

setup-remote-b2 account key:
    rclone config create b2 b2 account={{account}} key={{key}} --config {{config_path}}/rclone/rclone.conf

setup-remote-sftp host user:
    rclone config create sftp sftp host={{host}} user={{user}} --config {{config_path}}/rclone/rclone.conf

# =============================================================================
# BUILD RECIPES
# =============================================================================

# Build all containers
build-all: build-refinery build-relay
    @echo ":: All containers built successfully."

# Build Refinery container (full - Rclone + FFmpeg + ImageMagick)
build-refinery:
    @echo ":: Building Laminar Refinery Container..."
    {{container_runtime}} build -t laminar-refinery -f containers/Containerfile.refinery containers/

# Build minimal Relay container (Rclone only)
build-relay:
    @echo ":: Building Laminar Relay Container..."
    {{container_runtime}} build -t laminar-relay -f containers/Containerfile.relay containers/

# Build distroless variant (smallest)
build-distroless:
    @echo ":: Building Distroless Container..."
    {{container_runtime}} build -t laminar-distroless -f containers/Containerfile.distroless containers/

# Build with custom base image
build-custom base_image:
    @echo ":: Building with base image {{base_image}}..."
    {{container_runtime}} build -t laminar-custom --build-arg BASE_IMAGE={{base_image}} -f containers/Containerfile.refinery containers/

# Build Elixir application
build-logic:
    @echo ":: Compiling Elixir Intelligence..."
    cd apps/laminar_web && MIX_ENV=prod mix compile

# Build release
build-release:
    @echo ":: Building production release..."
    cd apps/laminar_web && MIX_ENV=prod mix release

# Multi-arch build
build-multiarch platforms="linux/amd64,linux/arm64":
    @echo ":: Building multi-architecture images..."
    {{container_runtime}} buildx build --platform {{platforms}} -t laminar-refinery -f containers/Containerfile.refinery containers/

# =============================================================================
# CONTAINER MANAGEMENT
# =============================================================================

# Start Refinery container (default)
up: up-refinery

# Start minimal Relay container
up-relay auth="":
    @echo ":: Starting Laminar Relay..."
    {{container_runtime}} run -d --name {{container_name}}-relay \
        --network host \
        -v $(pwd)/{{config_path}}/rclone:/config/rclone:Z \
        laminar-relay \
        rcd --rc-web-gui --rc-addr :{{rclone_port}} \
        {{auth}} \
        --rc-serve

# Start Refinery container with full features
up-refinery auth="--rc-no-auth":
    @echo ":: Starting Laminar Refinery..."
    {{container_runtime}} run -d --name {{container_name}} \
        --network host \
        -v {{tier1_path}}:/cache/ram:Z \
        -v {{tier2_path}}:/cache/nvme:Z \
        -v $(pwd)/{{config_path}}/rclone:/config/rclone:Z \
        {{container_image}} \
        rcd --rc-web-gui --rc-addr :{{rclone_port}} {{auth}} \
        --cache-dir /cache/ram \
        --vfs-cache-mode full \
        --vfs-cache-max-size 1500M

# Start with authentication
up-auth user pass: (up-refinery ("--rc-user " + user + " --rc-pass " + pass))

# Start in foreground (for debugging)
up-fg:
    @echo ":: Starting Laminar in foreground..."
    {{container_runtime}} run --rm --name {{container_name}} \
        --network host \
        -v {{tier1_path}}:/cache/ram:Z \
        -v {{tier2_path}}:/cache/nvme:Z \
        -v $(pwd)/{{config_path}}/rclone:/config/rclone:Z \
        {{container_image}} \
        rcd --rc-web-gui --rc-addr :{{rclone_port}} --rc-no-auth

# Stop containers
down:
    @echo ":: Stopping Laminar..."
    -{{container_runtime}} stop {{container_name}} {{container_name}}-relay 2>/dev/null
    -{{container_runtime}} rm {{container_name}} {{container_name}}-relay 2>/dev/null

# Restart containers
restart: down up

# View container logs
logs lines="100":
    {{container_runtime}} logs -f --tail {{lines}} {{container_name}} 2>/dev/null || \
    {{container_runtime}} logs -f --tail {{lines}} {{container_name}}-relay 2>/dev/null

# Execute command in container
exec +cmd:
    {{container_runtime}} exec -it {{container_name}} {{cmd}}

# Open shell in container
shell:
    {{container_runtime}} exec -it {{container_name}} /bin/sh

# =============================================================================
# ELIXIR CONTROL PLANE
# =============================================================================

# Start the control plane
start-brain:
    @echo ":: Starting Elixir Control Plane..."
    cd apps/laminar_web && iex -S mix phx.server

# Start control plane in background
start-brain-bg:
    @echo ":: Starting Control Plane (background)..."
    cd apps/laminar_web && elixir --detached -S mix phx.server

# Start in development mode
start-dev:
    cd apps/laminar_web && MIX_ENV=dev iex -S mix phx.server

# Start with observer (GUI debugging)
start-observer:
    cd apps/laminar_web && iex -S mix run -e ":observer.start()"

# =============================================================================
# TRANSFER OPERATIONS - BASIC
# =============================================================================

# Basic parallel stream
stream src dst transfers=default_transfers buffer=default_buffer:
    @echo ":: Laminar Stream: {{src}} -> {{dst}}"
    {{container_runtime}} exec -it {{container_name}} rclone copy "{{src}}" "{{dst}}" \
        --transfers {{transfers}} \
        --buffer-size {{buffer}} \
        --use-mmap \
        --stats 1s \
        --progress

# Smart stream with filtering
smart-stream src dst:
    @echo ":: Smart Stream: {{src}} -> {{dst}}"
    {{container_runtime}} exec -it {{container_name}} rclone copy "{{src}}" "{{dst}}" \
        --transfers {{default_transfers}} \
        --checkers {{default_checkers}} \
        --fast-list \
        --tpslimit 10 \
        --filter-from /config/rclone/filters.txt \
        --track-renames \
        --checksum \
        --use-mmap \
        --stats 1s \
        --progress

# Sync (mirror with deletes)
sync src dst:
    @echo ":: WARNING: Sync will DELETE files in destination not in source!"
    @echo ":: Syncing: {{src}} -> {{dst}}"
    {{container_runtime}} exec -it {{container_name}} rclone sync "{{src}}" "{{dst}}" \
        --transfers {{default_transfers}} \
        --checkers {{default_checkers}} \
        --fast-list \
        --filter-from /config/rclone/filters.txt \
        --checksum \
        --progress

# Move (transfer then delete source)
move src dst:
    @echo ":: Moving: {{src}} -> {{dst}}"
    {{container_runtime}} exec -it {{container_name}} rclone move "{{src}}" "{{dst}}" \
        --transfers {{default_transfers}} \
        --checkers {{default_checkers}} \
        --checksum \
        --progress

# =============================================================================
# TRANSFER OPERATIONS - ADVANCED
# =============================================================================

# High-bandwidth transfer (1Gbps+)
copy-fast src dst:
    @echo ":: High-Bandwidth Transfer: {{src}} -> {{dst}}"
    {{container_runtime}} exec -it {{container_name}} rclone copy "{{src}}" "{{dst}}" \
        --transfers 64 \
        --checkers 128 \
        --multi-thread-streams 16 \
        --buffer-size 256M \
        --drive-chunk-size 256M \
        --use-mmap \
        --fast-list \
        --progress

# Extreme parallelism (10Gbps+)
copy-extreme src dst:
    @echo ":: Extreme Transfer: {{src}} -> {{dst}}"
    {{container_runtime}} exec -it {{container_name}} rclone copy "{{src}}" "{{dst}}" \
        --transfers 128 \
        --checkers 256 \
        --multi-thread-streams 32 \
        --buffer-size 512M \
        --drive-chunk-size 512M \
        --use-mmap \
        --fast-list \
        --progress

# Low-bandwidth transfer (<10Mbps)
copy-slow src dst bwlimit="5M":
    @echo ":: Low-Bandwidth Transfer: {{src}} -> {{dst}}"
    {{container_runtime}} exec -it {{container_name}} rclone copy "{{src}}" "{{dst}}" \
        --transfers 4 \
        --checkers 8 \
        --buffer-size 32M \
        --bwlimit {{bwlimit}} \
        --retries 10 \
        --low-level-retries 20 \
        --progress

# Mobile/metered connection
copy-mobile src dst:
    @echo ":: Mobile Transfer: {{src}} -> {{dst}}"
    {{container_runtime}} exec -it {{container_name}} rclone copy "{{src}}" "{{dst}}" \
        --transfers 2 \
        --checkers 4 \
        --buffer-size 16M \
        --bwlimit 2M \
        --progress

# Large files (multi-threaded chunks)
copy-large src dst:
    @echo ":: Large File Transfer: {{src}} -> {{dst}}"
    {{container_runtime}} exec -it {{container_name}} rclone copy "{{src}}" "{{dst}}" \
        --transfers 8 \
        --multi-thread-streams 32 \
        --multi-thread-cutoff 100M \
        --buffer-size 512M \
        --drive-chunk-size 512M \
        --progress

# Many small files
copy-small-files src dst:
    @echo ":: Small Files Transfer: {{src}} -> {{dst}}"
    {{container_runtime}} exec -it {{container_name}} rclone copy "{{src}}" "{{dst}}" \
        --transfers 64 \
        --checkers 128 \
        --buffer-size 16M \
        --fast-list \
        --progress

# With checksum verification
copy-verified src dst:
    @echo ":: Verified Transfer: {{src}} -> {{dst}}"
    {{container_runtime}} exec -it {{container_name}} rclone copy "{{src}}" "{{dst}}" \
        --transfers {{default_transfers}} \
        --checksum \
        --progress

# Dry run (preview)
copy-dry src dst:
    @echo ":: Dry Run: {{src}} -> {{dst}}"
    {{container_runtime}} exec -it {{container_name}} rclone copy "{{src}}" "{{dst}}" \
        --dry-run \
        -v

# =============================================================================
# TRANSFER OPERATIONS - FILTERED
# =============================================================================

# Photos only
copy-photos src dst:
    {{container_runtime}} exec -it {{container_name}} rclone copy "{{src}}" "{{dst}}" \
        --transfers 16 \
        --include "*.jpg" --include "*.jpeg" --include "*.png" \
        --include "*.gif" --include "*.webp" --include "*.heic" \
        --progress

# Videos only
copy-videos src dst:
    {{container_runtime}} exec -it {{container_name}} rclone copy "{{src}}" "{{dst}}" \
        --transfers 8 \
        --multi-thread-streams 16 \
        --include "*.mp4" --include "*.mkv" --include "*.avi" \
        --include "*.mov" --include "*.webm" --include "*.m4v" \
        --progress

# Documents only
copy-docs src dst:
    {{container_runtime}} exec -it {{container_name}} rclone copy "{{src}}" "{{dst}}" \
        --transfers 32 \
        --include "*.pdf" --include "*.doc" --include "*.docx" \
        --include "*.xls" --include "*.xlsx" --include "*.ppt" \
        --include "*.pptx" --include "*.txt" --include "*.md" \
        --progress

# Code only (no artifacts)
copy-code src dst:
    {{container_runtime}} exec -it {{container_name}} rclone copy "{{src}}" "{{dst}}" \
        --transfers 32 \
        --filter-from /config/rclone/filters.txt \
        --progress

# Exclude by size
copy-small src dst max_size="100M":
    {{container_runtime}} exec -it {{container_name}} rclone copy "{{src}}" "{{dst}}" \
        --max-size {{max_size}} \
        --progress

copy-large-only src dst min_size="1G":
    {{container_runtime}} exec -it {{container_name}} rclone copy "{{src}}" "{{dst}}" \
        --min-size {{min_size}} \
        --progress

# Recent files
copy-recent src dst days="7":
    {{container_runtime}} exec -it {{container_name}} rclone copy "{{src}}" "{{dst}}" \
        --max-age {{days}}d \
        --progress

# Old files
copy-old src dst days="365":
    {{container_runtime}} exec -it {{container_name}} rclone copy "{{src}}" "{{dst}}" \
        --min-age {{days}}d \
        --progress

# =============================================================================
# TRANSFER OPERATIONS - WITH PARAMETERS
# =============================================================================

# Fully customizable transfer
transfer src dst transfers=default_transfers checkers=default_checkers buffer=default_buffer streams=default_streams bwlimit=default_bwlimit checksum="false" filter="":
    @echo ":: Custom Transfer: {{src}} -> {{dst}}"
    {{container_runtime}} exec -it {{container_name}} rclone copy "{{src}}" "{{dst}}" \
        --transfers {{transfers}} \
        --checkers {{checkers}} \
        --buffer-size {{buffer}} \
        --multi-thread-streams {{streams}} \
        $([ "{{bwlimit}}" != "off" ] && echo "--bwlimit {{bwlimit}}") \
        $([ "{{checksum}}" = "true" ] && echo "--checksum") \
        $([ -n "{{filter}}" ] && echo "--filter-from {{filter}}") \
        --progress

# Batch transfer from file list
transfer-batch list_file dst:
    @echo ":: Batch Transfer from {{list_file}}"
    {{container_runtime}} exec -it {{container_name}} rclone copy --files-from {{list_file}} "{{dst}}" \
        --transfers {{default_transfers}} \
        --progress

# =============================================================================
# RCLONE OPERATIONS
# =============================================================================

# List remotes
remotes:
    {{container_runtime}} exec {{container_name}} rclone listremotes 2>/dev/null || rclone listremotes

# List files
ls remote path="":
    {{container_runtime}} exec {{container_name}} rclone ls "{{remote}}{{path}}"

# List files with details
lsl remote path="":
    {{container_runtime}} exec {{container_name}} rclone lsl "{{remote}}{{path}}"

# List directories
lsd remote path="":
    {{container_runtime}} exec {{container_name}} rclone lsd "{{remote}}{{path}}"

# Tree view
tree remote path="" depth="2":
    {{container_runtime}} exec {{container_name}} rclone tree "{{remote}}{{path}}" --level {{depth}}

# Get size
size remote path="":
    {{container_runtime}} exec {{container_name}} rclone size "{{remote}}{{path}}"

# Get info about remote
about remote:
    {{container_runtime}} exec {{container_name}} rclone about "{{remote}}"

# Check files match
check src dst:
    {{container_runtime}} exec {{container_name}} rclone check "{{src}}" "{{dst}}" --one-way

# Delete file
delete remote path:
    {{container_runtime}} exec {{container_name}} rclone deletefile "{{remote}}{{path}}"

# Delete directory
rmdir remote path:
    {{container_runtime}} exec {{container_name}} rclone purge "{{remote}}{{path}}"

# Create directory
mkdir remote path:
    {{container_runtime}} exec {{container_name}} rclone mkdir "{{remote}}{{path}}"

# =============================================================================
# JOB MANAGEMENT
# =============================================================================

# Show active jobs
jobs:
    {{container_runtime}} exec {{container_name}} rclone rc job/list 2>/dev/null || echo "No relay running"

# Job status
job-status id:
    {{container_runtime}} exec {{container_name}} rclone rc job/status jobid={{id}}

# Stop job
job-stop id:
    {{container_runtime}} exec {{container_name}} rclone rc job/stop jobid={{id}}

# Stop all jobs
jobs-stop-all:
    {{container_runtime}} exec {{container_name}} rclone rc job/stopgroup group=transfer

# =============================================================================
# BANDWIDTH & RESOURCE CONTROL
# =============================================================================

# Set bandwidth limit
bwlimit rate:
    {{container_runtime}} exec {{container_name}} rclone rc core/bwlimit rate={{rate}}

# Remove bandwidth limit
bwlimit-off:
    {{container_runtime}} exec {{container_name}} rclone rc core/bwlimit rate=off

# Get current stats
stats:
    {{container_runtime}} exec {{container_name}} rclone rc core/stats

# Reset stats
stats-reset:
    {{container_runtime}} exec {{container_name}} rclone rc core/stats-reset

# Memory stats
memstats:
    {{container_runtime}} exec {{container_name}} rclone rc core/memstats

# Trigger GC
gc:
    {{container_runtime}} exec {{container_name}} rclone rc debug/set-gc-percent gc_percent=100

# =============================================================================
# HEALTH & MONITORING
# =============================================================================

# Quick health check
@health:
    curl -sf http://localhost:{{rclone_port}}/ >/dev/null && echo "✓ Relay: HEALTHY" || echo "✗ Relay: DOWN"
    curl -sf http://localhost:{{graphql_port}}/api/v1/health >/dev/null 2>&1 && echo "✓ Control Plane: HEALTHY" || echo "○ Control Plane: NOT RUNNING"

# Detailed health check
health-detailed:
    @echo "=== Rclone Relay ==="
    curl -s http://localhost:{{rclone_port}}/core/version 2>/dev/null | jq . || echo "Not available"
    @echo ""
    @echo "=== Memory ==="
    curl -s http://localhost:{{rclone_port}}/core/memstats 2>/dev/null | jq '.HeapAlloc, .Sys' || echo "Not available"
    @echo ""
    @echo "=== Active Transfers ==="
    curl -s http://localhost:{{rclone_port}}/core/stats 2>/dev/null | jq '.transferring // []' || echo "Not available"

# Watch stats in real-time
watch-stats interval="2":
    watch -n {{interval}} "curl -s http://localhost:{{rclone_port}}/core/stats | jq -c '.bytes, .speed, .transfers'"

# =============================================================================
# NETWORK PHYSICS
# =============================================================================

# Apply all network optimizations
tune-network: tune-bbr tune-buffers tune-offload
    @echo ":: Network physics applied."

# Enable TCP BBR
tune-bbr:
    @echo ":: Enabling TCP BBR..."
    sudo modprobe tcp_bbr 2>/dev/null || true
    echo "net.core.default_qdisc = fq" | sudo tee /etc/sysctl.d/99-laminar-bbr.conf
    echo "net.ipv4.tcp_congestion_control = bbr" | sudo tee -a /etc/sysctl.d/99-laminar-bbr.conf
    sudo sysctl -p /etc/sysctl.d/99-laminar-bbr.conf

# Tune TCP buffers
tune-buffers size="16777216":
    @echo ":: Tuning TCP buffers ({{size}})..."
    echo "net.core.rmem_max = {{size}}" | sudo tee /etc/sysctl.d/99-laminar-buffers.conf
    echo "net.core.wmem_max = {{size}}" | sudo tee -a /etc/sysctl.d/99-laminar-buffers.conf
    echo "net.ipv4.tcp_rmem = 4096 87380 {{size}}" | sudo tee -a /etc/sysctl.d/99-laminar-buffers.conf
    echo "net.ipv4.tcp_wmem = 4096 87380 {{size}}" | sudo tee -a /etc/sysctl.d/99-laminar-buffers.conf
    sudo sysctl -p /etc/sysctl.d/99-laminar-buffers.conf

# Tune NIC offload
tune-offload interface="eth0":
    @echo ":: Tuning {{interface}} offload..."
    sudo ethtool -K {{interface}} gro on 2>/dev/null || echo "GRO not available"
    sudo ethtool -K {{interface}} lro off 2>/dev/null || echo "LRO already off"

# Check network config
check-network:
    @echo "=== Congestion Control ==="
    sysctl net.ipv4.tcp_congestion_control
    @echo ""
    @echo "=== Buffer Sizes ==="
    sysctl net.core.rmem_max net.core.wmem_max
    @echo ""
    @echo "=== Available Algorithms ==="
    cat /proc/sys/net/ipv4/tcp_available_congestion_control

# =============================================================================
# NICKEL CONFIGURATION
# =============================================================================

# Export Nickel config to JSON
nickel-export output="config/config.generated.json":
    @echo ":: Exporting Nickel configuration..."
    nickel export {{config_path}}/nickel/default.ncl > {{output}}

# Validate Nickel config
nickel-check:
    @echo ":: Validating Nickel configuration..."
    nickel typecheck {{config_path}}/nickel/default.ncl
    nickel typecheck {{config_path}}/nickel/profiles.ncl

# Show Nickel config
nickel-show:
    nickel eval {{config_path}}/nickel/default.ncl | jq .

# =============================================================================
# DEVELOPMENT
# =============================================================================

# Run all tests
test:
    cd apps/laminar_web && mix test

# Run specific test
test-file file:
    cd apps/laminar_web && mix test {{file}}

# Run tests with coverage
test-cover:
    cd apps/laminar_web && mix test --cover

# Watch tests
test-watch:
    cd apps/laminar_web && mix test.watch

# Format code
format:
    cd apps/laminar_web && mix format

# Check formatting
format-check:
    cd apps/laminar_web && mix format --check-formatted

# Lint
lint:
    cd apps/laminar_web && mix credo --strict

# Dialyzer
dialyzer:
    cd apps/laminar_web && mix dialyzer

# All checks
check: format-check lint test
    @echo ":: All checks passed!"

# Generate docs
docs:
    cd apps/laminar_web && mix docs

# Interactive shell
iex:
    cd apps/laminar_web && iex -S mix

# =============================================================================
# CLEANUP
# =============================================================================

# Clean build artifacts
clean:
    @echo ":: Cleaning..."
    cd apps/laminar_web && mix clean 2>/dev/null || true
    rm -rf apps/laminar_web/_build apps/laminar_web/deps

# Clean containers
clean-containers:
    @echo ":: Removing containers..."
    -{{container_runtime}} rmi laminar-refinery laminar-relay laminar-distroless 2>/dev/null

# Clean cache
clean-cache:
    @echo ":: Cleaning cache..."
    sudo rm -rf {{tier1_path}}/* {{tier2_path}}/* 2>/dev/null || true

# Clean everything
clean-all: down clean clean-containers clean-cache
    @echo ":: Full cleanup complete."

# Unmount RAM disk
unmount-cache:
    sudo umount {{tier1_path}} 2>/dev/null || echo "Not mounted"

# =============================================================================
# UTILITIES
# =============================================================================

# Validate all configuration
validate:
    @echo ":: Validating configuration..."
    @test -f {{config_path}}/rclone/rclone.conf && echo "✓ rclone.conf" || echo "✗ rclone.conf MISSING"
    @test -s {{config_path}}/rclone/rclone.conf && echo "  (has content)" || echo "  (empty - run 'just setup-remotes')"
    @test -f containers/rclone/filters.txt && echo "✓ filters.txt" || echo "✗ filters.txt MISSING"
    @test -f .env && echo "✓ .env" || echo "○ .env (optional)"

# Show cache usage
cache-usage:
    @echo "=== Tier 1 (RAM) ==="
    df -h {{tier1_path}} 2>/dev/null || echo "Not mounted"
    @echo ""
    @echo "=== Tier 2 (NVMe) ==="
    du -sh {{tier2_path}} 2>/dev/null || echo "Not available"

# Generate completions
completions shell="bash":
    @just --completions {{shell}}

# Benchmark transfer
benchmark src dst:
    @echo ":: Benchmarking transfer..."
    time {{container_runtime}} exec {{container_name}} rclone copy "{{src}}" "{{dst}}" \
        --transfers {{default_transfers}} \
        --stats-one-line \
        --stats 1s

# Encrypt config
encrypt-config password:
    rclone config show --config {{config_path}}/rclone/rclone.conf | \
    openssl enc -aes-256-cbc -pbkdf2 -pass pass:{{password}} > {{config_path}}/rclone/rclone.conf.enc

# =============================================================================
# QUICK RECIPES (Aliases)
# =============================================================================

# Quick aliases
alias s := stream
alias ss := smart-stream
alias h := health
alias st := status
alias j := jobs
alias l := logs
alias r := restart

# =============================================================================
# PROFILES (Pre-configured Scenarios)
# =============================================================================

# Run with profile
profile-high-bandwidth src dst: (copy-fast src dst)
profile-low-bandwidth src dst: (copy-slow src dst "5M")
profile-mobile src dst: (copy-mobile src dst)
profile-photos src dst: (copy-photos src dst)
profile-videos src dst: (copy-videos src dst)
profile-code src dst: (copy-code src dst)
