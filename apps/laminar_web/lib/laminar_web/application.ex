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
      # Start the Credential Pool for multi-SA quota management
      {Laminar.CredentialPool, credentials_path: credentials_path()},
      # Start the Parallel Transfer coordinator
      Laminar.ParallelTransfer,
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

  defp credentials_path do
    # Check for credentials in standard locations
    paths = [
      System.get_env("LAMINAR_CREDENTIALS_PATH"),
      Path.expand("~/.config/laminar/credentials"),
      "/etc/laminar/credentials",
      "/secrets/credentials"
    ]

    Enum.find(paths, fn
      nil -> false
      path -> File.dir?(path)
    end)
  end
end
