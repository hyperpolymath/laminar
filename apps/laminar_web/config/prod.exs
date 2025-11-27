# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

import Config

config :laminar_web, LaminarWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  url: [host: "localhost", port: 4000],
  check_origin: false

config :logger, level: :info
