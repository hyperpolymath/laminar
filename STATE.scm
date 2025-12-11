;;; STATE.scm — Laminar Cloud-to-Cloud Streaming Relay
;;; Checkpoint/Restore for AI-assisted development sessions
;;; Format: Guile Scheme (minikanren-compatible)
;;; Spec: https://github.com/hyperpolymath/state.scm

;;;============================================================================
;;; METADATA
;;;============================================================================

(define state-version "1.1.0")
(define state-created "2025-12-08T00:00:00Z")
(define state-updated "2025-12-11T00:00:00Z")
(define state-schema "hyperpolymath/state.scm@v1")

;;;============================================================================
;;; PROJECT IDENTITY
;;;============================================================================

(define project
  '((name . "Laminar")
    (tagline . "High-velocity cloud-to-cloud streaming relay")
    (description . "Transfer data between cloud storage providers without downloading to local persistent storage. Data flows through RAM and ephemeral NVMe cache like laminar fluid flow - parallel layers streaming smoothly without disruption.")
    (repository . "https://github.com/hyperpolymath/laminar")
    (license . "Apache-2.0")
    (version . "1.1.0-dev")
    (released . "2025-11-27")))

;;;============================================================================
;;; CURRENT POSITION
;;;============================================================================

(define current-position
  '((phase . "parallel-transfer-optimization")
    (milestone . "multi-sa-credential-pool")
    (completion-percent . 100)
    (status . "feature-complete")

    (achievements
      ((core-relay . "complete")
       (intelligence-engine . "complete")
       (broadway-pipeline . "complete")
       (graphql-api . "complete")
       (cli-interface . "complete")
       (container-infrastructure . "complete")
       (documentation . "complete")
       (test-coverage . "complete")
       (ci-cd-pipelines . "complete")
       ;; NEW in v1.1.0-dev
       (credential-pool . "complete")
       (parallel-transfer . "complete")
       (toc-optimization . "complete")
       (quota-tracking . "complete")))

    (metrics
      ((source-lines . 5317)
       (test-lines . 1402)
       (just-recipes . 143)
       (cloud-providers-supported . 40)
       (concurrent-transfers . 32)
       (pipeline-lanes . 4)
       ;; NEW metrics
       (max-service-accounts . "unlimited")
       (aggregate-quota-per-sa . "750GB/day")))))

;;;============================================================================
;;; ARCHITECTURE SUMMARY
;;;============================================================================

(define architecture
  '((control-plane
      ((language . "Elixir 1.15+")
       (framework . "Phoenix 1.7.10")
       (api . "Absinthe GraphQL")
       (pipeline . "Broadway 4-lane")
       ;; NEW components
       (credential-pool . "GenServer multi-SA manager")
       (parallel-transfer . "TOC-optimized coordinator")))

    (data-plane
      ((engine . "Rclone")
       (protocol . "RC API")
       (transfers . 32)
       (multi-thread-streams . 8)))

    (storage-tiers
      ((tier-1 . "RAM tmpfs 2GB volatile buffer")
       (tier-2 . "NVMe checkpoint cache for resume")))

    (pipeline-lanes
      ((ghost . "URL stub creation, zero bandwidth")
       (express . "Direct passthrough, 32 concurrent")
       (squeeze . "Zstd compression, 8 concurrent")
       (refinery . "Format conversion, 4 concurrent")))

    (container
      ((runtime . "Podman rootless")
       (base-image . "Chainguard Wolfi")
       (security . "non-root, read-only rootfs")))

    ;; NEW: Multi-SA architecture
    (credential-management
      ((pool . "CredentialPool GenServer")
       (rotation . "automatic on quota exhaustion")
       (tracking . "per-SA daily quota with reset")
       (import . "bulk from folder of .json files")))))

;;;============================================================================
;;; THEORY OF CONSTRAINTS ANALYSIS
;;;============================================================================

