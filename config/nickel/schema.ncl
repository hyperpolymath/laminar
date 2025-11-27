# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors
#
# Laminar Configuration Schema (Nickel)
# Type-safe configuration with validation

# =============================================================================
# TYPE DEFINITIONS
# =============================================================================

let ByteSize = fun label value =>
  if std.string.is_match "^[0-9]+[KMGT]?$" value then
    value
  else
    std.contract.blame_with_message "Invalid byte size format (e.g., '128M', '1G')" label
in

let PortNumber = fun label value =>
  if value >= 1 && value <= 65535 then
    value
  else
    std.contract.blame_with_message "Port must be between 1 and 65535" label
in

let Percentage = fun label value =>
  if value >= 0.0 && value <= 100.0 then
    value
  else
    std.contract.blame_with_message "Percentage must be between 0 and 100" label
in

let PositiveInt = fun label value =>
  if value > 0 then
    value
  else
    std.contract.blame_with_message "Value must be positive" label
in

# =============================================================================
# STORAGE TIER SCHEMA
# =============================================================================

let TierType = std.contract.from_predicate (fun x => x == "tmpfs" | x == "nvme" | x == "ssd" | x == "hdd") in

let StorageTier = {
  path | String,
  type | TierType,
  size | ByteSize | optional,
  description | String | optional,
} in

# =============================================================================
# RCLONE CONFIGURATION SCHEMA
# =============================================================================

let RcloneDefaults = {
  transfers | PositiveInt | default = 32,
  checkers | PositiveInt | default = 64,
  multi_thread_streams | PositiveInt | default = 8,
  multi_thread_cutoff | ByteSize | default = "64M",
  buffer_size | ByteSize | default = "128M",
  drive_chunk_size | ByteSize | default = "128M",
  tpslimit | Number | default = 0,
  tpslimit_burst | PositiveInt | default = 1,
  retries | PositiveInt | default = 3,
  low_level_retries | PositiveInt | default = 10,
  timeout | String | default = "5m",
  contimeout | String | default = "1m",
} in

let RcloneConfig = {
  rc_url | String | default = "http://localhost:5572",
  rc_user | String | optional,
  rc_pass | String | optional,
  timeout_ms | PositiveInt | default = 60000,
  defaults | RcloneDefaults | default = {},
} in

# =============================================================================
# PIPELINE CONFIGURATION SCHEMA
# =============================================================================

let PipelineConfig = {
  express_concurrency | PositiveInt | default = 32,
  ghost_concurrency | PositiveInt | default = 16,
  compressed_concurrency | PositiveInt | default = 8,
  converted_concurrency | PositiveInt | default = 4,
  batch_size | PositiveInt | default = 10,
  batch_timeout_ms | PositiveInt | default = 5000,
} in

# =============================================================================
# INTELLIGENCE ENGINE SCHEMA
# =============================================================================

let IntelligenceConfig = {
  ghost_link_threshold_bytes | PositiveInt | default = 5368709120,  # 5GB
  massive_file_threshold_bytes | PositiveInt | default = 50000000000,  # 50GB
  compression_threshold_bytes | PositiveInt | default = 10000000,  # 10MB
  enabled_rulesets | Array String | default = ["default"],
} in

# =============================================================================
# WEB SERVER SCHEMA
# =============================================================================

let WebConfig = {
  host | String | default = "localhost",
  port | PortNumber | default = 4000,
  secret_key_base | String | optional,
  cors_origins | Array String | default = ["*"],
  enable_graphiql | Bool | default = true,
} in

# =============================================================================
# NETWORK TUNING SCHEMA
# =============================================================================

let NetworkConfig = {
  enable_bbr | Bool | default = true,
  tcp_rmem_max | PositiveInt | default = 16777216,
  tcp_wmem_max | PositiveInt | default = 16777216,
  enable_gro | Bool | default = true,
  disable_lro | Bool | default = true,
  interface | String | default = "eth0",
} in

# =============================================================================
# LOGGING SCHEMA
# =============================================================================

let LogLevel = std.contract.from_predicate (fun x =>
  x == "debug" | x == "info" | x == "warning" | x == "error"
) in

let LoggingConfig = {
  level | LogLevel | default = "info",
  format | String | default = "$time $metadata[$level] $message",
  enable_file_logging | Bool | default = false,
  log_file_path | String | default = "/var/log/laminar/laminar.log",
  max_log_size_mb | PositiveInt | default = 100,
  log_retention_days | PositiveInt | default = 7,
} in

# =============================================================================
# REFINERY (CONVERSION) SCHEMA
# =============================================================================

let RefineryConfig = {
  enable_audio_conversion | Bool | default = true,
  enable_image_conversion | Bool | default = true,
  enable_compression | Bool | default = true,
  ffmpeg_path | String | default = "ffmpeg",
  imagemagick_path | String | default = "convert",
  zstd_compression_level | PositiveInt | default = 19,
  flac_compression_level | PositiveInt | default = 8,
  webp_quality | PositiveInt | default = 100,  # 100 = lossless
} in

# =============================================================================
# MAIN CONFIGURATION SCHEMA
# =============================================================================

let LaminarConfig = {
  version | String | default = "1.0.0",
  environment | String | default = "production",

  tiers | {
    tier1 | StorageTier | default = {
      path = "/mnt/laminar_tier1",
      type = "tmpfs",
      size = "2G",
      description = "RAM Capacitor - Volatile ingestion buffer",
    },
    tier2 | StorageTier | default = {
      path = "/mnt/laminar_tier2",
      type = "nvme",
      description = "NVMe Stage - Checkpoint cache",
    },
  },

  rclone | RcloneConfig | default = {},
  pipeline | PipelineConfig | default = {},
  intelligence | IntelligenceConfig | default = {},
  web | WebConfig | default = {},
  network | NetworkConfig | default = {},
  logging | LoggingConfig | default = {},
  refinery | RefineryConfig | default = {},
} in

# Export the schema
{
  LaminarConfig,
  StorageTier,
  RcloneConfig,
  RcloneDefaults,
  PipelineConfig,
  IntelligenceConfig,
  WebConfig,
  NetworkConfig,
  LoggingConfig,
  RefineryConfig,

  # Contract helpers
  ByteSize,
  PortNumber,
  Percentage,
  PositiveInt,
}
