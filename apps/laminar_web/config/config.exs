# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

import Config

# Configures the endpoint
config :laminar_web, LaminarWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: LaminarWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: LaminarWeb.PubSub

# Rclone RC API Connection
config :laminar_web, :rclone_rc,
  url: System.get_env("RCLONE_RC_URL", "http://localhost:5572"),
  timeout: 60_000

# Pipeline Configuration
config :laminar_web, :pipeline,
  tier1_path: System.get_env("LAMINAR_TIER1", "/mnt/laminar_tier1"),
  tier2_path: System.get_env("LAMINAR_TIER2", "/mnt/laminar_tier2"),
  default_parallelism: 32,
  default_swarm_streams: 8,
  default_buffer_size: "128M"

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :job_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config
import_config "#{config_env()}.exs"