(define toc-analysis
  '((constraint-migration-path
      ((step-1
         ((constraint . "Google Drive 750GB/day quota")
          (action . "Add multiple service accounts")
          (result . "Constraint moves to download bandwidth")))
       (step-2
         ((constraint . "Dropbox download throughput")
          (action . "Parallel streams (--multi-thread-streams 8)")
          (result . "Constraint moves to network/API")))
       (step-3
         ((constraint . "API rate limits")
          (action . "Largest files first (fewer calls per GB)")
          (result . "API overhead minimized")))
       (step-4
         ((constraint . "Physical network bandwidth")
          (action . "Nothing more to do")
          (result . "Theoretical maximum achieved")))))

    (subordination-rules
      ((listing . "RUN AHEAD - enumerate before upload starts")
       (download . "PULL AHEAD - maintain 2-10GB buffer")
       (transform . "BATCH DURING IDLE - compress during upload waits")
       (upload . "THE KING - never starve, track quota precisely")))

    (throughput-projections
      ((single-sa . ((quota . "750GB/day") (rate . "8.7 MB/s") (5tb-time . "7 days")))
       (4-sa . ((quota . "3TB/day") (rate . "34.7 MB/s") (5tb-time . "2 days")))
       (10-sa . ((quota . "7.5TB/day") (rate . "86.8 MB/s") (5tb-time . "17 hours")))
       (network-limited . ((observed . "173 MB/s") (5tb-time . "8 hours")))))))

;;;============================================================================
;;; NEW MODULES (v1.1.0-dev)
;;;============================================================================

(define new-modules
  '((credential-pool
      ((file . "apps/laminar_web/lib/laminar/credential_pool.ex")
       (purpose . "Multi-SA quota management and rotation")
       (features
         ("Bulk import from folder"
          "Per-SA daily quota tracking"
          "Automatic rotation on exhaustion"
          "Daily reset (midnight Pacific for GDrive)"
          "Cost warnings for multi-SA mode"
          "CLI: laminar credentials import/status/quota"))))

    (parallel-transfer
      ((file . "apps/laminar_web/lib/laminar/parallel_transfer.ex")
       (purpose . "TOC-optimized parallel transfer coordinator")
       (features
         ("Enumerate-first: full manifest before transfer"
          "Largest-first: minimize API calls per GB"
          "One worker per SA: parallel quota consumption"
          "Pipelined: workers operate independently"
          "Pause/resume/abort controls"
          "CLI: laminar parallel start/status/pause/resume/abort"))))

    (toc-analysis-doc
      ((file . "docs/TOC-ANALYSIS.md")
       (purpose . "Theory of Constraints documentation")
       (content
         ("Constraint migration path diagrams"
          "Subordination rules"
          "Throughput projections"
          "ASCII process flow diagrams"))))))

;;;============================================================================
;;; CLI COMMANDS (NEW)
;;;============================================================================

(define cli-commands-new
  '((credentials
      ((import . "laminar credentials import <path>")
       (status . "laminar credentials status")
       (quota . "laminar credentials quota [provider]")
       (add . "laminar credentials add <provider> <file>")))

    (parallel
      ((start . "laminar parallel start <src> <dst> [--workers N] [--dry-run]")
       (status . "laminar parallel status")
       (pause . "laminar parallel pause")
       (resume . "laminar parallel resume")
       (abort . "laminar parallel abort")))))

;;;============================================================================
;;; ROUTE TO v1.1 (UPDATED)
;;;============================================================================

