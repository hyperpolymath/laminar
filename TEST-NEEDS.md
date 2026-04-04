# TEST-NEEDS.md — laminar

## CRG Grade: C — ACHIEVED 2026-04-04

> Generated 2026-03-29 by punishing audit.

## Current State

| Category     | Count | Notes |
|-------------|-------|-------|
| Unit tests   | 7     | cli, ghost_linker, intelligence, pipeline, rclone_client, refinery, schema |
| Integration  | 1     | transfer_test.exs |
| E2E          | 0     | None |
| Benchmarks   | 0     | None |

**Source modules:** ~1119 Elixir source files (including deps in tree). Own modules estimated at ~40-60 in apps/laminar_web/lib/ covering pipeline, intelligence, ghost_linker, refinery, rclone_client, CLI, schema, transfers.

## What's Missing

### P2P (Property-Based) Tests
- [ ] Pipeline processing: property tests for data transformation invariants
- [ ] Ghost linker: link resolution property tests
- [ ] Refinery: data cleaning/transformation property tests
- [ ] Schema: arbitrary schema validation

### E2E Tests
- [ ] Full pipeline: ingest -> process -> refine -> output
- [ ] Transfer lifecycle: initiate -> progress -> complete/rollback
- [ ] Intelligence: analysis request -> processing -> result delivery
- [ ] CLI: full command execution round-trips

### Aspect Tests
- **Security:** No tests for transfer authentication, data sanitization in pipeline, rclone credential handling
- **Performance:** No throughput benchmarks for pipeline stages, no transfer speed measurements
- **Concurrency:** No tests for parallel pipeline execution, concurrent transfers, GenServer contention
- **Error handling:** No tests for rclone failure, pipeline stage crash, interrupted transfers, malformed input

### Build & Execution
- [ ] `mix test` verification
- [ ] Zig FFI test (if applicable)
- [ ] Container build + smoke test

### Benchmarks Needed
- [ ] Pipeline stage throughput
- [ ] Transfer speed vs file size
- [ ] Intelligence analysis latency
- [ ] Refinery processing rate
- [ ] Ghost linker resolution speed

### Self-Tests
- [ ] Pipeline configuration self-validation
- [ ] rclone connectivity health check
- [ ] Schema migration verification

## Priority

**CRITICAL.** 8 test files for what appears to be a substantial data pipeline application. Pipeline processing — the core function — has 1 test. No benchmarks for a data transfer tool is a major gap. No concurrency tests for a system that inherently processes data in parallel is negligent.

## FAKE-FUZZ ALERT

- `tests/fuzz/placeholder.txt` is a scorecard placeholder inherited from rsr-template-repo — it does NOT provide real fuzz testing
- Replace with an actual fuzz harness (see rsr-template-repo/tests/fuzz/README.adoc) or remove the file
- Priority: P2 — creates false impression of fuzz coverage
