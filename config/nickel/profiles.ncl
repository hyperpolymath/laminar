# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors
#
# Laminar Transfer Profiles
# Pre-configured settings for common scenarios

let schema = import "schema.ncl" in
let default = import "default.ncl" in

# =============================================================================
# TRANSFER PROFILE TYPE
# =============================================================================

let TransferProfile = {
  name | String,
  description | String,
  source | String | optional,
  destination | String | optional,

  # Rclone overrides
  transfers | schema.PositiveInt | optional,
  checkers | schema.PositiveInt | optional,
  multi_thread_streams | schema.PositiveInt | optional,
  buffer_size | schema.ByteSize | optional,
  bwlimit | String | optional,

  # Filter mode
  filter_mode | String | default = "code_clean",
  custom_filter_file | String | optional,

  # Feature flags
  use_checksum | Bool | default = true,
  track_renames | Bool | default = false,
  fast_list | Bool | default = true,

  # Intelligence overrides
  enable_ghost_links | Bool | default = true,
  enable_conversion | Bool | default = true,
  enable_compression | Bool | default = true,
} in

# =============================================================================
# PREDEFINED PROFILES
# =============================================================================

{
  profiles = {

    # -------------------------------------------------------------------------
    # HIGH BANDWIDTH PROFILES
    # -------------------------------------------------------------------------

    high_bandwidth | TransferProfile = {
      name = "high_bandwidth",
      description = "Maximum throughput for fast connections (1Gbps+)",
      transfers = 64,
      checkers = 128,
      multi_thread_streams = 16,
      buffer_size = "256M",
      filter_mode = "code_clean",
      use_checksum = true,
      fast_list = true,
    },

    extreme | TransferProfile = {
      name = "extreme",
      description = "Absolute maximum parallelism (10Gbps+, powerful CPU)",
      transfers = 128,
      checkers = 256,
      multi_thread_streams = 32,
      buffer_size = "512M",
      filter_mode = "code_clean",
      use_checksum = false,  # Skip for speed
      fast_list = true,
    },

    # -------------------------------------------------------------------------
    # LOW BANDWIDTH PROFILES
    # -------------------------------------------------------------------------

    low_bandwidth | TransferProfile = {
      name = "low_bandwidth",
      description = "Conservative settings for slow connections (<10Mbps)",
      transfers = 4,
      checkers = 8,
      multi_thread_streams = 2,
      buffer_size = "32M",
      bwlimit = "5M",
      filter_mode = "code_clean",
      use_checksum = true,
    },

    mobile | TransferProfile = {
      name = "mobile",
      description = "Mobile tethering or metered connections",
      transfers = 2,
      checkers = 4,
      multi_thread_streams = 1,
      buffer_size = "16M",
      bwlimit = "2M",
      filter_mode = "code_clean",
      enable_conversion = true,  # Compress to save data
      enable_compression = true,
    },

    # -------------------------------------------------------------------------
    # USE CASE PROFILES
    # -------------------------------------------------------------------------

    photos | TransferProfile = {
      name = "photos",
      description = "Photo library backup (skip RAW, keep metadata)",
      transfers = 16,
      filter_mode = "smart",
      use_checksum = true,
      track_renames = true,
      enable_ghost_links = false,  # Photos should transfer fully
      enable_conversion = false,    # Preserve original formats
    },

    code_backup | TransferProfile = {
      name = "code_backup",
      description = "Source code backup (exclude artifacts)",
      transfers = 32,
      checkers = 64,
      filter_mode = "code_clean",
      use_checksum = true,
      fast_list = true,
      enable_ghost_links = true,
      enable_conversion = false,  # Keep source files as-is
    },

    video_archive | TransferProfile = {
      name = "video_archive",
      description = "Large video archive (ghost links for huge files)",
      transfers = 8,
      multi_thread_streams = 16,
      buffer_size = "256M",
      filter_mode = "smart",
      enable_ghost_links = true,
      enable_conversion = false,  # Videos already compressed
    },

    documents | TransferProfile = {
      name = "documents",
      description = "Office documents and PDFs",
      transfers = 32,
      filter_mode = "smart",
      use_checksum = true,
      enable_ghost_links = false,
      enable_conversion = false,
    },

    full_backup | TransferProfile = {
      name = "full_backup",
      description = "Complete backup with no filtering",
      transfers = 32,
      filter_mode = "none",
      use_checksum = true,
      track_renames = true,
      enable_ghost_links = false,
      enable_conversion = false,
      enable_compression = false,
    },

    # -------------------------------------------------------------------------
    # ARCHIVE PROFILES
    # -------------------------------------------------------------------------

    cold_storage | TransferProfile = {
      name = "cold_storage",
      description = "Archive to cold storage (maximize ghost links)",
      transfers = 16,
      filter_mode = "code_clean",
      enable_ghost_links = true,
      enable_compression = true,  # Compress everything
    },

    migration | TransferProfile = {
      name = "migration",
      description = "Full cloud migration (preserve everything)",
      transfers = 32,
      checkers = 64,
      filter_mode = "none",
      use_checksum = true,
      track_renames = true,
      enable_ghost_links = false,
      enable_conversion = false,
      enable_compression = false,
    },

    # -------------------------------------------------------------------------
    # SPECIAL PURPOSE PROFILES
    # -------------------------------------------------------------------------

    sync_mirror | TransferProfile = {
      name = "sync_mirror",
      description = "Bi-directional sync mirror",
      transfers = 32,
      filter_mode = "smart",
      use_checksum = true,
      track_renames = true,
    },

    incremental | TransferProfile = {
      name = "incremental",
      description = "Fast incremental backup (quick checks)",
      transfers = 32,
      checkers = 128,
      filter_mode = "code_clean",
      use_checksum = false,  # Use size/modtime only
      fast_list = true,
    },

    verify | TransferProfile = {
      name = "verify",
      description = "Verification mode (checksums, no transfer)",
      transfers = 1,
      checkers = 64,
      use_checksum = true,
    },

  },

  # Export schema for external use
  TransferProfile,
}
