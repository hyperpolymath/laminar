# SPDX-License-Identifier: MPL-2.0
# StreamData property tests for Laminar data-transformation invariants.
#
# Tests use property-based generation to verify that key pipeline operations
# hold for arbitrary inputs, catching edge cases missed by example-based tests.

defmodule Laminar.DataPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Laminar.Pipeline
  alias Laminar.Intelligence

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  # Generate a file metadata map with arbitrary name and size.
  defp file_gen do
    gen all name <- StreamData.string(:alphanumeric, min_length: 1, max_length: 60),
            ext <- StreamData.member_of(["", ".txt", ".ex", ".rs", ".mp4", ".jpg", ".wav", ".sql", ".tar"]),
            size <- StreamData.integer(0..10_000_000_000) do
      full_name = name <> ext
      %{name: full_name, size: size, extension: ext}
    end
  end

  # Generate a non-empty list of file metadata maps.
  defp file_list_gen(max \\ 20) do
    StreamData.list_of(file_gen(), min_length: 1, max_length: max)
  end

  # ---------------------------------------------------------------------------
  # Job ID uniqueness
  # ---------------------------------------------------------------------------

  describe "job ID uniqueness" do
    property "every new_job call produces a unique binary ID" do
      check all _n <- StreamData.integer(1..1) do
        job1 = Pipeline.new_job(source: "a:", destination: "b:")
        job2 = Pipeline.new_job(source: "a:", destination: "b:")
        assert is_binary(job1.id)
        assert is_binary(job2.id)
        assert job1.id != job2.id
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Lane assignment coverage
  # ---------------------------------------------------------------------------

  describe "lane assignment exhaustiveness" do
    property "every non-ignored file appears in exactly one lane" do
      check all files <- file_list_gen() do
        classified =
          Enum.map(files, fn f ->
            action =
              case Intelligence.consult_oracle(f) do
                :ignore -> :ignore
                {:link, _} -> :link
                {:convert, _, _} -> :convert
                {:compress, _, _} -> :compress
                {:transfer, _, _} -> :transfer
              end

            Map.put(f, :action, action)
          end)

        non_ignored = Enum.reject(classified, &(&1.action == :ignore))
        assignments = Pipeline.assign_lanes(classified)
        assigned_count = Enum.sum(Enum.map(Map.values(assignments), &length/1))

        assert assigned_count == length(non_ignored),
               "Expected #{length(non_ignored)} assigned files but got #{assigned_count}"
      end
    end

    property "ignored files never appear in any lane" do
      check all files <- file_list_gen() do
        classified =
          Enum.map(files, fn f ->
            action =
              case Intelligence.consult_oracle(f) do
                :ignore -> :ignore
                {:link, _} -> :link
                {:convert, _, _} -> :convert
                {:compress, _, _} -> :compress
                {:transfer, _, _} -> :transfer
              end

            Map.put(f, :action, action)
          end)

        assignments = Pipeline.assign_lanes(classified)
        all_assigned = Enum.flat_map(Map.values(assignments), & &1)

        assert Enum.all?(all_assigned, &(&1.action != :ignore)),
               "An ignored file appeared in a lane"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Batch sizing bounds
  # ---------------------------------------------------------------------------

  describe "batch size bounds" do
    property "batch size is always at least 1" do
      check all avg_size <- StreamData.integer(1..1_000_000_000),
                mem <- StreamData.integer(1_000_000..64_000_000_000) do
        batch = Pipeline.calculate_batch_size(%{average_file_size: avg_size, available_memory: mem})
        assert batch >= 1
      end
    end

    property "larger average file sizes yield non-increasing batch sizes" do
      check all small <- StreamData.integer(1..10_000),
                large <- StreamData.integer(100_000_000..1_000_000_000),
                mem <- StreamData.integer(4_000_000_000..8_000_000_000) do
        small_batch = Pipeline.calculate_batch_size(%{average_file_size: small, available_memory: mem})
        large_batch = Pipeline.calculate_batch_size(%{average_file_size: large, available_memory: mem})

        assert small_batch >= large_batch,
               "Small-file batch #{small_batch} should be >= large-file batch #{large_batch}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Progress calculation
  # ---------------------------------------------------------------------------

  describe "progress calculation" do
    property "file_percent is always in [0.0, 100.0]" do
      check all total <- StreamData.integer(0..1_000_000),
                transferred <- StreamData.integer(0..1_000_000) do
        # Ensure transferred never exceeds total for realistic inputs
        {t, tr} = if total == 0, do: {0, 0}, else: {total, min(transferred, total)}

        progress =
          Pipeline.calculate_progress(%{
            total_files: t,
            transferred_files: tr,
            total_bytes: t,
            transferred_bytes: tr
          })

        assert progress.file_percent >= 0.0
        assert progress.file_percent <= 100.0
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Backoff delay
  # ---------------------------------------------------------------------------

  describe "backoff delay" do
    property "backoff_delay is monotonically non-decreasing for attempts 1..8" do
      check all _n <- StreamData.integer(1..1) do
        delays = Enum.map(1..8, &Pipeline.backoff_delay/1)
        pairs = Enum.zip(delays, tl(delays))

        assert Enum.all?(pairs, fn {a, b} -> b >= a end),
               "Backoff sequence is not non-decreasing: #{inspect(delays)}"
      end
    end

    property "backoff_delay never exceeds 60 seconds" do
      check all attempt <- StreamData.integer(1..20) do
        assert Pipeline.backoff_delay(attempt) <= 60_000
      end
    end
  end
end
