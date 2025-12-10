# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule LaminarWeb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the Telemetry supervisor
      LaminarWeb.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: LaminarWeb.PubSub},
      # Start Finch HTTP client for Rclone RC API
      {Finch, name: LaminarWeb.Finch},
      # Start the transfer orchestrator
      Laminar.Orchestrator,
      # Start the Endpoint
      LaminarWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: LaminarWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    LaminarWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
