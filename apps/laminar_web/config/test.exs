# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

import Config

config :laminar_web, LaminarWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-only-secret-key-laminar-testing-2025-do-not-use-in-production",
  server: false

config :logger, level: :warning