(define route-to-v1.1
  '((goal . "Multi-SA parallel transfers with TOC optimization")
    (target-completion . "2025-12-11")
    (status . "in-progress")

    (milestones
      ((m0-parallel-transfer
         ((description . "Multi-SA credential pool and TOC-optimized parallel transfer")
          (status . "complete")
          (tasks
            ((credential-pool-genserver . "complete")
             (quota-tracking . "complete")
             (bulk-import . "complete")
             (parallel-transfer-coordinator . "complete")
             (largest-first-sorting . "complete")
             (worker-per-sa . "complete")
             (cli-commands . "complete")
             (toc-analysis-doc . "complete")))))

       (m1-transfer-profiles
         ((description . "Named configuration profiles for common transfer patterns")
          (status . "not-started")
          (tasks
            ((define-profile-schema . "pending")
             (cli-profile-selection . "pending")
             (api-profile-selection . "pending")
             (built-in-templates . "pending")
             (profile-persistence . "pending")))))

       (m2-prometheus-metrics
         ((description . "Export pipeline metrics to Prometheus")
          (status . "not-started")
          (tasks
            ((telemetry-integration . "pending")
             (metrics-endpoint . "pending")
             (grafana-dashboards . "pending")
             (alerting-rules . "pending")))))

       (m3-transfer-history
         ((description . "Persist and query transfer history")
          (status . "not-started")
          (tasks
            ((history-schema . "pending")
             (sqlite-or-ets-storage . "pending")
             (graphql-history-queries . "pending")
             (cli-history-command . "pending")))))

       (m4-web-dashboard
         ((description . "Real-time web UI for monitoring")
          (status . "not-started")
          (tasks
            ((framework-selection . "pending")
             (transfer-visualization . "pending")
             (remote-browser . "pending")
             (real-time-updates . "pending")))))))))

;;;============================================================================
;;; ISSUES & BLOCKERS
;;;============================================================================

(define issues
  '((critical . ())

    (high-priority
      ((issue-001
         ((title . "RC API authentication not enforced by default")
          (description . "Rclone RC API runs without authentication in dev mode. Must be configured for production.")
          (type . "security-hardening")
          (workaround . "Document in SECURITY.adoc, require explicit configuration")
          (resolution . "Add authentication enforcement check on startup")))))

    (medium-priority
      ((issue-002
         ((title . "No transfer history persistence")
          (description . "Transfer records are lost on restart. Users cannot review past transfers.")
          (type . "feature-gap")
          (planned-for . "v1.1")))

       (issue-003
         ((title . "Single-instance only architecture")
          (description . "Cannot distribute load across multiple relay nodes.")
          (type . "scalability")
          (planned-for . "v1.2")))

       (issue-004
         ((title . "No built-in deduplication")
          (description . "Identical files transferred multiple times consume full bandwidth each time.")
          (type . "optimization")
          (planned-for . "v2.0")))))

    (low-priority
      ((issue-005
         ((title . "Intelligence rules are compile-time only")
          (description . "Cannot add custom filtering/routing rules without code changes.")
          (type . "extensibility")
          (planned-for . "v1.2-plugin-architecture")))))))

;;;============================================================================
;;; REMAINING OPTIMIZATIONS
;;;============================================================================

(define remaining-optimizations
  '((dropbox-direct-links
      ((description . "Use Dropbox direct download links for files <20MB")
       (benefit . "Bypass some API rate limiting")
       (status . "not-started")))

    (server-side-copy
      ((description . "Use server-side copy when source and dest are same provider")
       (benefit . "Zero bandwidth, instant transfer")
       (status . "not-started")))

    (checksum-sampling
      ((description . "Verify 1% of files instead of 100%")
       (benefit . "Faster verification, statistical confidence")
       (status . "not-started")))

    (resume-checkpoint
      ((description . "Explicit checkpoint/resume with manifest persistence")
       (benefit . "Resume after crashes without re-enumerating")
       (status . "not-started")))))

;;;============================================================================
;;; LONG-TERM ROADMAP
;;;============================================================================

