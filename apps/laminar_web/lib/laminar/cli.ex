# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.CLI do
  @moduledoc """
  Laminar Command Line Interface.

  Provides comprehensive command-line access to all Laminar functionality.

  ## Usage

      laminar <command> [options] [arguments]

  ## Global Options

      --config, -c      Configuration file path
      --profile, -p     Transfer profile to use
      --verbose, -v     Increase verbosity (can be repeated)
      --quiet, -q       Suppress output except errors
      --json            Output in JSON format
      --no-color        Disable colored output
      --help, -h        Show help
      --version         Show version

  ## Commands

      stream            Stream files between cloud providers
      sync              Synchronize directories
      copy              Copy files (one-way)
      move              Move files (copy + delete source)
      ls                List remote contents
      lsd               List directories only
      lsl               List with details
      tree              Tree view of remote
      size              Calculate size of remote path
      check             Verify files between source and destination
      delete            Delete files
      mkdir             Create directory
      rmdir             Remove directory
      about             Get remote quota information
      remotes           List configured remotes
      config            Manage configuration
      profile           Manage transfer profiles
      job               Manage transfer jobs
      stats             Show transfer statistics
      health            Check system health
      version           Show version information

  ## Examples

      # Stream from Dropbox to Google Drive
      laminar stream dropbox:photos gdrive:backup/photos

      # Sync with progress
      laminar sync -v --progress dropbox:/ s3:bucket/backup

      # Copy using high-bandwidth profile
      laminar copy -p high_bandwidth dropbox:large-files b2:archive

      # List files as JSON
      laminar ls --json gdrive:documents

  """

  @version Mix.Project.config()[:version] || "1.0.0"

  # ===========================================================================
  # OPTION SPECIFICATIONS
  # ===========================================================================

  @global_switches [
    # Configuration
    config: :string,
    profile: :string,
    rclone_url: :string,

    # Output control
    verbose: :count,
    quiet: :boolean,
    json: :boolean,
    no_color: :boolean,

    # Help
    help: :boolean,
    version: :boolean
  ]

  @global_aliases [
    c: :config,
    p: :profile,
    v: :verbose,
    q: :quiet,
    h: :help
  ]

  @transfer_switches [
    # Parallelism
    transfers: :integer,
    checkers: :integer,
    multi_thread_streams: :integer,
    multi_thread_cutoff: :string,

    # Buffer settings
    buffer_size: :string,
    use_mmap: :boolean,

    # Bandwidth control
    bwlimit: :string,
    bwlimit_file: :string,

    # Filtering
    filter: :string,
    filter_from: :string,
    include: :string,
    include_from: :string,
    exclude: :string,
    exclude_from: :string,
    files_from: :string,
    min_size: :string,
    max_size: :string,
    min_age: :string,
    max_age: :string,

    # Comparison
    checksum: :boolean,
    no_checksum: :boolean,
    size_only: :boolean,
    update: :boolean,
    ignore_existing: :boolean,
    ignore_size: :boolean,
    ignore_times: :boolean,
    modify_window: :string,

    # Copy behavior
    copy_links: :boolean,
    no_traverse: :boolean,
    no_update_modtime: :boolean,
    no_gzip_encoding: :boolean,
    track_renames: :boolean,
    track_renames_strategy: :string,

    # Sync specific
    delete_before: :boolean,
    delete_during: :boolean,
    delete_after: :boolean,
    delete_excluded: :boolean,
    backup_dir: :string,
    suffix: :string,
    suffix_keep_extension: :boolean,

    # Error handling
    retries: :integer,
    retries_sleep: :string,
    low_level_retries: :integer,
    ignore_errors: :boolean,
    no_check_dest: :boolean,
    contimeout: :string,
    timeout: :string,
    expect_continue_timeout: :string,

    # Performance
    fast_list: :boolean,
    no_fast_list: :boolean,
    cache: :boolean,
    no_cache: :boolean,

    # Dry run
    dry_run: :boolean,
    interactive: :boolean,

    # Progress
    progress: :boolean,
    no_progress: :boolean,
    stats: :string,
    stats_file_name_length: :integer,
    stats_one_line: :boolean,
    stats_one_line_date: :boolean,
    stats_one_line_date_format: :string,

    # Logging
    log_level: :string,
    log_file: :string,
    log_format: :string,
    use_json_log: :boolean,

    # Laminar specific
    enable_ghost_links: :boolean,
    no_ghost_links: :boolean,
    ghost_link_threshold: :string,
    enable_conversion: :boolean,
    no_conversion: :boolean,
    enable_compression: :boolean,
    no_compression: :boolean,
    intelligence_mode: :string,
    filter_mode: :string
  ]

  @transfer_aliases [
    n: :dry_run,
    P: :progress,
    i: :interactive
  ]

  @list_switches [
    recursive: :boolean,
    max_depth: :integer,
    include: :string,
    exclude: :string,
    filter: :string,
    files_only: :boolean,
    dirs_only: :boolean,
    format: :string,
    separator: :string,
    absolute: :boolean,
    human_readable: :boolean
  ]

  @list_aliases [
    R: :recursive,
    d: :max_depth
  ]

  # ===========================================================================
  # MAIN ENTRY POINT
  # ===========================================================================

  @doc """
  Main entry point for the CLI.
  """
  def main(args \\ []) do
    {global_opts, remaining, _invalid} =
      OptionParser.parse(args, strict: @global_switches, aliases: @global_aliases)

    cond do
      global_opts[:version] ->
        print_version()

      global_opts[:help] && remaining == [] ->
        print_help()

      true ->
        case remaining do
          [] ->
            print_help()

          [command | rest] ->
            run_command(command, rest, global_opts)
        end
    end
  end

  # ===========================================================================
  # COMMANDS
  # ===========================================================================

  defp run_command(command, args, global_opts) do
    case command do
      # Transfer commands
      "stream" -> cmd_stream(args, global_opts)
      "sync" -> cmd_sync(args, global_opts)
      "copy" -> cmd_copy(args, global_opts)
      "move" -> cmd_move(args, global_opts)

      # List commands
      "ls" -> cmd_ls(args, global_opts)
      "lsl" -> cmd_lsl(args, global_opts)
      "lsd" -> cmd_lsd(args, global_opts)
      "tree" -> cmd_tree(args, global_opts)

      # Info commands
      "size" -> cmd_size(args, global_opts)
      "about" -> cmd_about(args, global_opts)
      "check" -> cmd_check(args, global_opts)

      # File operations
      "delete" -> cmd_delete(args, global_opts)
      "mkdir" -> cmd_mkdir(args, global_opts)
      "rmdir" -> cmd_rmdir(args, global_opts)

      # Management
      "remotes" -> cmd_remotes(args, global_opts)
      "config" -> cmd_config(args, global_opts)
      "profile" -> cmd_profile(args, global_opts)
      "job" -> cmd_job(args, global_opts)

      # Status
      "stats" -> cmd_stats(args, global_opts)
      "health" -> cmd_health(args, global_opts)
      "version" -> print_version()

      # Help
      "help" -> print_command_help(args)

      _ ->
        error("Unknown command: #{command}")
        print_help()
        System.halt(1)
    end
  end

  # ---------------------------------------------------------------------------
  # STREAM COMMAND
  # ---------------------------------------------------------------------------

  defp cmd_stream(args, global_opts) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: @transfer_switches, aliases: @transfer_aliases)

    opts = merge_opts(global_opts, opts)

    case positional do
      [source, dest] ->
        info(opts, "Streaming from #{source} to #{dest}")
        do_transfer(:stream, source, dest, opts)

      _ ->
        print_command_help(["stream"])
        System.halt(1)
    end
  end

  # ---------------------------------------------------------------------------
  # SYNC COMMAND
  # ---------------------------------------------------------------------------

  defp cmd_sync(args, global_opts) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: @transfer_switches, aliases: @transfer_aliases)

    opts = merge_opts(global_opts, opts)

    case positional do
      [source, dest] ->
        info(opts, "Syncing from #{source} to #{dest}")
        do_transfer(:sync, source, dest, opts)

      _ ->
        print_command_help(["sync"])
        System.halt(1)
    end
  end

  # ---------------------------------------------------------------------------
  # COPY COMMAND
  # ---------------------------------------------------------------------------

  defp cmd_copy(args, global_opts) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: @transfer_switches, aliases: @transfer_aliases)

    opts = merge_opts(global_opts, opts)

    case positional do
      [source, dest] ->
        info(opts, "Copying from #{source} to #{dest}")
        do_transfer(:copy, source, dest, opts)

      _ ->
        print_command_help(["copy"])
        System.halt(1)
    end
  end

  # ---------------------------------------------------------------------------
  # MOVE COMMAND
  # ---------------------------------------------------------------------------

  defp cmd_move(args, global_opts) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: @transfer_switches, aliases: @transfer_aliases)

    opts = merge_opts(global_opts, opts)

    case positional do
      [source, dest] ->
        info(opts, "Moving from #{source} to #{dest}")
        do_transfer(:move, source, dest, opts)

      _ ->
        print_command_help(["move"])
        System.halt(1)
    end
  end

  # ---------------------------------------------------------------------------
  # LIST COMMANDS
  # ---------------------------------------------------------------------------

  defp cmd_ls(args, global_opts) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: @list_switches, aliases: @list_aliases)

    opts = merge_opts(global_opts, opts)

    case positional do
      [remote] -> do_list(remote, opts)
      [] -> do_list("", opts)
      _ -> print_command_help(["ls"])
    end
  end

  defp cmd_lsl(args, global_opts) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: @list_switches, aliases: @list_aliases)

    opts = merge_opts(global_opts, opts) |> Keyword.put(:format, :long)

    case positional do
      [remote] -> do_list(remote, opts)
      [] -> do_list("", opts)
      _ -> print_command_help(["lsl"])
    end
  end

  defp cmd_lsd(args, global_opts) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: @list_switches, aliases: @list_aliases)

    opts = merge_opts(global_opts, opts) |> Keyword.put(:dirs_only, true)

    case positional do
      [remote] -> do_list(remote, opts)
      [] -> do_list("", opts)
      _ -> print_command_help(["lsd"])
    end
  end

  defp cmd_tree(args, global_opts) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: @list_switches ++ [level: :integer, noreport: :boolean],
        aliases: @list_aliases ++ [L: :level]
      )

    opts = merge_opts(global_opts, opts)

    case positional do
      [remote] -> do_tree(remote, opts)
      [] -> do_tree("", opts)
      _ -> print_command_help(["tree"])
    end
  end

  # ---------------------------------------------------------------------------
  # INFO COMMANDS
  # ---------------------------------------------------------------------------

  defp cmd_size(args, global_opts) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          json: :boolean,
          human_readable: :boolean
        ]
      )

    opts = merge_opts(global_opts, opts)

    case positional do
      [remote] -> do_size(remote, opts)
      _ -> print_command_help(["size"])
    end
  end

  defp cmd_about(args, global_opts) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          json: :boolean,
          full: :boolean
        ]
      )

    opts = merge_opts(global_opts, opts)

    case positional do
      [remote] -> do_about(remote, opts)
      [] -> do_about("", opts)
      _ -> print_command_help(["about"])
    end
  end

  defp cmd_check(args, global_opts) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict:
          @transfer_switches ++
            [
              one_way: :boolean,
              download: :boolean,
              combined: :string,
              missing_on_src: :string,
              missing_on_dst: :string,
              match: :string,
              differ: :string,
              error: :string
            ]
      )

    opts = merge_opts(global_opts, opts)

    case positional do
      [source, dest] -> do_check(source, dest, opts)
      _ -> print_command_help(["check"])
    end
  end

  # ---------------------------------------------------------------------------
  # FILE OPERATION COMMANDS
  # ---------------------------------------------------------------------------

  defp cmd_delete(args, global_opts) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          rmdirs: :boolean,
          force: :boolean,
          include: :string,
          exclude: :string,
          filter: :string,
          min_size: :string,
          max_size: :string,
          min_age: :string,
          max_age: :string
        ],
        aliases: [f: :force]
      )

    opts = merge_opts(global_opts, opts)

    case positional do
      [remote] -> do_delete(remote, opts)
      _ -> print_command_help(["delete"])
    end
  end

  defp cmd_mkdir(args, global_opts) do
    opts = merge_opts(global_opts, [])

    case args do
      [remote] -> do_mkdir(remote, opts)
      _ -> print_command_help(["mkdir"])
    end
  end

  defp cmd_rmdir(args, global_opts) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [leave_root: :boolean],
        aliases: []
      )

    opts = merge_opts(global_opts, opts)

    case positional do
      [remote] -> do_rmdir(remote, opts)
      _ -> print_command_help(["rmdir"])
    end
  end

  # ---------------------------------------------------------------------------
  # MANAGEMENT COMMANDS
  # ---------------------------------------------------------------------------

  defp cmd_remotes(args, global_opts) do
    {opts, subcommand, _} =
      OptionParser.parse(args,
        strict: [long: :boolean]
      )

    opts = merge_opts(global_opts, opts)

    case subcommand do
      [] -> do_list_remotes(opts)
      ["list"] -> do_list_remotes(opts)
      _ -> print_command_help(["remotes"])
    end
  end

  defp cmd_config(args, global_opts) do
    {opts, subcommand, _} =
      OptionParser.parse(args,
        strict: [format: :string]
      )

    opts = merge_opts(global_opts, opts)

    case subcommand do
      ["show"] -> do_config_show(opts)
      ["providers"] -> do_config_providers(opts)
      ["dump"] -> do_config_dump(opts)
      _ -> print_command_help(["config"])
    end
  end

  defp cmd_profile(args, global_opts) do
    opts = merge_opts(global_opts, [])

    case args do
      ["list"] -> do_profile_list(opts)
      ["show", name] -> do_profile_show(name, opts)
      ["use", name] -> do_profile_use(name, opts)
      _ -> print_command_help(["profile"])
    end
  end

  defp cmd_job(args, global_opts) do
    {opts, subcommand, _} =
      OptionParser.parse(args,
        strict: [all: :boolean]
      )

    opts = merge_opts(global_opts, opts)

    case subcommand do
      ["list"] -> do_job_list(opts)
      ["status", id] -> do_job_status(id, opts)
      ["stop", id] -> do_job_stop(id, opts)
      ["stop-all"] -> do_job_stop_all(opts)
      _ -> print_command_help(["job"])
    end
  end

  # ---------------------------------------------------------------------------
  # STATUS COMMANDS
  # ---------------------------------------------------------------------------

  defp cmd_stats(args, global_opts) do
    {opts, _subcommand, _} =
      OptionParser.parse(args,
        strict: [
          group: :string,
          reset: :boolean,
          watch: :boolean,
          interval: :integer
        ]
      )

    opts = merge_opts(global_opts, opts)
    do_stats(opts)
  end

  defp cmd_health(args, global_opts) do
    {opts, _subcommand, _} =
      OptionParser.parse(args,
        strict: [
          detailed: :boolean,
          check_remotes: :boolean
        ]
      )

    opts = merge_opts(global_opts, opts)
    do_health(opts)
  end

  # ===========================================================================
  # IMPLEMENTATION
  # ===========================================================================

  defp do_transfer(operation, source, dest, opts) do
    # Parse source and destination
    {src_remote, src_path} = parse_remote_path(source)
    {dst_remote, dst_path} = parse_remote_path(dest)

    # Build transfer options
    transfer_opts = build_transfer_opts(opts)

    # Apply profile if specified
    transfer_opts =
      if opts[:profile] do
        apply_profile(opts[:profile], transfer_opts)
      else
        transfer_opts
      end

    # Execute based on operation
    result =
      case operation do
        :stream ->
          Laminar.RcloneClient.sync(src_remote <> ":" <> src_path, dst_remote <> ":" <> dst_path, transfer_opts)

        :sync ->
          Laminar.RcloneClient.sync(src_remote <> ":" <> src_path, dst_remote <> ":" <> dst_path, transfer_opts)

        :copy ->
          Laminar.RcloneClient.copy(src_remote <> ":" <> src_path, dst_remote <> ":" <> dst_path, transfer_opts)

        :move ->
          Laminar.RcloneClient.move(src_remote <> ":" <> src_path, dst_remote <> ":" <> dst_path, transfer_opts)
      end

    handle_result(result, opts)
  end

  defp do_list(remote_path, opts) do
    {remote, path} = parse_remote_path(remote_path)

    result = Laminar.RcloneClient.list(remote, path)

    case result do
      {:ok, items} ->
        if opts[:json] do
          IO.puts(Jason.encode!(items, pretty: true))
        else
          Enum.each(items, fn item ->
            if opts[:format] == :long do
              IO.puts(format_long_listing(item))
            else
              IO.puts(item["Path"] || item["Name"])
            end
          end)
        end

      {:error, reason} ->
        error("Failed to list: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp do_tree(remote_path, opts) do
    {remote, path} = parse_remote_path(remote_path)
    max_depth = opts[:level] || 3

    IO.puts(path || remote)
    print_tree_recursive(remote, path, 0, max_depth, opts)
  end

  defp print_tree_recursive(remote, path, depth, max_depth, opts) when depth < max_depth do
    case Laminar.RcloneClient.list(remote, path) do
      {:ok, items} ->
        items
        |> Enum.sort_by(& &1["IsDir"], :desc)
        |> Enum.each(fn item ->
          prefix = String.duplicate("    ", depth) <> "|-- "
          name = item["Name"] || item["Path"]
          is_dir = item["IsDir"] || false

          IO.puts(prefix <> name <> if(is_dir, do: "/", else: ""))

          if is_dir do
            child_path = if path == "", do: name, else: path <> "/" <> name
            print_tree_recursive(remote, child_path, depth + 1, max_depth, opts)
          end
        end)

      _ ->
        :ok
    end
  end

  defp print_tree_recursive(_, _, _, _, _), do: :ok

  defp do_size(remote_path, opts) do
    {remote, path} = parse_remote_path(remote_path)
    # Implementation would call rclone size
    info(opts, "Calculating size for #{remote}:#{path}")
    # TODO: Implement actual size calculation
    IO.puts("Size calculation pending implementation")
  end

  defp do_about(remote_path, opts) do
    {remote, _path} = parse_remote_path(remote_path)

    case Laminar.RcloneClient.about(remote) do
      {:ok, info} ->
        if opts[:json] do
          IO.puts(Jason.encode!(info, pretty: true))
        else
          IO.puts("Remote: #{remote}")
          IO.puts("Total:  #{format_bytes(info["total"] || 0)}")
          IO.puts("Used:   #{format_bytes(info["used"] || 0)}")
          IO.puts("Free:   #{format_bytes(info["free"] || 0)}")
        end

      {:error, reason} ->
        error("Failed to get info: #{inspect(reason)}")
    end
  end

  defp do_check(source, dest, opts) do
    info(opts, "Checking #{source} against #{dest}")
    # TODO: Implement check command
    IO.puts("Check pending implementation")
  end

  defp do_delete(remote_path, opts) do
    {remote, path} = parse_remote_path(remote_path)

    unless opts[:force] do
      IO.write("Delete all files in #{remote}:#{path}? [y/N] ")
      case IO.gets("") do
        "y\n" -> :ok
        "Y\n" -> :ok
        _ ->
          IO.puts("Aborted")
          System.halt(0)
      end
    end

    case Laminar.RcloneClient.delete_file(remote, path) do
      :ok ->
        info(opts, "Deleted #{remote}:#{path}")

      {:error, reason} ->
        error("Failed to delete: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp do_mkdir(remote_path, opts) do
    {remote, path} = parse_remote_path(remote_path)

    case Laminar.RcloneClient.mkdir(remote, path) do
      :ok ->
        info(opts, "Created directory #{remote}:#{path}")

      {:error, reason} ->
        error("Failed to create directory: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp do_rmdir(remote_path, opts) do
    {remote, path} = parse_remote_path(remote_path)
    info(opts, "Removing directory #{remote}:#{path}")
    # TODO: Implement rmdir
    IO.puts("rmdir pending implementation")
  end

  defp do_list_remotes(opts) do
    case Laminar.RcloneClient.list_remotes() do
      {:ok, remotes} ->
        if opts[:json] do
          IO.puts(Jason.encode!(remotes, pretty: true))
        else
          Enum.each(remotes, &IO.puts/1)
        end

      {:error, reason} ->
        error("Failed to list remotes: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp do_config_show(opts) do
    case Laminar.RcloneClient.config_dump() do
      {:ok, config} ->
        if opts[:json] do
          IO.puts(Jason.encode!(config, pretty: true))
        else
          Enum.each(config, fn {name, settings} ->
            IO.puts("[#{name}]")
            Enum.each(settings, fn {k, v} ->
              IO.puts("#{k} = #{v}")
            end)
            IO.puts("")
          end)
        end

      {:error, reason} ->
        error("Failed to show config: #{inspect(reason)}")
    end
  end

  defp do_config_providers(opts) do
    info(opts, "Listing available providers")
    # TODO: Implement providers listing
    IO.puts("Providers listing pending implementation")
  end

  defp do_config_dump(opts) do
    do_config_show(opts)
  end

  defp do_profile_list(opts) do
    profiles = [
      %{name: "high_bandwidth", description: "Maximum throughput for fast connections"},
      %{name: "extreme", description: "Absolute maximum parallelism"},
      %{name: "low_bandwidth", description: "Conservative settings for slow connections"},
      %{name: "mobile", description: "Mobile tethering or metered connections"},
      %{name: "photos", description: "Photo library backup"},
      %{name: "code_backup", description: "Source code backup"},
      %{name: "video_archive", description: "Large video archive"},
      %{name: "documents", description: "Office documents and PDFs"},
      %{name: "full_backup", description: "Complete backup with no filtering"},
      %{name: "cold_storage", description: "Archive to cold storage"},
      %{name: "migration", description: "Full cloud migration"},
      %{name: "sync_mirror", description: "Bi-directional sync mirror"},
      %{name: "incremental", description: "Fast incremental backup"},
      %{name: "verify", description: "Verification mode"}
    ]

    if opts[:json] do
      IO.puts(Jason.encode!(profiles, pretty: true))
    else
      IO.puts("Available transfer profiles:\n")
      Enum.each(profiles, fn p ->
        IO.puts("  #{String.pad_trailing(p.name, 16)} #{p.description}")
      end)
    end
  end

  defp do_profile_show(name, opts) do
    info(opts, "Showing profile: #{name}")
    # TODO: Load from Nickel config
    IO.puts("Profile details pending implementation")
  end

  defp do_profile_use(name, opts) do
    info(opts, "Using profile: #{name}")
    # TODO: Set active profile
    IO.puts("Profile activation pending implementation")
  end

  defp do_job_list(opts) do
    case Laminar.RcloneClient.job_list() do
      {:ok, jobs} ->
        if opts[:json] do
          IO.puts(Jason.encode!(jobs, pretty: true))
        else
          if jobs == [] do
            IO.puts("No active jobs")
          else
            IO.puts("Active jobs:\n")
            Enum.each(jobs, fn job ->
              IO.puts("  #{job["jobid"]}: #{job["group"]} - #{job["status"]}")
            end)
          end
        end

      {:error, reason} ->
        error("Failed to list jobs: #{inspect(reason)}")
    end
  end

  defp do_job_status(id, opts) do
    case Laminar.RcloneClient.job_status(String.to_integer(id)) do
      {:ok, status} ->
        if opts[:json] do
          IO.puts(Jason.encode!(status, pretty: true))
        else
          IO.puts("Job #{id}:")
          IO.puts("  Status:   #{status["status"]}")
          IO.puts("  Started:  #{status["startTime"]}")
          IO.puts("  Duration: #{status["duration"]}")
        end

      {:error, reason} ->
        error("Failed to get job status: #{inspect(reason)}")
    end
  end

  defp do_job_stop(id, opts) do
    case Laminar.RcloneClient.job_stop(String.to_integer(id)) do
      :ok ->
        info(opts, "Stopped job #{id}")

      {:error, reason} ->
        error("Failed to stop job: #{inspect(reason)}")
    end
  end

  defp do_job_stop_all(opts) do
    case Laminar.RcloneClient.job_stop_all() do
      :ok ->
        info(opts, "Stopped all jobs")

      {:error, reason} ->
        error("Failed to stop all jobs: #{inspect(reason)}")
    end
  end

  defp do_stats(opts) do
    case Laminar.RcloneClient.stats() do
      {:ok, stats} ->
        if opts[:json] do
          IO.puts(Jason.encode!(stats, pretty: true))
        else
          IO.puts("Transfer Statistics")
          IO.puts("-------------------")
          IO.puts("Bytes:       #{format_bytes(stats["bytes"] || 0)}")
          IO.puts("Files:       #{stats["files"] || 0}")
          IO.puts("Errors:      #{stats["errors"] || 0}")
          IO.puts("Checks:      #{stats["checks"] || 0}")
          IO.puts("Transfers:   #{stats["transfers"] || 0}")
          IO.puts("Speed:       #{format_bytes(stats["speed"] || 0)}/s")
          IO.puts("Elapsed:     #{stats["elapsedTime"] || "0s"}")
        end

      {:error, reason} ->
        error("Failed to get stats: #{inspect(reason)}")
    end
  end

  defp do_health(opts) do
    checks = [
      {:rclone, check_rclone()},
      {:config, check_config()},
      {:cache, check_cache()}
    ]

    all_ok = Enum.all?(checks, fn {_, status} -> status == :ok end)

    if opts[:json] do
      result = %{
        healthy: all_ok,
        checks:
          Enum.map(checks, fn {name, status} ->
            %{name: name, status: status}
          end)
      }

      IO.puts(Jason.encode!(result, pretty: true))
    else
      IO.puts("Health Check")
      IO.puts("------------")

      Enum.each(checks, fn {name, status} ->
        icon = if status == :ok, do: "[OK]", else: "[FAIL]"
        IO.puts("#{icon} #{name}")
      end)

      IO.puts("")
      IO.puts(if all_ok, do: "System healthy", else: "System unhealthy")
    end

    unless all_ok, do: System.halt(1)
  end

  # ===========================================================================
  # HELPERS
  # ===========================================================================

  defp parse_remote_path(path) when is_binary(path) do
    case String.split(path, ":", parts: 2) do
      [remote, rest] -> {remote, rest}
      [path] -> {"", path}
    end
  end

  defp merge_opts(global, command) do
    Keyword.merge(global, command)
  end

  defp build_transfer_opts(opts) do
    opts
    |> Enum.filter(fn {k, _v} ->
      k in [
        :transfers,
        :checkers,
        :buffer_size,
        :bwlimit,
        :checksum,
        :dry_run,
        :progress,
        :filter_from,
        :fast_list
      ]
    end)
    |> Enum.into(%{})
  end

  defp apply_profile(profile_name, opts) do
    # TODO: Load profile from Nickel config
    profiles = %{
      "high_bandwidth" => %{transfers: 64, checkers: 128, buffer_size: "256M"},
      "extreme" => %{transfers: 128, checkers: 256, buffer_size: "512M"},
      "low_bandwidth" => %{transfers: 4, checkers: 8, buffer_size: "32M", bwlimit: "5M"},
      "mobile" => %{transfers: 2, checkers: 4, buffer_size: "16M", bwlimit: "2M"}
    }

    case Map.get(profiles, profile_name) do
      nil ->
        IO.puts(:stderr, "Warning: Unknown profile '#{profile_name}', using defaults")
        opts

      profile_opts ->
        Map.merge(profile_opts, opts)
    end
  end

  defp handle_result({:ok, result}, opts) do
    if opts[:json] do
      IO.puts(Jason.encode!(result, pretty: true))
    else
      IO.puts("Operation completed successfully")
    end
  end

  defp handle_result({:error, reason}, _opts) do
    error("Operation failed: #{inspect(reason)}")
    System.halt(1)
  end

  defp format_long_listing(item) do
    size = format_bytes(item["Size"] || 0)
    mod_time = item["ModTime"] || "-"
    name = item["Path"] || item["Name"]
    is_dir = if item["IsDir"], do: "d", else: "-"

    "#{is_dir} #{String.pad_leading(size, 10)} #{mod_time} #{name}"
  end

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776, 2)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "0 B"

  defp check_rclone do
    case Laminar.RcloneClient.version() do
      {:ok, _} -> :ok
      _ -> :error
    end
  end

  defp check_config do
    config_path = System.get_env("RCLONE_CONFIG", "/config/rclone/rclone.conf")

    if File.exists?(config_path) do
      :ok
    else
      :error
    end
  end

  defp check_cache do
    cache_path = System.get_env("RCLONE_CACHE_DIR", "/cache")

    if File.dir?(cache_path) do
      :ok
    else
      :error
    end
  end

  defp info(opts, message) do
    unless opts[:quiet] do
      IO.puts(message)
    end
  end

  defp error(message) do
    IO.puts(:stderr, "Error: #{message}")
  end

  # ===========================================================================
  # HELP OUTPUT
  # ===========================================================================

  defp print_version do
    IO.puts("Laminar v#{@version}")
    IO.puts("Cloud-to-cloud streaming relay")
    IO.puts("https://github.com/laminar-dev/laminar")
  end

  defp print_help do
    IO.puts("""
    Laminar v#{@version} - High-velocity cloud streaming relay

    USAGE:
        laminar <command> [options] [arguments]

    GLOBAL OPTIONS:
        -c, --config <path>     Configuration file path
        -p, --profile <name>    Transfer profile to use
        -v, --verbose           Increase verbosity (can be repeated)
        -q, --quiet             Suppress output except errors
            --json              Output in JSON format
            --no-color          Disable colored output
        -h, --help              Show help
            --version           Show version

    TRANSFER COMMANDS:
        stream <src> <dst>      Stream files between cloud providers
        sync <src> <dst>        Synchronize directories
        copy <src> <dst>        Copy files (one-way)
        move <src> <dst>        Move files (copy + delete source)

    LIST COMMANDS:
        ls [remote:path]        List remote contents
        lsl [remote:path]       List with details
        lsd [remote:path]       List directories only
        tree [remote:path]      Tree view of remote

    INFO COMMANDS:
        size <remote:path>      Calculate size of remote path
        about [remote:]         Get remote quota information
        check <src> <dst>       Verify files between locations

    FILE COMMANDS:
        delete <remote:path>    Delete files
        mkdir <remote:path>     Create directory
        rmdir <remote:path>     Remove directory

    MANAGEMENT:
        remotes                 List configured remotes
        config <subcommand>     Manage configuration
        profile <subcommand>    Manage transfer profiles
        job <subcommand>        Manage transfer jobs

    STATUS:
        stats                   Show transfer statistics
        health                  Check system health
        version                 Show version information

    EXAMPLES:
        laminar stream dropbox:photos gdrive:backup/photos
        laminar sync -v --progress dropbox:/ s3:bucket/backup
        laminar copy -p high_bandwidth dropbox:files b2:archive
        laminar ls --json gdrive:documents

    Use 'laminar help <command>' for more information on a command.
    """)
  end

  defp print_command_help(args) do
    case args do
      ["stream"] ->
        print_stream_help()

      ["sync"] ->
        print_sync_help()

      ["copy"] ->
        print_copy_help()

      ["move"] ->
        print_move_help()

      ["ls"] ->
        print_ls_help()

      ["profile"] ->
        print_profile_help()

      ["job"] ->
        print_job_help()

      ["config"] ->
        print_config_help()

      _ ->
        print_help()
    end
  end

  defp print_stream_help do
    IO.puts("""
    laminar stream - Stream files between cloud providers

    USAGE:
        laminar stream [options] <source> <destination>

    TRANSFER OPTIONS:
            --transfers <n>             Number of parallel transfers (default: 32)
            --checkers <n>              Number of parallel checkers (default: 64)
            --multi-thread-streams <n>  Streams per multi-thread transfer (default: 4)
            --buffer-size <size>        Buffer size (default: 128M)
            --bwlimit <rate>            Bandwidth limit (e.g., 10M, 1G)

    FILTER OPTIONS:
            --filter <pattern>          Filter pattern
            --filter-from <file>        Read filter patterns from file
            --include <pattern>         Include pattern
            --exclude <pattern>         Exclude pattern
            --min-size <size>           Minimum file size
            --max-size <size>           Maximum file size

    COMPARISON OPTIONS:
            --checksum                  Use checksums instead of modtime
            --size-only                 Skip based on size only
            --update                    Skip files that are newer on destination
            --ignore-existing           Skip files that exist on destination

    LAMINAR OPTIONS:
            --enable-ghost-links        Enable ghost links for large files
            --ghost-link-threshold <s>  Ghost link size threshold (default: 5G)
            --enable-conversion         Enable format conversion
            --enable-compression        Enable compression

    OTHER OPTIONS:
        -n, --dry-run                   Don't actually transfer
        -P, --progress                  Show progress
            --stats <interval>          Stats update interval

    EXAMPLES:
        laminar stream dropbox:photos gdrive:photos
        laminar stream --transfers 64 --bwlimit 100M s3:bucket b2:backup
        laminar stream --filter "*.jpg" --enable-ghost-links onedrive:/ gdrive:/
    """)
  end

  defp print_sync_help do
    IO.puts("""
    laminar sync - Synchronize directories

    USAGE:
        laminar sync [options] <source> <destination>

    Makes destination identical to source, deleting files not in source.

    DELETE OPTIONS:
            --delete-before        Delete before transfer
            --delete-during        Delete during transfer (default)
            --delete-after         Delete after transfer
            --delete-excluded      Delete excluded files on destination
            --backup-dir <path>    Backup deleted files to this path
            --suffix <suffix>      Suffix for backup files

    (See 'laminar help stream' for other options)
    """)
  end

  defp print_copy_help do
    IO.puts("""
    laminar copy - Copy files (one-way)

    USAGE:
        laminar copy [options] <source> <destination>

    Copies files from source to destination without deleting.

    (See 'laminar help stream' for available options)
    """)
  end

  defp print_move_help do
    IO.puts("""
    laminar move - Move files

    USAGE:
        laminar move [options] <source> <destination>

    Copies files from source to destination, then deletes source files.

    (See 'laminar help stream' for available options)
    """)
  end

  defp print_ls_help do
    IO.puts("""
    laminar ls - List remote contents

    USAGE:
        laminar ls [options] [remote:path]

    OPTIONS:
        -R, --recursive         List recursively
        -d, --max-depth <n>     Maximum depth for recursive listing
            --files-only        Show files only
            --dirs-only         Show directories only
            --format <fmt>      Output format (short, long)
            --human-readable    Human readable sizes

    VARIANTS:
        laminar lsl             List with details (long format)
        laminar lsd             List directories only
        laminar tree            Tree view
    """)
  end

  defp print_profile_help do
    IO.puts("""
    laminar profile - Manage transfer profiles

    USAGE:
        laminar profile <subcommand>

    SUBCOMMANDS:
        list                Show available profiles
        show <name>         Show profile details
        use <name>          Set active profile

    PROFILES:
        high_bandwidth      Maximum throughput for fast connections
        extreme             Absolute maximum parallelism
        low_bandwidth       Conservative settings for slow connections
        mobile              Mobile/metered connections
        photos              Photo library backup
        code_backup         Source code backup
        video_archive       Large video archive
        documents           Office documents
        full_backup         Complete backup
        cold_storage        Archive to cold storage
        migration           Full cloud migration
        sync_mirror         Bi-directional sync
        incremental         Fast incremental backup
        verify              Verification mode
    """)
  end

  defp print_job_help do
    IO.puts("""
    laminar job - Manage transfer jobs

    USAGE:
        laminar job <subcommand>

    SUBCOMMANDS:
        list                List active jobs
        status <id>         Show job status
        stop <id>           Stop a job
        stop-all            Stop all jobs
    """)
  end

  defp print_config_help do
    IO.puts("""
    laminar config - Manage configuration

    USAGE:
        laminar config <subcommand>

    SUBCOMMANDS:
        show                Show current configuration
        providers           List available providers
        dump                Dump configuration
    """)
  end
end
