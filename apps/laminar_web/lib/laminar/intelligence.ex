# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.Intelligence do
  @moduledoc """
  The Logic Engine. Uses declarative pattern matching to decide the fate of a file.

  Behaves like a mini-expert system, using Elixir's pattern matching as a
  high-performance alternative to external logic solvers (Prolog/miniKanren).

  ## Actions

  - `:transfer` - Stream the bytes directly
  - `:ignore` - The "Bullshit" filter (skip this file)
  - `{:link, target}` - Create a Ghost Link instead of transferring
  - `{:convert, format, priority}` - Convert before transfer
  - `{:compress, algo, priority}` - Compress before transfer

  ## Priorities

  - `:immediate` - Express lane, starts now
  - `:high_priority` - Fast processing lane
  - `:medium_priority` - Standard processing
  - `:low_priority` - Background processing (CPU intensive)
  """

  @moduledoc since: "1.0.0"

  # -- The Facts (Types) --

  defstruct name: "",
            size: 0,
            extension: "",
            path: "",
            mime: ""

  @type t :: %__MODULE__{
          name: String.t(),
          size: non_neg_integer(),
          extension: String.t(),
          path: String.t(),
          mime: String.t()
        }

  @type action ::
          :transfer
          | :ignore
          | {:link, atom() | String.t()}
          | {:convert, atom(), priority()}
          | {:compress, atom(), priority()}

  @type priority :: :immediate | :high_priority | :medium_priority | :low_priority

  @type ruleset :: :default | :archive_mode | :code_clean | :full_refinery

  # Size thresholds
  @ghost_link_threshold 5_368_709_120
  @massive_file_threshold 50_000_000_000

  # -- The API --

  @doc """
  Decides the action for a given file based on the rule set.

  ## Examples

      iex> file = %{name: "app.js", size: 1024, extension: ".js", path: "/src/app.js", mime: "text/javascript"}
      iex> Laminar.Intelligence.consult_oracle(file)
      {:transfer, :raw, :immediate}

      iex> file = %{name: "node_modules", size: 0, extension: "", path: "/node_modules", mime: ""}
      iex> Laminar.Intelligence.consult_oracle(file)
      :ignore
  """
  @spec consult_oracle(map() | t(), ruleset()) :: action()
  def consult_oracle(file_metadata, ruleset \\ :default) do
    file_metadata
    |> normalize()
    |> run_rules(ruleset)
  end

  @doc """
  Batch process multiple files and partition by action type.

  Returns a map with keys for each action type.
  """
  @spec partition_files([map()], ruleset()) :: %{
          transfer: [map()],
          ignore: [map()],
          link: [map()],
          convert: [map()],
          compress: [map()]
        }
  def partition_files(files, ruleset \\ :default) do
    files
    |> Enum.map(fn file -> {file, consult_oracle(file, ruleset)} end)
    |> Enum.reduce(
      %{transfer: [], ignore: [], link: [], convert: [], compress: []},
      fn
        {file, :ignore}, acc ->
          %{acc | ignore: [file | acc.ignore]}

        {file, {:transfer, _, _}}, acc ->
          %{acc | transfer: [file | acc.transfer]}

        {file, {:link, _}}, acc ->
          %{acc | link: [file | acc.link]}

        {file, {:convert, _, _}}, acc ->
          %{acc | convert: [file | acc.convert]}

        {file, {:compress, _, _}}, acc ->
          %{acc | compress: [file | acc.compress]}

        {file, _}, acc ->
          %{acc | transfer: [file | acc.transfer]}
      end
    )
  end

  # -- The Logic Gates (Declarative Rules) --

  # Rule 1: The "Bullshit" Filter (Immediate Rejection)
  defp run_rules(%{extension: ext}, _) when ext in ~w(.tmp .log .bak .DS_Store Thumbs.db) do
    :ignore
  end

  defp run_rules(%{name: name}, _) when name in ~w(node_modules _build target deps vendor .git .svn) do
    :ignore
  end

  defp run_rules(%{name: name}, _) when name in ~w(__pycache__ .sass-cache .cache .gradle .idea .vscode) do
    :ignore
  end

  # Rule 2: The "Ghost Link" (Huge Files > 5GB)
  # If it is massive, don't move it. Link it.
  defp run_rules(%{size: size}, _) when size > @ghost_link_threshold do
    {:link, :source_location}
  end

  # Rule 3: The "Third Location" (Cold Storage for massive RAW video)
  defp run_rules(%{extension: ".r3d", size: size}, _) when size > @massive_file_threshold do
    {:link, :cold_storage}
  end

  defp run_rules(%{extension: ".mkv", size: size}, :archive_mode) when size > @ghost_link_threshold do
    {:link, :cold_storage}
  end

  # Rule 4: Audio Conversion (WAV/AIFF -> FLAC)
  defp run_rules(%{extension: ext}, _) when ext in ~w(.wav .aiff .aif) do
    {:convert, :flac, :medium_priority}
  end

  # Rule 5: Image Conversion (BMP/TIFF -> WebP)
  defp run_rules(%{extension: ext}, _) when ext in ~w(.bmp .tiff .tif) do
    {:convert, :webp, :low_priority}
  end

  # Rule 6: Text/Code Compression (SQL, CSV, large JSON)
  defp run_rules(%{extension: ".sql", size: size}, _) when size > 10_000_000 do
    {:compress, :zstd, :high_priority}
  end

  defp run_rules(%{extension: ".csv", size: size}, _) when size > 10_000_000 do
    {:compress, :zstd, :high_priority}
  end

  defp run_rules(%{extension: ".json", size: size}, _) when size > 10_000_000 do
    {:compress, :zstd, :medium_priority}
  end

  # Rule 7: Already Compressed Media -> Express Lane
  defp run_rules(%{extension: ext}, _) when ext in ~w(.mp4 .mkv .avi .mov .webm) do
    {:transfer, :raw, :immediate}
  end

  defp run_rules(%{extension: ext}, _) when ext in ~w(.jpg .jpeg .png .gif .webp) do
    {:transfer, :raw, :immediate}
  end

  defp run_rules(%{extension: ext}, _) when ext in ~w(.mp3 .aac .flac .ogg .opus) do
    {:transfer, :raw, :immediate}
  end

  defp run_rules(%{extension: ext}, _) when ext in ~w(.zip .tar .gz .7z .rar .xz) do
    {:transfer, :raw, :immediate}
  end

  defp run_rules(%{extension: ext}, _) when ext in ~w(.docx .xlsx .pptx .pdf) do
    {:transfer, :raw, :immediate}
  end

  # Rule 8: Source Code (Keep as-is for versioning integrity)
  defp run_rules(%{extension: ext}, _)
       when ext in ~w(.ex .exs .rs .go .py .js .ts .rb .java .c .cpp .h .hpp) do
    {:transfer, :raw, :immediate}
  end

  # Rule 9: Configuration files (Keep as-is)
  defp run_rules(%{extension: ext}, _)
       when ext in ~w(.json .yaml .yml .toml .xml .ini .cfg .conf) do
    {:transfer, :raw, :immediate}
  end

  # Default: If no other rules match, move the data.
  defp run_rules(_, _), do: {:transfer, :raw, :immediate}

  # -- Helpers --

  defp normalize(params) when is_struct(params, __MODULE__), do: params

  defp normalize(params) when is_map(params) do
    %__MODULE__{
      name: params[:name] || params["name"] || params["Name"] || "",
      size: params[:size] || params["size"] || params["Size"] || 0,
      extension: get_extension(params),
      path: params[:path] || params["path"] || params["Path"] || "",
      mime: params[:mime] || params["MimeType"] || params["mime_type"] || ""
    }
  end

  defp get_extension(params) do
    ext = params[:extension] || params["extension"] || ""

    if ext != "" do
      ext
    else
      name = params[:name] || params["name"] || params["Name"] || ""
      Path.extname(name) |> String.downcase()
    end
  end
end
