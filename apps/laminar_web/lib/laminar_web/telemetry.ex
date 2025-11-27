# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule LaminarWeb.Telemetry do
  @moduledoc """
  Telemetry supervisor for Laminar metrics.
  """

  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),

      # Laminar Transfer Metrics
      counter("laminar.transfer.started.count"),
      counter("laminar.transfer.completed.count"),
      counter("laminar.transfer.failed.count"),

      summary("laminar.transfer.duration",
        unit: {:native, :millisecond}
      ),
      summary("laminar.transfer.bytes",
        unit: :byte
      ),

      # Pipeline Metrics
      counter("laminar.pipeline.express.count"),
      counter("laminar.pipeline.ghost.count"),
      counter("laminar.pipeline.compressed.count"),
      counter("laminar.pipeline.converted.count"),

      # VM Metrics
      summary("vm.memory.total", unit: :byte),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      {__MODULE__, :dispatch_transfer_stats, []}
    ]
  end

  @doc false
  def dispatch_transfer_stats do
    # Placeholder for custom metrics collection
    :ok
  end
end
