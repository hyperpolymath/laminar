# CLAUDE.md — Laminar AI Assistant Context

## Project Overview

**Laminar** is a high-velocity cloud-to-cloud streaming relay written in Elixir/Phoenix. It transfers data between cloud storage providers (Dropbox, Google Drive, S3, etc.) without downloading to local persistent storage—data flows through RAM and ephemeral NVMe cache like laminar fluid flow.

## Quick Start for AI Assistants

```bash
# Read the full project state
cat STATE.scm

# Key files to understand the architecture
apps/laminar_web/lib/laminar/
├── credential_pool.ex     # Multi-SA quota management
├── parallel_transfer.ex   # TOC-optimized transfer coordinator
├── intelligence.ex        # File routing decision engine
├── pipeline.ex            # Broadway 4-lane processor
├── rclone_client.ex       # Rclone RC API client
├── cli.ex                 # Command-line interface
└── ghost_linker.ex        # URL stub creation for large files
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     LAMINAR ARCHITECTURE                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  CONTROL PLANE (Elixir/Phoenix)                                │
│  ├── GraphQL API (Absinthe)                                    │
│  ├── CLI Interface                                             │
│  ├── Intelligence Engine (file routing)                        │
│  ├── Broadway Pipeline (4-lane: ghost/express/squeeze/refine)  │
│  ├── CredentialPool (multi-SA quota management)        [NEW]   │
│  └── ParallelTransfer (TOC-optimized coordinator)      [NEW]   │
│                                                                 │
│  DATA PLANE (Rclone)                                           │
│  ├── RC API (HTTP JSON-RPC)                                    │
│  ├── 40+ cloud providers                                       │
│  └── Multi-thread streams (8 per large file)                   │
│                                                                 │
│  STORAGE TIERS                                                 │
│  ├── Tier 1: RAM tmpfs (2GB volatile buffer)                   │
│  └── Tier 2: NVMe checkpoint cache (resume capability)         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Current Focus: Multi-SA Parallel Transfer

The latest work implements **Theory of Constraints (TOC)** optimization for bulk migrations:

### The Problem
- Google Drive has a **750GB/day upload limit** per service account
- Single SA = 7 days for 5TB migration
- API overhead accumulates with many small files

### The Solution
1. **CredentialPool**: Manage multiple service accounts with automatic rotation
2. **ParallelTransfer**: TOC-optimized coordinator with workers per SA
3. **Largest-first ordering**: Minimize API calls per GB transferred

### Throughput Projections
| Config | Daily Quota | 5TB Time |
|--------|-------------|----------|
| 1 SA   | 750 GB/day  | 7 days   |
| 4 SAs  | 3 TB/day    | 2 days   |
| 10 SAs | 7.5 TB/day  | 17 hours |

## Key CLI Commands

```bash
# Credential management
laminar credentials import /path/to/service-accounts/
laminar credentials status
laminar credentials quota

# Parallel transfer (TOC-optimized)
laminar parallel start dropbox: gdrive:backup
laminar parallel status
laminar parallel pause/resume/abort

# Standard operations
laminar stream <source> <destination>
laminar ls <remote:path>
laminar health
```

## Theory of Constraints Summary

```
CONSTRAINT MIGRATION PATH:
═══════════════════════════════════════════════════════════════

Step 1: Single SA → Upload quota is constraint
        Action: Add more service accounts
        Result: Constraint moves to download

Step 2: Multi-SA → Download is constraint
        Action: Parallel streams (--multi-thread-streams 8)
        Result: Constraint moves to API/network

Step 3: Parallel streams → API overhead is constraint
        Action: Largest files first (fewer calls per GB)
        Result: API overhead minimized

Step 4: Optimized → Network bandwidth is constraint
        Action: Nothing more to do (physics limit)
        Result: Theoretical maximum achieved
```

## Important Design Decisions

1. **Multi-SA is Google-approved**: Service account rotation is a documented pattern for bulk migrations
2. **Enumerate-first**: Build complete file manifest before starting any transfers
3. **Largest-first**: Process big files first to minimize API call overhead
4. **One worker per SA**: Each service account gets dedicated worker for quota tracking
5. **Subordination**: Everything serves the constraint (upload quota initially, then network)

## File Locations

| Component | Path |
|-----------|------|
| CredentialPool | `apps/laminar_web/lib/laminar/credential_pool.ex` |
| ParallelTransfer | `apps/laminar_web/lib/laminar/parallel_transfer.ex` |
| TOC Analysis | `docs/TOC-ANALYSIS.md` |
| CLI | `apps/laminar_web/lib/laminar/cli.ex` |
| State | `STATE.scm` |
| Supervision | `apps/laminar_web/lib/laminar_web/application.ex` |

## Remaining Optimizations

- [ ] Dropbox direct download links (files <20MB)
- [ ] Server-side copy (same provider)
- [ ] Checksum sampling (1% verification)
- [ ] Explicit checkpoint/resume with manifest persistence

## Testing Multi-SA

```bash
# 1. Create service accounts in GCP Console
# 2. Download .json credential files
# 3. Import them
laminar credentials import ~/.config/laminar/credentials/

# 4. Verify
laminar credentials status

# 5. Run parallel transfer
laminar parallel start dropbox: gdrive:backup --dry-run
laminar parallel start dropbox: gdrive:backup
```

## Code Style

- Elixir with Phoenix conventions
- Pattern matching for control flow (see `intelligence.ex`)
- GenServer for stateful components
- Broadway for pipeline processing
- Rclone RC API for data plane operations

## Common Tasks

### Add a new CLI command
1. Edit `cli.ex`
2. Add to `run_command/3` dispatch
3. Implement `cmd_<name>/2` and `do_<action>/2` functions
4. Add help text

### Add a new GenServer
1. Create module in `apps/laminar_web/lib/laminar/`
2. Add to supervision tree in `application.ex`
3. Define public API with `@spec`
4. Implement callbacks

### Modify transfer behavior
1. Check `intelligence.ex` for file routing rules
2. Check `pipeline.ex` for processing stages
3. Check `parallel_transfer.ex` for TOC coordination
