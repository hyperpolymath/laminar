defmodule Laminar.FilterEngine do
  @moduledoc """
  Advanced filtering with regex/glob patterns for include/exclude.

  Supports:
  - Glob patterns (*.txt, **/*.jpg)
  - Regular expressions
  - agrep-style approximate matching
  - Directory-based filtering
  - Size-based filtering
  - Date-based filtering
  - Combined filter rules

  Compatible with rclone filter syntax.
  """

  defstruct [
    :include_patterns,
    :exclude_patterns,
    :include_dirs,
    :exclude_dirs,
    :min_size,
    :max_size,
    :min_age,
    :max_age,
    :filter_rules
  ]

  @type pattern :: String.t() | Regex.t()
  @type t :: %__MODULE__{}

  @doc """
  Create a new filter engine from options.

  Options:
  - `:include` - List of patterns to include
  - `:exclude` - List of patterns to exclude
  - `:include_dirs` - Directories to include
  - `:exclude_dirs` - Directories to exclude
  - `:min_size` - Minimum file size (bytes or string like "10MB")
  - `:max_size` - Maximum file size
  - `:min_age` - Minimum file age (duration string like "7d", "1w")
  - `:max_age` - Maximum file age
  - `:filter_file` - Path to filter file (rclone format)
  """
  def new(opts \\ []) do
    %__MODULE__{
      include_patterns: parse_patterns(Keyword.get(opts, :include, [])),
      exclude_patterns: parse_patterns(Keyword.get(opts, :exclude, [])),
      include_dirs: Keyword.get(opts, :include_dirs, []),
      exclude_dirs: Keyword.get(opts, :exclude_dirs, []),
      min_size: parse_size(Keyword.get(opts, :min_size)),
      max_size: parse_size(Keyword.get(opts, :max_size)),
      min_age: parse_age(Keyword.get(opts, :min_age)),
      max_age: parse_age(Keyword.get(opts, :max_age)),
      filter_rules: load_filter_file(Keyword.get(opts, :filter_file))
    }
  end

  @doc """
  Check if a file matches the filter criteria (should be included).
  """
  def matches?(%__MODULE__{} = filter, file) when is_map(file) do
    path = Map.get(file, "Path", Map.get(file, "Name", ""))
    size = Map.get(file, "Size", 0)
    mod_time = Map.get(file, "ModTime")

    # Apply all checks
    cond do
      # Check exclude patterns first (they take precedence)
      matches_any_pattern?(path, filter.exclude_patterns) -> false

      # Check excluded directories
      in_excluded_dir?(path, filter.exclude_dirs) -> false

      # Check size constraints
      not size_matches?(size, filter.min_size, filter.max_size) -> false

      # Check age constraints
      not age_matches?(mod_time, filter.min_age, filter.max_age) -> false

      # If include patterns specified, must match one
      length(filter.include_patterns) > 0 ->
        matches_any_pattern?(path, filter.include_patterns)

      # If include dirs specified, must be in one
      length(filter.include_dirs) > 0 ->
        in_included_dir?(path, filter.include_dirs)

      # No include patterns = include all (that passed exclude checks)
      true -> true
    end
  end

  def matches?(%__MODULE__{} = filter, path) when is_binary(path) do
    matches?(filter, %{"Path" => path})
  end

  @doc """
  Filter a list of files, returning only those that match.
  """
  def filter_files(%__MODULE__{} = filter, files) when is_list(files) do
    Enum.filter(files, &matches?(filter, &1))
  end

  @doc """
  Convert filter to rclone command line arguments.
  """
  def to_rclone_args(%__MODULE__{} = filter) do
    args = []

    # Include patterns
    args = filter.include_patterns
    |> Enum.reduce(args, fn pattern, acc ->
      ["--include", pattern_to_string(pattern) | acc]
    end)

    # Exclude patterns
    args = filter.exclude_patterns
    |> Enum.reduce(args, fn pattern, acc ->
      ["--exclude", pattern_to_string(pattern) | acc]
    end)

    # Size filters
    args = case filter.min_size do
      nil -> args
      size -> ["--min-size", "#{size}" | args]
    end

    args = case filter.max_size do
      nil -> args
      size -> ["--max-size", "#{size}" | args]
    end

    # Age filters
    args = case filter.min_age do
      nil -> args
      age -> ["--min-age", format_age(age) | args]
    end

    args = case filter.max_age do
      nil -> args
      age -> ["--max-age", format_age(age) | args]
    end

    Enum.reverse(args)
  end

  @doc """
  Parse a filter rule string (rclone format).

  Examples:
  - "+ *.txt" -> include txt files
  - "- *.log" -> exclude log files
  - "+ /photos/**" -> include photos directory
  - "- .git/" -> exclude .git directories
  """
  def parse_rule(rule) when is_binary(rule) do
    rule = String.trim(rule)

    cond do
      String.starts_with?(rule, "+ ") ->
        {:include, parse_pattern(String.slice(rule, 2..-1//1))}

      String.starts_with?(rule, "- ") ->
        {:exclude, parse_pattern(String.slice(rule, 2..-1//1))}

      String.starts_with?(rule, "#") ->
        {:comment, rule}

      rule == "" ->
        {:empty, nil}

      true ->
        # Default to include
        {:include, parse_pattern(rule)}
    end
  end

  @doc """
  Approximate string matching (agrep-style).

  Returns true if pattern matches with up to `max_errors` differences.
  Uses Levenshtein distance for fuzzy matching.
  """
  def fuzzy_match?(text, pattern, max_errors \\ 2) do
    text = String.downcase(text)
    pattern = String.downcase(pattern)

    # For short patterns, use exact substring check with distance
    if String.length(pattern) <= 5 do
      String.contains?(text, pattern)
    else
      # Check if any substring matches within error threshold
      min_distance = text
      |> String.graphemes()
      |> Enum.chunk_every(String.length(pattern), 1, :discard)
      |> Enum.map(&Enum.join/1)
      |> Enum.map(&levenshtein_distance(&1, pattern))
      |> Enum.min(fn -> max_errors + 1 end)

      min_distance <= max_errors
    end
  end

  @doc """
  Build a filter from a human-readable query string.

  Examples:
  - "*.jpg in photos/ bigger than 1MB"
  - "not .git/ and *.{js,ts} modified today"
  """
  def from_query(query) when is_binary(query) do
    # Simple parser for common queries
    parts = String.split(query, ~r/\s+and\s+/i)

    opts = Enum.reduce(parts, [], fn part, acc ->
      cond do
        String.match?(part, ~r/bigger than|larger than|>/i) ->
          [_, size] = Regex.run(~r/(?:bigger|larger) than\s+(\S+)/i, part) || [nil, nil]
          if size, do: [{:min_size, size} | acc], else: acc

        String.match?(part, ~r/smaller than|less than|</i) ->
          [_, size] = Regex.run(~r/(?:smaller|less) than\s+(\S+)/i, part) || [nil, nil]
          if size, do: [{:max_size, size} | acc], else: acc

        String.match?(part, ~r/^not\s+/i) ->
          pattern = String.replace(part, ~r/^not\s+/i, "")
          excludes = Keyword.get(acc, :exclude, [])
          Keyword.put(acc, :exclude, [pattern | excludes])

        String.match?(part, ~r/\*|\?/) ->
          # Glob pattern
          includes = Keyword.get(acc, :include, [])
          Keyword.put(acc, :include, [part | includes])

        String.match?(part, ~r/^in\s+/i) ->
          dir = String.replace(part, ~r/^in\s+/i, "")
          dirs = Keyword.get(acc, :include_dirs, [])
          Keyword.put(acc, :include_dirs, [dir | dirs])

        true ->
          acc
      end
    end)

    new(opts)
  end

  # Private functions

  defp parse_patterns(patterns) when is_list(patterns) do
    Enum.map(patterns, &parse_pattern/1)
  end

  defp parse_pattern(pattern) when is_binary(pattern) do
    cond do
      # Regex pattern (starts with ~)
      String.starts_with?(pattern, "~") ->
        pattern
        |> String.slice(1..-1//1)
        |> Regex.compile!()

      # Glob pattern - convert to regex
      String.contains?(pattern, ["*", "?", "[", "{"]) ->
        glob_to_regex(pattern)

      # Plain string
      true ->
        pattern
    end
  end

  defp glob_to_regex(glob) do
    regex_str = glob
    |> String.replace(".", "\\.")
    |> String.replace("**", "<<<DOUBLESTAR>>>")
    |> String.replace("*", "[^/]*")
    |> String.replace("<<<DOUBLESTAR>>>", ".*")
    |> String.replace("?", ".")
    |> String.replace(~r/\{([^}]+)\}/, fn _, inner ->
      "(#{String.replace(inner, ",", "|")})"
    end)

    Regex.compile!("^#{regex_str}$")
  end

  defp pattern_to_string(%Regex{} = regex), do: "~#{Regex.source(regex)}"
  defp pattern_to_string(pattern) when is_binary(pattern), do: pattern

  defp matches_any_pattern?(path, patterns) do
    Enum.any?(patterns, fn pattern ->
      case pattern do
        %Regex{} = regex -> Regex.match?(regex, path)
        str when is_binary(str) -> String.contains?(path, str) or path == str
      end
    end)
  end

  defp in_excluded_dir?(path, dirs) do
    Enum.any?(dirs, fn dir ->
      String.starts_with?(path, dir) or String.contains?(path, "/#{dir}/")
    end)
  end

  defp in_included_dir?(path, dirs) do
    Enum.any?(dirs, fn dir ->
      String.starts_with?(path, dir) or String.contains?(path, "/#{dir}/")
    end)
  end

  defp size_matches?(_size, nil, nil), do: true
  defp size_matches?(size, min, nil), do: size >= min
  defp size_matches?(size, nil, max), do: size <= max
  defp size_matches?(size, min, max), do: size >= min and size <= max

  defp age_matches?(_mod_time, nil, nil), do: true
  defp age_matches?(nil, _, _), do: true
  defp age_matches?(mod_time, min_age, max_age) do
    case DateTime.from_iso8601(mod_time) do
      {:ok, dt, _} ->
        now = DateTime.utc_now()
        age_seconds = DateTime.diff(now, dt)

        min_ok = min_age == nil or age_seconds >= min_age
        max_ok = max_age == nil or age_seconds <= max_age
        min_ok and max_ok

      _ -> true
    end
  end

  defp parse_size(nil), do: nil
  defp parse_size(size) when is_integer(size), do: size
  defp parse_size(size) when is_binary(size) do
    case Regex.run(~r/^(\d+(?:\.\d+)?)\s*(B|KB|MB|GB|TB)?$/i, size) do
      [_, num, unit] ->
        n = String.to_float(num)
        multiplier = case String.upcase(unit || "B") do
          "B" -> 1
          "KB" -> 1024
          "MB" -> 1024 * 1024
          "GB" -> 1024 * 1024 * 1024
          "TB" -> 1024 * 1024 * 1024 * 1024
        end
        round(n * multiplier)
      _ -> nil
    end
  end

  defp parse_age(nil), do: nil
  defp parse_age(age) when is_integer(age), do: age
  defp parse_age(age) when is_binary(age) do
    case Regex.run(~r/^(\d+)\s*(s|m|h|d|w|M|y)?$/i, age) do
      [_, num, unit] ->
        n = String.to_integer(num)
        seconds = case String.downcase(unit || "s") do
          "s" -> 1
          "m" -> 60
          "h" -> 3600
          "d" -> 86400
          "w" -> 604800
          "M" -> 2592000  # 30 days
          "y" -> 31536000  # 365 days
        end
        n * seconds
      _ -> nil
    end
  end

  defp format_age(seconds) when is_integer(seconds) do
    cond do
      rem(seconds, 31536000) == 0 -> "#{div(seconds, 31536000)}y"
      rem(seconds, 604800) == 0 -> "#{div(seconds, 604800)}w"
      rem(seconds, 86400) == 0 -> "#{div(seconds, 86400)}d"
      rem(seconds, 3600) == 0 -> "#{div(seconds, 3600)}h"
      rem(seconds, 60) == 0 -> "#{div(seconds, 60)}m"
      true -> "#{seconds}s"
    end
  end

  defp load_filter_file(nil), do: []
  defp load_filter_file(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.map(&parse_rule/1)
        |> Enum.reject(fn {type, _} -> type in [:comment, :empty] end)
      {:error, _} -> []
    end
  end

  # Simple Levenshtein distance for fuzzy matching
  defp levenshtein_distance(s1, s2) do
    s1_len = String.length(s1)
    s2_len = String.length(s2)

    if s1_len == 0 do
      s2_len
    else
      if s2_len == 0 do
        s1_len
      else
        # Build matrix
        s1_chars = String.graphemes(s1)
        s2_chars = String.graphemes(s2)

        matrix = for i <- 0..s1_len, into: %{} do
          for j <- 0..s2_len, into: %{} do
            cond do
              i == 0 -> {{i, j}, j}
              j == 0 -> {{i, j}, i}
              true -> {{i, j}, 0}
            end
          end
        end
        |> Enum.reduce(%{}, fn map, acc -> Map.merge(acc, map) end)

        # Fill matrix
        final_matrix = Enum.reduce(1..s1_len, matrix, fn i, acc ->
          Enum.reduce(1..s2_len, acc, fn j, acc2 ->
            cost = if Enum.at(s1_chars, i-1) == Enum.at(s2_chars, j-1), do: 0, else: 1
            val = Enum.min([
              acc2[{i-1, j}] + 1,      # deletion
              acc2[{i, j-1}] + 1,      # insertion
              acc2[{i-1, j-1}] + cost  # substitution
            ])
            Map.put(acc2, {i, j}, val)
          end)
        end)

        final_matrix[{s1_len, s2_len}]
      end
    end
  end
end
