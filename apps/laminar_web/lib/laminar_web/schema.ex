# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule LaminarWeb.Schema do
  @moduledoc """
  The GraphQL Schema for Laminar.

  Provides declarative control over cloud-to-cloud streaming transfers.
  """

  use Absinthe.Schema

  import_types LaminarWeb.Schema.Types
  import_types Absinthe.Type.Custom

  # -- Types --

  @desc "Represents a single Laminar flow (transfer job)"
  object :transfer_job do
    field :id, non_null(:id)
    field :source, non_null(:string)
    field :destination, non_null(:string)
    field :status, non_null(:job_status)

    # Real-time telemetry
    field :speed, :string
    field :percentage, :float
    field :transferred, :string
    field :eta, :string

    # The 'Laminar' tuning parameters used for this job
    field :config, :stream_config
  end

  @desc "Configuration for the parallel stream physics"
  object :stream_config do
    field :parallelism, :integer
    field :swarm_streams, :integer
    field :buffer_size, :string
    field :chunk_size, :string
  end

  @desc "System health and resource statistics"
  object :system_stats do
    field :cpu_load, :float
    field :memory_used, :string
    field :memory_available, :string
    field :network_congestion_algo, :string
    field :tcp_retransmits, :integer
    field :relay_healthy, :boolean
  end

  @desc "Cloud remote configuration"
  object :cloud_remote do
    field :name, non_null(:string)
    field :type, non_null(:string)
    field :space_used, :string
    field :space_available, :string
  end

  @desc "The state of the flow"
  enum :job_status do
    value :queued, description: "Job is queued for execution"
    value :streaming, description: "Data is actively flowing"
    value :finishing, description: "Final cleanup in progress"
    value :failed, description: "Job failed with error"
    value :success, description: "Job completed successfully"
  end

  @desc "Filter strictness levels"
  enum :filter_mode do
    value :none, description: "Transfer everything (raw backup)"
    value :smart, description: "Exclude OS junk (Thumbs.db, .DS_Store)"
    value :code_clean, description: "Exclude OS junk AND build artifacts (node_modules, _build)"
  end

  # -- Queries (Read State) --

  query do
    @desc "Get all active laminar streams"
    field :active_streams, list_of(:transfer_job) do
      resolve &LaminarWeb.Resolvers.Transfer.list_active/3
    end

    @desc "Get a specific transfer job by ID"
    field :stream, :transfer_job do
      arg :id, non_null(:id)
      resolve &LaminarWeb.Resolvers.Transfer.get_stream/3
    end

    @desc "Get system health (RAM/CPU usage of the Relay)"
    field :system_health, :system_stats do
      resolve &LaminarWeb.Resolvers.System.health/3
    end

    @desc "List all configured cloud remotes"
    field :remotes, list_of(:cloud_remote) do
      resolve &LaminarWeb.Resolvers.System.list_remotes/3
    end
  end

  # -- Mutations (Change State) --

  mutation do
    @desc "Initiate a high-speed Laminar stream"
    field :start_laminar_stream, :transfer_job do
      arg :source, non_null(:string)
      arg :destination, non_null(:string)

      # Tweakables (Defaults handled in Resolver)
      arg :parallelism, :integer
      arg :swarm_streams, :integer
      arg :buffer_size, :string
      arg :filter_mode, :filter_mode

      resolve &LaminarWeb.Resolvers.Transfer.start_stream/3
    end

    @desc "Emergency Stop - Cuts the stream immediately"
    field :abort_stream, :boolean do
      arg :job_id, non_null(:id)
      resolve &LaminarWeb.Resolvers.Transfer.abort/3
    end

    @desc "Pause a running stream"
    field :pause_stream, :transfer_job do
      arg :job_id, non_null(:id)
      resolve &LaminarWeb.Resolvers.Transfer.pause/3
    end

    @desc "Resume a paused stream"
    field :resume_stream, :transfer_job do
      arg :job_id, non_null(:id)
      resolve &LaminarWeb.Resolvers.Transfer.resume/3
    end
  end

  # -- Subscriptions (Real-time Feedback) --

  subscription do
    @desc "Subscribe to progress updates for a specific stream"
    field :stream_progress, :transfer_job do
      arg :job_id, non_null(:id)

      config fn args, _ ->
        {:ok, topic: "transfer:#{args.job_id}"}
      end
    end

    @desc "Subscribe to all transfer events"
    field :all_transfers, :transfer_job do
      config fn _, _ ->
        {:ok, topic: "transfers:all"}
      end
    end
  end
end
