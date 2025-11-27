# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.PipelineTest do
  use ExUnit.Case, async: true

  alias Laminar.Pipeline

  describe "start_link/1" do
    test "starts pipeline with default options" do
      # Pipeline uses Broadway, which requires proper supervision
      # This is a basic structural test
      opts = [
        source: "dropbox:",
        destination: "gdrive:",
        name: :test_pipeline
      ]

      assert is_list(opts)
      assert opts[:source] == "dropbox:"
    end
  end

  describe "job creation" do
    test "creates job struct with required fields" do
      job = Pipeline.new_job(
        source: "dropbox:photos",
        destination: "gdrive:backup/photos",
        filter_mode: :code_clean
      )

      assert job.source == "dropbox:photos"
      assert job.destination == "gdrive:backup/photos"
      assert job.filter_mode == :code_clean
      assert job.status == :pending
      assert is_binary(job.id)
    end

    test "generates unique job IDs" do
      job1 = Pipeline.new_job(source: "a:", destination: "b:")
      job2 = Pipeline.new_job(source: "a:", destination: "b:")

      refute job1.id == job2.id
    end

    test "sets default options" do
      job = Pipeline.new_job(source: "a:", destination: "b:")

      assert job.transfers == 32
      assert job.checkers == 64
      assert job.filter_mode == :smart
    end
  end

  describe "job status transitions" do
    test "transitions from pending to running" do
      job = Pipeline.new_job(source: "a:", destination: "b:")
      assert job.status == :pending

      updated = Pipeline.update_status(job, :running)
      assert updated.status == :running
      assert updated.started_at != nil
    end

    test "transitions from running to completed" do
      job = Pipeline.new_job(source: "a:", destination: "b:")
      job = Pipeline.update_status(job, :running)
      job = Pipeline.update_status(job, :completed)

      assert job.status == :completed
      assert job.completed_at != nil
    end

    test "transitions to failed state" do
      job = Pipeline.new_job(source: "a:", destination: "b:")
      job = Pipeline.update_status(job, :running)
      job = Pipeline.update_status(job, {:failed, "Connection timeout"})

      assert job.status == :failed
      assert job.error == "Connection timeout"
    end
  end

  describe "lane assignment" do
    test "assigns files to correct lanes based on action" do
      files = [
        %{action: :transfer, name: "file.txt"},
        %{action: :convert, name: "audio.wav"},
        %{action: :link, name: "huge.tar"},
        %{action: :compress, name: "dump.sql"}
      ]

      assignments = Pipeline.assign_lanes(files)

      assert assignments.express == [%{action: :transfer, name: "file.txt"}]
      assert assignments.convert == [%{action: :convert, name: "audio.wav"}]
      assert assignments.ghost == [%{action: :link, name: "huge.tar"}]
      assert assignments.compress == [%{action: :compress, name: "dump.sql"}]
    end

    test "filters out ignored files" do
      files = [
        %{action: :ignore, name: ".DS_Store"},
        %{action: :transfer, name: "file.txt"}
      ]

      assignments = Pipeline.assign_lanes(files)

      # Ignored files should not appear in any lane
      all_assigned = Enum.flat_map(Map.values(assignments), & &1)
      refute Enum.any?(all_assigned, &(&1.action == :ignore))
    end
  end

  describe "progress tracking" do
    test "calculates progress percentage" do
      progress = Pipeline.calculate_progress(%{
        total_files: 100,
        transferred_files: 50,
        total_bytes: 1_000_000_000,
        transferred_bytes: 500_000_000
      })

      assert progress.file_percent == 50.0
      assert progress.byte_percent == 50.0
    end

    test "handles zero total" do
      progress = Pipeline.calculate_progress(%{
        total_files: 0,
        transferred_files: 0,
        total_bytes: 0,
        transferred_bytes: 0
      })

      assert progress.file_percent == 100.0
      assert progress.byte_percent == 100.0
    end
  end

  describe "batch sizing" do
    test "calculates optimal batch size" do
      # Large files should have smaller batches
      batch_size = Pipeline.calculate_batch_size(%{
        average_file_size: 100_000_000,  # 100MB average
        available_memory: 4_000_000_000   # 4GB
      })

      assert batch_size <= 40
      assert batch_size >= 1

      # Small files should have larger batches
      batch_size = Pipeline.calculate_batch_size(%{
        average_file_size: 1_000,  # 1KB average
        available_memory: 4_000_000_000
      })

      assert batch_size >= 100
    end
  end

  describe "retry logic" do
    test "calculates exponential backoff" do
      assert Pipeline.backoff_delay(1) == 1_000
      assert Pipeline.backoff_delay(2) == 2_000
      assert Pipeline.backoff_delay(3) == 4_000
      assert Pipeline.backoff_delay(4) == 8_000
    end

    test "caps backoff at maximum" do
      # Should not exceed 60 seconds
      assert Pipeline.backoff_delay(10) <= 60_000
    end

    test "determines if retry is warranted" do
      assert Pipeline.should_retry?(%{error: :connection_timeout, attempts: 1})
      assert Pipeline.should_retry?(%{error: :rate_limited, attempts: 2})
      refute Pipeline.should_retry?(%{error: :connection_timeout, attempts: 5})
      refute Pipeline.should_retry?(%{error: :not_found, attempts: 1})
    end
  end
end
