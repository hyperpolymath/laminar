# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule LaminarWeb.StatusController do
  use LaminarWeb, :controller

  alias Laminar.RcloneClient

  def index(conn, _params) do
    case RcloneClient.rpc("core/stats", %{}) do
      {:ok, stats} ->
        json(conn, %{
          status: "ok",
          stats: stats
        })

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "error", error: reason})
    end
  end
end
