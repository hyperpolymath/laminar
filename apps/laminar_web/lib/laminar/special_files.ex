defmodule Laminar.SpecialFiles do
  @moduledoc """
  Detection and handling of cloud-provider-specific special files.

  These files either:
  - Only work on their native platform (Google Docs, Sheets, etc.)
  - Have special semantics (Dropbox placeholders, OneDrive shortcuts)
  - Require special handling (symlinks, hardlinks, sparse files)
  - May cause issues during transfer

  Provides:
  - Detection of special file types
  - Recommendations for handling
  - Export alternatives where available
  """

  @type file_info :: %{
    path: String.t(),
    type: atom(),
    provider: atom(),
    transferable: boolean(),
    recommendation: String.t(),
    export_formats: [String.t()] | nil
  }

  # Google Workspace file extensions (these are just pointers, not actual files)
  @google_doc_extensions [
    ".gdoc",      # Google Docs
    ".gsheet",    # Google Sheets
    ".gslides",   # Google Slides
    ".gdraw",     # Google Drawings
    ".gform",     # Google Forms
    ".gsite",     # Google Sites
    ".gjam",      # Google Jamboard
    ".gmap"       # Google My Maps
  ]

  # Google Workspace MIME types (from API)
  @google_mimetypes %{
    "application/vnd.google-apps.document" => :gdoc,
    "application/vnd.google-apps.spreadsheet" => :gsheet,
    "application/vnd.google-apps.presentation" => :gslides,
    "application/vnd.google-apps.drawing" => :gdraw,
    "application/vnd.google-apps.form" => :gform,
    "application/vnd.google-apps.site" => :gsite,
    "application/vnd.google-apps.jam" => :gjam,
    "application/vnd.google-apps.map" => :gmap,
    "application/vnd.google-apps.folder" => :folder,
    "application/vnd.google-apps.shortcut" => :shortcut
  }

  # Export formats for Google types
  @google_export_formats %{
    gdoc: ["docx", "odt", "pdf", "txt", "html", "rtf", "epub"],
    gsheet: ["xlsx", "ods", "pdf", "csv", "tsv"],
    gslides: ["pptx", "odp", "pdf", "txt"],
    gdraw: ["svg", "png", "pdf", "jpg"]
  }

  # Dropbox special files
  @dropbox_extensions [
    ".dropbox",           # Placeholder/sync marker
    ".dropbox.attr"       # Extended attributes
  ]

  # OneDrive special files
  @onedrive_extensions [
    ".onedrive",          # Placeholder
    ".lnk"                # Windows shortcuts (often synced)
  ]

  # iCloud special files
  @icloud_extensions [
    ".icloud"             # Placeholder for files not downloaded
  ]

  # macOS special files
  @macos_special [
    ".DS_Store",
    ".AppleDouble",
    ".LSOverride",
    "._*"                 # Resource fork files
  ]

  # Windows special files
  @windows_special [
    "Thumbs.db",
    "desktop.ini",
    "*.lnk"
  ]

  @doc """
  Scan a list of files and identify special/problematic ones.

  Accepts rclone lsjson output format.
  """
  @spec scan([map()]) :: [file_info()]
  def scan(files) when is_list(files) do
    files
    |> Enum.map(&analyze_file/1)
    |> Enum.filter(& &1)  # Remove nils (normal files)
  end

  @doc """
  Check if a single file path is a special file.
  """
  @spec is_special?(String.t()) :: boolean()
  def is_special?(path) do
    analyze_path(path) != nil
  end

  @doc """
  Get handling recommendation for a special file type.
  """
  @spec get_recommendation(atom()) :: String.t()
  def get_recommendation(type) do
    case type do
      t when t in [:gdoc, :gsheet, :gslides, :gdraw] ->
        exports = Map.get(@google_export_formats, type, [])
        "Export to #{Enum.join(exports, "/")} before transfer, or use rclone --drive-export-formats"

      :gform ->
        "Google Forms cannot be exported - recreate manually or use Google Takeout"

      :gsite ->
        "Google Sites cannot be exported directly - use Google Takeout or manual backup"

      :shortcut ->
        "Google Drive shortcut - will not transfer, resolve to actual file"

      :dropbox_placeholder ->
        "Dropbox placeholder - ensure file is synced locally before transfer"

      :onedrive_placeholder ->
        "OneDrive placeholder - ensure file is downloaded before transfer"

      :icloud_placeholder ->
        "iCloud placeholder - download file from iCloud before transfer"

      :macos_metadata ->
        "macOS metadata file - usually safe to exclude from transfer"

      :windows_metadata ->
        "Windows metadata file - usually safe to exclude from transfer"

      :symlink ->
        "Symbolic link - may not preserve correctly across cloud providers"

      :sparse_file ->
        "Sparse file - may expand to full size during transfer"

      _ ->
        "Unknown special file type - verify after transfer"
    end
  end

  @doc """
  Get rclone flags needed to handle special files for a provider.
  """
  @spec get_rclone_flags(atom()) :: [String.t()]
  def get_rclone_flags(provider) do
    case provider do
      :gdrive ->
        [
          # Export Google Docs to Office formats
          "--drive-export-formats", "docx,xlsx,pptx,svg",
          # Skip Google Apps files that can't be exported
          "--drive-skip-gdocs"
        ]

      :dropbox ->
        [
          # Handle Dropbox-specific behavior
        ]

      :onedrive ->
        [
          # Handle OneDrive shortcuts
          "--onedrive-link-scope", "anonymous"
        ]

      _ ->
        []
    end
  end

  @doc """
  Generate filter rules to exclude common problematic files.
  """
  @spec exclusion_filters() :: [String.t()]
  def exclusion_filters do
    [
      # macOS
      "- .DS_Store",
      "- .AppleDouble",
      "- .LSOverride",
      "- ._*",
      "- .Spotlight-V100",
      "- .Trashes",
      "- .fseventsd",

      # Windows
      "- Thumbs.db",
      "- desktop.ini",
      "- $RECYCLE.BIN/",
      "- System Volume Information/",

      # Linux
      "- .Trash-*",

      # Version control
      "- .git/",
      "- .svn/",
      "- .hg/",

      # IDE/Editor
      "- .idea/",
      "- .vscode/",
      "- *.swp",
      "- *~",

      # Cloud sync markers
      "- *.dropbox",
      "- *.dropbox.attr",
      "- .dropbox.cache/",
      "- *.icloud"
    ]
  end

  # Private functions

  defp analyze_file(file) when is_map(file) do
    path = Map.get(file, "Path", Map.get(file, "Name", ""))
    mime_type = Map.get(file, "MimeType")
    is_dir = Map.get(file, "IsDir", false)

    cond do
      # Check MIME type first (more reliable for Google)
      mime_type && Map.has_key?(@google_mimetypes, mime_type) ->
        type = Map.get(@google_mimetypes, mime_type)
        build_info(path, type, :google, type != :folder)

      # Check by extension
      true ->
        analyze_path(path)
    end
  end

  defp analyze_path(path) do
    ext = Path.extname(path) |> String.downcase()
    basename = Path.basename(path)

    cond do
      # Google Workspace
      ext in @google_doc_extensions ->
        type = extension_to_type(ext)
        build_info(path, type, :google, true)

      # Dropbox
      ext in @dropbox_extensions or String.starts_with?(basename, ".dropbox") ->
        build_info(path, :dropbox_placeholder, :dropbox, false)

      # OneDrive
      ext in @onedrive_extensions ->
        build_info(path, :onedrive_placeholder, :onedrive, false)

      # iCloud
      ext in @icloud_extensions ->
        build_info(path, :icloud_placeholder, :icloud, false)

      # macOS metadata
      basename in [".DS_Store", ".AppleDouble", ".LSOverride"] or
        String.starts_with?(basename, "._") ->
        build_info(path, :macos_metadata, :macos, true)

      # Windows metadata
      basename in ["Thumbs.db", "desktop.ini"] ->
        build_info(path, :windows_metadata, :windows, true)

      # Normal file
      true ->
        nil
    end
  end

  defp extension_to_type(ext) do
    case ext do
      ".gdoc" -> :gdoc
      ".gsheet" -> :gsheet
      ".gslides" -> :gslides
      ".gdraw" -> :gdraw
      ".gform" -> :gform
      ".gsite" -> :gsite
      ".gjam" -> :gjam
      ".gmap" -> :gmap
      _ -> :unknown
    end
  end

  defp build_info(path, type, provider, transferable) do
    %{
      path: path,
      type: type,
      provider: provider,
      transferable: transferable,
      recommendation: get_recommendation(type),
      export_formats: Map.get(@google_export_formats, type)
    }
  end
end
