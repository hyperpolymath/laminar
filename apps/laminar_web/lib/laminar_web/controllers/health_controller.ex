# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule LaminarWeb.HealthController do
  use LaminarWeb, :controller

  alias Laminar.RcloneClient

  def check(conn, _params) do
    relay_healthy = RcloneClient.health_check()

    status = if relay_healthy, do: :ok, else: :service_unavailable

    conn
    |> put_status(status)
    |> json(%{
      status: if(relay_healthy, do: "healthy", else: "degraded"),
      relay: relay_healthy,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end
end
