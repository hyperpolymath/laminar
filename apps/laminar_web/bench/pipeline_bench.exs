# SPDX-License-Identifier: PMPL-1.0-or-later
# Benchee benchmarks for Laminar pipeline operations.
#
# Run with:   mix run bench/pipeline_bench.exs
# For HTML:   mix run bench/pipeline_bench.exs --html

alias Laminar.Pipeline
alias Laminar.Intelligence

# ---------------------------------------------------------------------------
# Shared data
# ---------------------------------------------------------------------------

small_file = %{name: "README.md", size: 10_000, extension: ".md"}
large_file = %{name: "backup.sql", size: 200_000_000, extension: ".sql"}
huge_file  = %{name: "archive.tar", size: 10_000_000_000, extension: ".tar"}
wav_file   = %{name: "audio.wav", size: 60_000_000, extension: ".wav"}
ds_store   = %{name: ".DS_Store", size: 0, extension: ".DS_Store"}

files_100 =
  Enum.map(1..100, fn i ->
    %{name: "file_#{i}.txt", size: :rand.uniform(10_000_000), extension: ".txt"}
  end)

files_1000 =
  Enum.map(1..1000, fn i ->
    %{name: "file_#{i}.txt", size: :rand.uniform(10_000_000), extension: ".txt"}
  end)

classify = fn f ->
  action =
    case Intelligence.consult_oracle(f) do
      :ignore -> :ignore
      {:link, _} -> :link
      {:convert, _, _} -> :convert
      {:compress, _, _} -> :compress
      {:transfer, _, _} -> :transfer
    end
  Map.put(f, :action, action)
end

classified_100  = Enum.map(files_100, classify)
classified_1000 = Enum.map(files_1000, classify)

# ---------------------------------------------------------------------------
# Benchmarks
# ---------------------------------------------------------------------------

Benchee.run(
  %{
    # --- Intelligence / oracle classification ---
    "oracle: small text file" => fn ->
      Intelligence.consult_oracle(small_file)
    end,

    "oracle: large SQL dump" => fn ->
      Intelligence.consult_oracle(large_file)
    end,

    "oracle: huge tar archive (ghost)" => fn ->
      Intelligence.consult_oracle(huge_file)
    end,

    "oracle: WAV to FLAC convert" => fn ->
      Intelligence.consult_oracle(wav_file)
    end,

    "oracle: .DS_Store (ignore)" => fn ->
      Intelligence.consult_oracle(ds_store)
    end,

    # --- Lane assignment ---
    "assign_lanes: 100 pre-classified files" => fn ->
      Pipeline.assign_lanes(classified_100)
    end,

    "assign_lanes: 1000 pre-classified files" => fn ->
      Pipeline.assign_lanes(classified_1000)
    end,

    # --- Job creation ---
    "new_job: default options" => fn ->
      Pipeline.new_job(source: "dropbox:", destination: "gdrive:")
    end,

    # --- Status transitions ---
    "update_status: pending → running" => fn ->
      job = Pipeline.new_job(source: "a:", destination: "b:")
      Pipeline.update_status(job, :running)
    end,

    "update_status: full lifecycle" => fn ->
      job = Pipeline.new_job(source: "a:", destination: "b:")
      job = Pipeline.update_status(job, :running)
      Pipeline.update_status(job, :completed)
    end,

    # --- Progress calculation ---
    "calculate_progress: mid-transfer" => fn ->
      Pipeline.calculate_progress(%{
        total_files: 10_000,
        transferred_files: 5_000,
        total_bytes: 100_000_000_000,
        transferred_bytes: 50_000_000_000
      })
    end,

    # --- Batch sizing ---
    "calculate_batch_size: small files, 4GB RAM" => fn ->
      Pipeline.calculate_batch_size(%{average_file_size: 1_000, available_memory: 4_000_000_000})
    end,

    "calculate_batch_size: large files, 4GB RAM" => fn ->
      Pipeline.calculate_batch_size(%{average_file_size: 100_000_000, available_memory: 4_000_000_000})
    end,

    # --- Backoff delay ---
    "backoff_delay: attempt 1" => fn -> Pipeline.backoff_delay(1) end,
    "backoff_delay: attempt 5" => fn -> Pipeline.backoff_delay(5) end
  },
  time: 3,
  memory_time: 1,
  warmup: 1,
  print: [fast_warning: false],
  formatters: [
    Benchee.Formatters.Console
  ]
)
