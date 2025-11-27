# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.Pipeline do
  @moduledoc """
  The Broadway-based processing pipeline for Laminar.

  This implements the "4-Lane Highway" architecture:

    * Lane 1 (Ghost): Creates URL stubs (zero bandwidth)
    * Lane 2 (Express): Direct passthrough for already-compressed files
    * Lane 3 (Squeeze): Lossless compression for text/data files
    * Lane 4 (Refinery): Format conversion (CPU intensive)

  The pipeline ensures that the network is never idle - Express lane files
  start flowing immediately while Refinery files process in the background.
  """

  use Broadway

  alias Laminar.Intelligence
  alias Laminar.GhostLinker
  alias Laminar.Refinery

  require Logger

  @doc """
  Start the pipeline for a transfer job.
  """
  def start_link(opts) do
    Broadway.start_link(__MODULE__,
      name: opts[:name] || __MODULE__,
      producer: [
        module: {Laminar.Pipeline.Producer, opts},
        concurrency: 1
      ],
      processors: [
        # Lane 1 & 2: Fast processing
        default: [concurrency: 8],
        # Lane 3 & 4: CPU-bound processing
        refinery: [concurrency: 4]
      ],
      batchers: [
        # Express uploads (passthrough)
        express: [concurrency: 32, batch_size: 10],
        # Ghost links (very fast)
        ghost: [concurrency: 16, batch_size: 20],
        # Compressed uploads
        compressed: [concurrency: 8, batch_size: 5],
        # Converted uploads
        converted: [concurrency: 4, batch_size: 2]
      ]
    )
  end

  # -- Broadway Callbacks --

  @impl true
  def handle_message(:default, message, context) do
    file = message.data
    action = Intelligence.consult_oracle(file)

    message = Broadway.Message.put_data(message, %{file: file, action: action})

    case action do
      :ignore ->
        Logger.debug("Ignoring: #{file["Path"]}")
        Broadway.Message.failed(message, :ignored)

      {:link, _target} ->
        Broadway.Message.put_batcher(message, :ghost)

      {:transfer, :raw, :immediate} ->
        Broadway.Message.put_batcher(message, :express)

      {:compress, _, _} ->
        # Send to refinery processor first
        message
        |> Broadway.Message.put_batcher(:compressed)
        |> process_in_refinery(context)

      {:convert, _, _} ->
        # Send to refinery processor first
        message
        |> Broadway.Message.put_batcher(:converted)
        |> process_in_refinery(context)

      _ ->
        Broadway.Message.put_batcher(message, :express)
    end
  end

  @impl true
  def handle_batch(:express, messages, _batch_info, context) do
    source = context[:source_remote]
    dest = context[:dest_remote]

    # Build list of files for bulk transfer
    paths =
      messages
      |> Enum.map(fn msg -> msg.data.file["Path"] end)
      |> Enum.join("\n")

    # Write to temp file for --files-from
    list_file = "/tmp/laminar_express_#{:erlang.unique_integer([:positive])}"
    File.write!(list_file, paths)

    # Execute bulk transfer
    case System.cmd("rclone", [
           "copy",
           source,
           dest,
           "--files-from",
           list_file,
           "--transfers",
           "32",
           "--progress"
         ]) do
      {_, 0} ->
        File.rm(list_file)
        messages

      {output, code} ->
        Logger.error("Express batch failed (#{code}): #{output}")
        File.rm(list_file)
        Enum.map(messages, &Broadway.Message.failed(&1, {:transfer_failed, code}))
    end
  end

  @impl true
  def handle_batch(:ghost, messages, _batch_info, context) do
    source = context[:source_remote]
    dest = context[:dest_remote]

    files = Enum.map(messages, fn msg -> msg.data.file end)
    GhostLinker.create_stubs(files, source, dest)

    messages
  end

  @impl true
  def handle_batch(:compressed, messages, _batch_info, context) do
    dest = context[:dest_remote]

    # Files should already be compressed in the buffer by the processor
    Enum.map(messages, fn msg ->
      case msg.data[:processed_path] do
        nil ->
          Broadway.Message.failed(msg, :not_processed)

        path ->
          # Upload the compressed file
          file = msg.data.file
          dest_path = file["Path"] <> ".zst"

          case System.cmd("rclone", ["copyto", path, "#{dest}#{dest_path}"]) do
            {_, 0} ->
              File.rm(path)
              msg

            {_, code} ->
              File.rm(path)
              Broadway.Message.failed(msg, {:upload_failed, code})
          end
      end
    end)
  end

  @impl true
  def handle_batch(:converted, messages, _batch_info, context) do
    dest = context[:dest_remote]

    Enum.map(messages, fn msg ->
      case msg.data[:processed_path] do
        nil ->
          Broadway.Message.failed(msg, :not_processed)

        path ->
          file = msg.data.file
          {_, format, _} = msg.data.action
          ext = format_extension(format)
          dest_path = Path.rootname(file["Path"]) <> ext

          case System.cmd("rclone", ["copyto", path, "#{dest}#{dest_path}"]) do
            {_, 0} ->
              File.rm(path)
              msg

            {_, code} ->
              File.rm(path)
              Broadway.Message.failed(msg, {:upload_failed, code})
          end
      end
    end)
  end

  # -- Private Helpers --

  defp process_in_refinery(message, context) do
    file = message.data.file
    action = message.data.action
    source = context[:source_remote]
    dest = context[:dest_remote]

    case Refinery.process(file, action, source, dest) do
      {:ok, :passthrough} ->
        message

      {:ok, path} ->
        Broadway.Message.update_data(message, &Map.put(&1, :processed_path, path))

      {:error, reason} ->
        Broadway.Message.failed(message, reason)
    end
  end

  defp format_extension(:flac), do: ".flac"
  defp format_extension(:webp), do: ".webp"
  defp format_extension(_), do: ""
end

defmodule Laminar.Pipeline.Producer do
  @moduledoc """
  Broadway producer that reads file listings from Rclone.
  """

  use GenStage

  alias Laminar.RcloneClient

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    source = opts[:source_remote]
    {:producer, %{source: source, files: [], done: false}}
  end

  @impl true
  def handle_demand(demand, %{done: true} = state) when demand > 0 do
    {:noreply, [], state}
  end

  @impl true
  def handle_demand(demand, %{files: []} = state) when demand > 0 do
    # Fetch more files from source
    case RcloneClient.lsjson(state.source, recursive: true) do
      {:ok, files} ->
        {to_send, remaining} = Enum.split(files, demand)

        messages =
          Enum.map(to_send, fn file ->
            %Broadway.Message{
              data: file,
              acknowledger: {__MODULE__, :ack_id, :ack_data}
            }
          end)

        {:noreply, messages, %{state | files: remaining, done: remaining == []}}

      {:error, _reason} ->
        {:noreply, [], %{state | done: true}}
    end
  end

  @impl true
  def handle_demand(demand, %{files: files} = state) when demand > 0 do
    {to_send, remaining} = Enum.split(files, demand)

    messages =
      Enum.map(to_send, fn file ->
        %Broadway.Message{
          data: file,
          acknowledger: {__MODULE__, :ack_id, :ack_data}
        }
      end)

    {:noreply, messages, %{state | files: remaining, done: remaining == []}}
  end

  # Acknowledger callback (required by Broadway)
  def ack(:ack_id, _successful, _failed) do
    :ok
  end
end
