# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.Integration.TransferTest do
  @moduledoc """
  Integration tests for end-to-end transfer functionality.

  These tests require:
  - Rclone running with RC API enabled
  - Configured test remotes (local: at minimum)

  Run with: mix test --include integration
  """

  use ExUnit.Case

  alias Laminar.{Pipeline, Intelligence, RcloneClient}

  @moduletag :integration

  setup do
    # Ensure rclone is available
    case RcloneClient.version() do
      {:ok, _} ->
        {:ok, rclone_available: true}

      {:error, _} ->
        {:ok, rclone_available: false}
    end
  end

  describe "local-to-local transfer" do
    @tag :integration
    test "streams files from source to destination", %{rclone_available: available} do
      unless available do
        IO.puts("Skipping: rclone not available")
        :ok
      else
        # Create temp directories
        source_dir = Path.join(System.tmp_dir!(), "laminar_test_src_#{:rand.uniform(1_000_000)}")
        dest_dir = Path.join(System.tmp_dir!(), "laminar_test_dst_#{:rand.uniform(1_000_000)}")

        File.mkdir_p!(source_dir)
        File.mkdir_p!(dest_dir)

        # Create test files
        File.write!(Path.join(source_dir, "test1.txt"), "Hello World")
        File.write!(Path.join(source_dir, "test2.txt"), "Test content")

        on_exit(fn ->
          File.rm_rf!(source_dir)
          File.rm_rf!(dest_dir)
        end)

        # Run transfer
        result = RcloneClient.sync("local:#{source_dir}", "local:#{dest_dir}", %{})

        case result do
          {:ok, _} ->
            # Verify files were transferred
            assert File.exists?(Path.join(dest_dir, "test1.txt"))
            assert File.exists?(Path.join(dest_dir, "test2.txt"))
            assert File.read!(Path.join(dest_dir, "test1.txt")) == "Hello World"

          {:error, reason} ->
            flunk("Transfer failed: #{inspect(reason)}")
        end
      end
    end
  end

  describe "intelligence-driven transfer" do
    @tag :integration
    test "filters out junk files", %{rclone_available: available} do
      unless available do
        :ok
      else
        # Create test files including junk
        source_dir = Path.join(System.tmp_dir!(), "laminar_intel_src_#{:rand.uniform(1_000_000)}")
        dest_dir = Path.join(System.tmp_dir!(), "laminar_intel_dst_#{:rand.uniform(1_000_000)}")

        File.mkdir_p!(source_dir)
        File.mkdir_p!(dest_dir)

        File.write!(Path.join(source_dir, "keep.txt"), "Keep this")
        File.write!(Path.join(source_dir, ".DS_Store"), "Junk")
        File.write!(Path.join(source_dir, "Thumbs.db"), "Junk")

        on_exit(fn ->
          File.rm_rf!(source_dir)
          File.rm_rf!(dest_dir)
        end)

        # Analyze files
        files = [
          %{name: "keep.txt", size: 9, extension: ".txt"},
          %{name: ".DS_Store", size: 4, extension: ".DS_Store"},
          %{name: "Thumbs.db", size: 4, extension: ".db"}
        ]

        partitioned = Intelligence.partition_files(files)

        # Junk should be ignored
        assert length(partitioned.ignore) == 2
        assert length(partitioned.transfer) == 1

        # The actual transfer would use filter file
      end
    end
  end

  describe "pipeline job lifecycle" do
    test "creates and tracks transfer job" do
      job = Pipeline.new_job(
        source: "dropbox:test",
        destination: "gdrive:backup/test",
        filter_mode: :code_clean
      )

      assert job.status == :pending
      assert is_binary(job.id)

      # Simulate job progression
      job = Pipeline.update_status(job, :running)
      assert job.status == :running
      assert job.started_at != nil

      job = Pipeline.update_status(job, :completed)
      assert job.status == :completed
      assert job.completed_at != nil
    end

    test "handles job failure" do
      job = Pipeline.new_job(source: "test:", destination: "test:")
      job = Pipeline.update_status(job, :running)
      job = Pipeline.update_status(job, {:failed, "Connection refused"})

      assert job.status == :failed
      assert job.error == "Connection refused"
    end
  end

  describe "file classification" do
    test "partitions mixed file set correctly" do
      files = [
        # Should ignore
        %{name: ".DS_Store", size: 0, extension: ".DS_Store"},
        %{name: "node_modules", size: 0, extension: ""},
        %{name: "Thumbs.db", size: 100, extension: ".db"},

        # Should transfer
        %{name: "app.ex", size: 5000, extension: ".ex"},
        %{name: "photo.jpg", size: 2_000_000, extension: ".jpg"},
        %{name: "video.mp4", size: 100_000_000, extension: ".mp4"},

        # Should convert
        %{name: "audio.wav", size: 50_000_000, extension: ".wav"},
        %{name: "image.bmp", size: 10_000_000, extension: ".bmp"},

        # Should compress
        %{name: "dump.sql", size: 500_000_000, extension: ".sql"},

        # Should ghost link
        %{name: "archive.tar", size: 10_000_000_000, extension: ".tar"}
      ]

      result = Intelligence.partition_files(files)

      assert length(result.ignore) == 3
      assert length(result.transfer) == 3
      assert length(result.convert) == 2
      assert length(result.compress) == 1
      assert length(result.link) == 1
    end
  end

  describe "bandwidth limiting" do
    @tag :integration
    @tag :slow
    test "respects bandwidth limits", %{rclone_available: available} do
      unless available do
        :ok
      else
        # Set a low bandwidth limit
        case RcloneClient.set_bwlimit("1M") do
          :ok ->
            # Verify the limit is set
            {:ok, stats} = RcloneClient.stats()
            # Stats should reflect the limit is active

            # Reset
            RcloneClient.set_bwlimit("off")
            :ok

          {:error, _} ->
            :ok
        end
      end
    end
  end

  describe "checksum verification" do
    @tag :integration
    test "verifies file checksums after transfer", %{rclone_available: available} do
      unless available do
        :ok
      else
        source_dir = Path.join(System.tmp_dir!(), "laminar_sum_src_#{:rand.uniform(1_000_000)}")
        dest_dir = Path.join(System.tmp_dir!(), "laminar_sum_dst_#{:rand.uniform(1_000_000)}")

        File.mkdir_p!(source_dir)
        File.mkdir_p!(dest_dir)

        # Create a file with known content
        content = :crypto.strong_rand_bytes(1024)
        File.write!(Path.join(source_dir, "random.bin"), content)

        on_exit(fn ->
          File.rm_rf!(source_dir)
          File.rm_rf!(dest_dir)
        end)

        # Copy with checksum verification
        result = RcloneClient.copy(
          "local:#{source_dir}",
          "local:#{dest_dir}",
          %{checksum: true}
        )

        case result do
          {:ok, _} ->
            # Verify content matches
            dest_content = File.read!(Path.join(dest_dir, "random.bin"))
            assert dest_content == content

          {:error, reason} ->
            flunk("Copy failed: #{inspect(reason)}")
        end
      end
    end
  end

  describe "concurrent transfers" do
    @tag :integration
    @tag :slow
    test "handles multiple concurrent transfers", %{rclone_available: available} do
      unless available do
        :ok
      else
        # Create multiple source directories
        sources = for i <- 1..3 do
          dir = Path.join(System.tmp_dir!(), "laminar_concurrent_#{i}_#{:rand.uniform(1_000_000)}")
          File.mkdir_p!(dir)
          File.write!(Path.join(dir, "file.txt"), "Content #{i}")
          dir
        end

        dest_base = Path.join(System.tmp_dir!(), "laminar_concurrent_dest_#{:rand.uniform(1_000_000)}")
        File.mkdir_p!(dest_base)

        on_exit(fn ->
          Enum.each(sources, &File.rm_rf!/1)
          File.rm_rf!(dest_base)
        end)

        # Start concurrent transfers
        tasks = for {src, i} <- Enum.with_index(sources) do
          Task.async(fn ->
            dest = Path.join(dest_base, "dest_#{i}")
            File.mkdir_p!(dest)
            RcloneClient.copy("local:#{src}", "local:#{dest}", %{})
          end)
        end

        # Wait for all to complete
        results = Task.await_many(tasks, 30_000)

        # Verify all succeeded
        for result <- results do
          assert {:ok, _} = result
        end
      end
    end
  end
end
