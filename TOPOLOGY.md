<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- TOPOLOGY.md — Project architecture map and completion dashboard -->
<!-- Last updated: 2026-02-19 -->

# Laminar — Project Topology

## System Architecture

```
                        ┌─────────────────────────────────────────┐
                        │              OPERATOR / ADMIN           │
                        │        (GraphQL API, CLI, Dashboard)    │
                        └───────────────────┬─────────────────────┘
                                            │
                                            ▼
                        ┌─────────────────────────────────────────┐
                        │           ELIXIR CONTROL PLANE          │
                        │    (Phoenix, Absinthe, Orchestration)    │
                        └──────────┬───────────────────┬──────────┘
                                   │                   │
                                   ▼                   ▼
                        ┌───────────────────────┐  ┌────────────────────────────────┐
                        │ STORAGE TIERS (CACHE) │  │ RCLONE DATA PLANE              │
                        │ - RAM Buffer (Tier 1) │  │ - Parallel Streaming           │
                        │ - NVMe Stage (Tier 2) │  │ - Content-Aware Routing        │
                        └──────────┬────────────┘  └──────────┬─────────────────────┘
                                   │                          │
                                   └────────────┬─────────────┘
                                                ▼
                        ┌─────────────────────────────────────────┐
                        │           EXTERNAL CLOUD APIS           │
                        │  ┌───────────┐  ┌───────────┐  ┌───────┐│
                        │  │ Dropbox   │──► LAMINAR   │──► GDrive ││
                        │  │ (Source)  │  │ RELAY     │  │ (Dest) ││
                        │  └───────────┘  └───────────┘  └───────┘│
                        └─────────────────────────────────────────┘

                        ┌─────────────────────────────────────────┐
                        │          REPO INFRASTRUCTURE            │
                        │  Justfile Automation  .machine_readable/  │
                        │  Wolfi Containers     0-AI-MANIFEST.a2ml  │
                        └─────────────────────────────────────────┘
```

## Completion Dashboard

```
COMPONENT                          STATUS              NOTES
─────────────────────────────────  ──────────────────  ─────────────────────────────────
CORE RELAY
  Rclone Engine (Data Plane)        ██████████ 100%    Parallel streaming stable
  RAM/NVMe Storage Tiers            ██████████ 100%    Volatile caching verified
  Refinery Pipeline                 ████████░░  80%    Format conversion refining
  Control Plane (Elixir)            ██████████ 100%    GraphQL API stable

NETWORK & INFRA
  TCP BBR Tuning                    ██████████ 100%    Throughput optimized
  Podman / Wolfi build              ██████████ 100%    Reproducible containers
  Network Physics (GRO/LRO)         ██████████ 100%    Container safety verified

REPO INFRASTRUCTURE
  Justfile Automation               ██████████ 100%    Standard build/tune/up
  .machine_readable/                ██████████ 100%    STATE tracking active
  Cookbook Documentation            ██████████ 100%    Comprehensive tuning guide

─────────────────────────────────────────────────────────────────────────────
OVERALL:                            █████████░  ~95%   Production-ready cloud relay
```

## Key Dependencies

```
Network Tuning ───► Rclone Engine ──────► RAM Buffer ──────► Cloud Sync
     │                 │                   │                 │
     ▼                 ▼                   ▼                 ▼
Elixir Brain ───► Stream Control ────► NVMe Stage ────► Integrity Check
```

## Update Protocol

This file is maintained by both humans and AI agents. When updating:

1. **After completing a component**: Change its bar and percentage
2. **After adding a component**: Add a new row in the appropriate section
3. **After architectural changes**: Update the ASCII diagram
4. **Date**: Update the `Last updated` comment at the top of this file

Progress bars use: `█` (filled) and `░` (empty), 10 characters wide.
Percentages: 0%, 10%, 20%, ... 100% (in 10% increments).
