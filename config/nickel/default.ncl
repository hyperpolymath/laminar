# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors
#
# Laminar Default Configuration

let schema = import "schema.ncl" in

# Default production configuration
{
  laminar | schema.LaminarConfig = {
    version = "1.0.0",
    environment = "production",

    tiers = {
      tier1 = {
        path = "/mnt/laminar_tier1",
        type = "tmpfs",
        size = "2G",
        description = "RAM Capacitor - Volatile ingestion buffer",
      },
      tier2 = {
        path = "/mnt/laminar_tier2",
        type = "nvme",
        description = "NVMe Stage - Checkpoint for resume",
      },
    },

    rclone = {
      rc_url = "http://localhost:5572",
      timeout_ms = 60000,
      defaults = {
        transfers = 32,
        checkers = 64,
        multi_thread_streams = 8,
        multi_thread_cutoff = "64M",
        buffer_size = "128M",
        drive_chunk_size = "128M",
        tpslimit = 0,
        retries = 3,
        low_level_retries = 10,
        timeout = "5m",
        contimeout = "1m",
      },
    },

    pipeline = {
      express_concurrency = 32,
      ghost_concurrency = 16,
      compressed_concurrency = 8,
      converted_concurrency = 4,
      batch_size = 10,
      batch_timeout_ms = 5000,
    },

    intelligence = {
      ghost_link_threshold_bytes = 5368709120,  # 5GB
      massive_file_threshold_bytes = 50000000000,  # 50GB
      compression_threshold_bytes = 10000000,  # 10MB
      enabled_rulesets = ["default"],
    },

    web = {
      host = "localhost",
      port = 4000,
      cors_origins = ["*"],
      enable_graphiql = true,
    },

    network = {
      enable_bbr = true,
      tcp_rmem_max = 16777216,
      tcp_wmem_max = 16777216,
      enable_gro = true,
      disable_lro = true,
      interface = "eth0",
    },

    logging = {
      level = "info",
      format = "$time $metadata[$level] $message",
      enable_file_logging = false,
    },

    refinery = {
      enable_audio_conversion = true,
      enable_image_conversion = true,
      enable_compression = true,
      zstd_compression_level = 19,
      flac_compression_level = 8,
      webp_quality = 100,
    },
  },
}