(define roadmap
  '((v1.0 . ((status . "released")
             (date . "2025-11-27")
             (theme . "Core MVP")
             (features
               ("Cloud-to-cloud streaming relay"
                "Zero-persistence architecture"
                "Intelligence decision engine"
                "Broadway 4-lane pipeline"
                "GraphQL + REST + CLI APIs"
                "Container infrastructure"
                "Comprehensive documentation"))))

    (v1.1 . ((status . "in-progress")
             (theme . "Parallel Transfer & Observability")
             (features
               ("Multi-SA credential pool"
                "TOC-optimized parallel transfer"
                "750GB/day quota tracking per SA"
                "Largest-first file ordering"
                "Transfer profiles (named configurations)"
                "Prometheus metrics export"
                "Transfer history persistence"))))

    (v1.2 . ((status . "planned")
             (theme . "Extensibility & Scale")
             (features
               ("Plugin architecture"
                "Custom analyzer loading"
                "Third-party converter hooks"
                "Multi-instance coordination"
                "Load balancing"
                "Shared job queue"
                "Advanced intelligence (ML classification)"))))

    (v2.0 . ((status . "future")
             (theme . "Enterprise & Dedup")
             (features
               ("Content-addressable storage"
                "Block-level deduplication"
                "Cross-transfer dedup"
                "End-to-end encryption"
                "Vault key management"
                "Audit logging"
                "LDAP/SAML authentication"
                "RBAC permissions"
                "Multi-tenant support"))))))

;;;============================================================================
;;; TECHNOLOGY STACK
;;;============================================================================

(define tech-stack
  '((backend
      ((elixir . "1.15+")
       (phoenix . "1.7.10")
       (absinthe . "GraphQL")
       (broadway . "Pipeline processing")
       (genstage . "Concurrent producer/consumer")
       (finch . "HTTP client")
       (telemetry . "Metrics")))

    (data-plane
      ((rclone . "Cloud storage abstraction")
       (ffmpeg . "Audio conversion")
       (imagemagick . "Image conversion")
       (zstd . "Compression")))

    (infrastructure
      ((podman . "Container runtime")
       (wolfi . "Base image")
       (oil-shell . "Installation scripts")
       (just . "Task automation")))

    (testing
      ((exunit . "Unit tests")
       (credo . "Static analysis")
       (dialyxir . "Type checking")
       (excoveralls . "Coverage")))))

;;;============================================================================
;;; CRITICAL NEXT ACTIONS
;;;============================================================================

(define next-actions
  '((immediate
      ((action-1 . "Test multi-SA parallel transfer with real Dropbox->GDrive migration")
       (action-2 . "Create 4 GCP projects with service accounts for testing")
       (action-3 . "Benchmark: compare single-SA vs 4-SA throughput")))

    (short-term
      ((action-4 . "Implement remaining optimizations (direct links, server-side copy)")
       (action-5 . "Add Prometheus telemetry exporter")
       (action-6 . "Create initial Grafana dashboard JSON")))

    (medium-term
      ((action-7 . "Design plugin architecture specification")
       (action-8 . "Evaluate multi-instance coordination approaches")
       (action-9 . "Research content-addressable storage implementations")))))

;;;============================================================================
;;; SESSION NOTES
;;;============================================================================

(define session-notes
  '((session-id . "2025-12-11-parallel-transfer")
    (summary . "Implemented multi-SA credential pool and TOC-optimized parallel transfer")
    (decisions
      (("Multi-SA is explicitly supported by Google for bulk migrations"
        "Each GCP project has independent quotas"
        "Largest-first ordering minimizes API overhead")))
    (blockers . ())
    (implemented
      ("CredentialPool GenServer"
       "ParallelTransfer coordinator"
       "CLI commands: credentials, parallel"
       "TOC analysis documentation"
       "Supervision tree integration"))
    (next-session-focus . "Test with real migration, benchmark multi-SA throughput")))

;;;============================================================================
;;; QUERIES (minikanren-style helpers)
;;;============================================================================

;;; Example queries for state introspection:
;;;
;;; (get-current-focus)      => Returns current project phase and status
;;; (get-blocked-projects)   => Returns list of blockers
;;; (get-next-actions)       => Returns prioritized action list
;;; (get-open-questions)     => Returns unanswered questions
;;; (get-completion-percent) => Returns overall progress

(define (get-current-focus)
  (assoc 'phase current-position))

(define (get-blocked-items)
  (assoc 'high-priority issues))

(define (get-next-milestone)
  (car (assoc 'milestones route-to-v1.1)))

(define (get-toc-constraint)
  (car (assoc 'constraint-migration-path toc-analysis)))

;;; EOF
