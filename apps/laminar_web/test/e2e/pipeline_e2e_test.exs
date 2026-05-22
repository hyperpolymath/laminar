# SPDX-License-Identifier: MPL-2.0
# End-to-end tests for the Laminar pipeline.
#
# These tests exercise the full pipeline path from file classification through
# lane assignment and progress tracking, using self-contained mocked data.
# External services (rclone, cloud providers) are not required.

defmodule Laminar.Pipeline.E2ETest do
  use ExUnit.Case, async: false

  alias Laminar.Intelligence
  alias Laminar.Pipeline

  @moduletag :e2e

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_file(name, size) do
    ext = Path.extname(name)
    %{name: name, size: size, extension: ext}
  end

  # ---------------------------------------------------------------------------
  # Full classify → partition → lane-assign pipeline
  # ---------------------------------------------------------------------------

  describe "full classify → lane assignment pipeline" do
    test "media files flow through transfer lane" do
      files = [
        make_file("video.mp4", 500_000_000),
        make_file("photo.jpg", 5_000_000),
        make_file("track.mp3", 10_000_000)
      ]

      assignments =
        files
        |> Enum.map(fn f -> Map.put(f, :action, action_for(f)) end)
        |> Pipeline.assign_lanes()

      assert length(assignments.express) == 3
      assert assignments.ghost == []
      assert assignments.compress == []
    end

    test "huge archive files are routed to ghost lane" do
      files = [make_file("dump.tar", 10_000_000_000)]

      assignments =
        files
        |> Enum.map(fn f -> Map.put(f, :action, action_for(f)) end)
        |> Pipeline.assign_lanes()

      assert length(assignments.ghost) == 1
      assert assignments.express == []
    end

    test "WAV files are routed to convert lane" do
      files = [make_file("recording.wav", 60_000_000)]

      assignments =
        files
        |> Enum.map(fn f -> Map.put(f, :action, action_for(f)) end)
        |> Pipeline.assign_lanes()

      assert length(assignments.convert) == 1
    end

    test "large SQL dumps are routed to compress lane" do
      files = [make_file("backup.sql", 200_000_000)]

      assignments =
        files
        |> Enum.map(fn f -> Map.put(f, :action, action_for(f)) end)
        |> Pipeline.assign_lanes()

      assert length(assignments.compress) == 1
    end

    test "ignored files are absent from all lanes" do
      files = [make_file(".DS_Store", 0), make_file("Thumbs.db", 0)]

      assignments =
        files
        |> Enum.map(fn f -> Map.put(f, :action, action_for(f)) end)
        |> Pipeline.assign_lanes()

      all = Enum.flat_map(Map.values(assignments), & &1)
      assert all == []
    end

    test "mixed bag of files partitions correctly" do
      files = [
        make_file("main.rs", 5_000),
        make_file("node_modules", 0),
        make_file("huge.tar", 8_000_000_000),
        make_file("sound.wav", 40_000_000),
        make_file("video.mp4", 900_000_000)
      ]

      assignments =
        files
        |> Enum.map(fn f -> Map.put(f, :action, action_for(f)) end)
        |> Pipeline.assign_lanes()

      # source code + mp4 go to express
      assert length(assignments.express) == 2
      # .tar ghost link
      assert length(assignments.ghost) == 1
      # WAV convert
      assert length(assignments.convert) == 1
      # node_modules is ignored — absent
      all = Enum.flat_map(Map.values(assignments), & &1)
      refute Enum.any?(all, &(&1.name == "node_modules"))
    end
  end

  # ---------------------------------------------------------------------------
  # Job lifecycle E2E
  # ---------------------------------------------------------------------------

  describe "job lifecycle: pending → running → completed" do
    test "full happy-path lifecycle" do
      job = Pipeline.new_job(source: "dropbox:docs", destination: "gdrive:backup/docs")

      assert job.status == :pending
      assert is_binary(job.id)

      job = Pipeline.update_status(job, :running)
      assert job.status == :running
      assert job.started_at != nil

      job = Pipeline.update_status(job, :completed)
      assert job.status == :completed
      assert job.completed_at != nil
    end

    test "failed lifecycle records error reason" do
      job =
        Pipeline.new_job(source: "s3:bucket", destination: "gdrive:archive")
        |> Pipeline.update_status(:running)
        |> Pipeline.update_status({:failed, "quota exceeded"})

      assert job.status == :failed
      assert job.error == "quota exceeded"
    end

    test "unique IDs across concurrent job creation" do
      jobs = Enum.map(1..50, fn _ -> Pipeline.new_job(source: "a:", destination: "b:") end)
      ids = Enum.map(jobs, & &1.id)
      assert length(Enum.uniq(ids)) == 50
    end
  end

  # ---------------------------------------------------------------------------
  # Progress tracking E2E
  # ---------------------------------------------------------------------------

  describe "progress tracking" do
    test "tracks incremental progress to completion" do
      checkpoints = [
        %{total_files: 100, transferred_files: 0, total_bytes: 1_000_000, transferred_bytes: 0},
        %{total_files: 100, transferred_files: 25, total_bytes: 1_000_000, transferred_bytes: 250_000},
        %{total_files: 100, transferred_files: 100, total_bytes: 1_000_000, transferred_bytes: 1_000_000}
      ]

      [start, mid, done] = Enum.map(checkpoints, &Pipeline.calculate_progress/1)

      assert start.file_percent == 0.0
      assert mid.file_percent == 25.0
      assert done.file_percent == 100.0
      assert done.byte_percent == 100.0
    end
  end

  # ---------------------------------------------------------------------------
  # Retry logic E2E
  # ---------------------------------------------------------------------------

  describe "retry logic" do
    test "exponential backoff sequence stays bounded" do
      delays = Enum.map(1..10, &Pipeline.backoff_delay/1)

      # Sequence must be non-decreasing
      pairs = Enum.zip(delays, tl(delays))
      assert Enum.all?(pairs, fn {a, b} -> b >= a end)

      # None exceeds 60 seconds
      assert Enum.max(delays) <= 60_000
    end

    test "transient errors warrant retry but permanent errors do not" do
      assert Pipeline.should_retry?(%{error: :connection_timeout, attempts: 1})
      assert Pipeline.should_retry?(%{error: :rate_limited, attempts: 2})
      refute Pipeline.should_retry?(%{error: :not_found, attempts: 1})
      refute Pipeline.should_retry?(%{error: :connection_timeout, attempts: 5})
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Delegate classification to Intelligence so lane assignment uses live logic.
  defp action_for(file) do
    case Intelligence.consult_oracle(file) do
      :ignore -> :ignore
      {:link, _} -> :link
      {:convert, _, _} -> :convert
      {:compress, _, _} -> :compress
      {:transfer, _, _} -> :transfer
    end
  end
end
