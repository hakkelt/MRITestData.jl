# CMRxRecon2024 catalog. Unlike OCMR/mridata, there is no remote index to scrape:
# the catalog is a *static* offset map, generated once from the local archives
# (see scripts/generate_cmrxrecon2024_map.jl) and committed to the package as
# `data/cmrxrecon2024_map.csv`. Each row records where one fully-sampled `.mat` file
# lives inside one of the two split archives — `archive` tags it "training" or
# "aftercompetition" — as which fragment(s) + byte offsets + ZIP local-header length +
# compressed size, plus pre-computed metadata (modality, subject, acquisition
# parameters). The runtime uses this to pull and inflate individual files with HTTP
# range requests instead of downloading the multi-hundred-GB archives.
#
# Map CSV schema (see scripts/annotate_cmrxrecon2024_map.jl for column definitions):
#   path, start_frag, start_off, end_frag, end_off, lfh_size, compressed_size,
#   uncompressed_size, compression, archive,
#   sampling, coil_type, modality, dataset_set, subject, matfile,
#   hardware_coils, field_strength, fov_x, fov_y, nx, ny, nz, nt, tr_ms, te_ms, flip_angle
#
# Note: hardware_coils is the physical receiver element count (30-38 in this dataset).
# The stored k-space arrays always have 10 virtual (SVD-compressed) coil channels for
# MultiCoil acquisitions — `receiver_channels` reflects that stored channel count (10/1),
# with `coil_data = :derived` recording that they are not the physical elements
# (`hardware_coils`, kept in `extra["multi_coil_elements"]`).

# Committed offset map shipped with the package.
const _CMRXRECON_MAP_PATH = normpath(joinpath(@__DIR__, "..", "..", "data", "cmrxrecon2024_map.csv"))
_bundled_index_path(::CMRxRecon2024) = _CMRXRECON_MAP_PATH
_is_static_index(::CMRxRecon2024) = true

# Convert an archive-canonical path to a user-facing entry id. Strips the redundant
# "MultiCoil/" prefix (all distributed data is MultiCoil), the "FullSample/" folder
# component (retained TrainingSet data is entirely FullSample), and the ".mat" extension.
function _cmrxrecon_path_to_id(path::AbstractString)
    s = replace(String(path), r"^MultiCoil/" => "")
    s = replace(s, "/FullSample/" => "/")
    return replace(s, r"\.mat$" => "")
end

function _cmrxrecon_entry(row, col)
    path = _csv_cell_str(row, col, "path")
    isempty(path) && return nothing

    span = _zip_span_from_row(row, col)
    start_frag = _csv_cell_int(row, col, "start_frag")
    end_frag = _csv_cell_int(row, col, "end_frag")
    # A usable entry must carry the full coordinate tuple needed to fetch it.
    (span === nothing || start_frag === nothing || end_frag === nothing) && return nothing

    modality = _csv_cell_str(row, col, "modality")
    subject = _csv_cell_str(row, col, "subject")
    matfile = _csv_cell_str(row, col, "matfile")
    coil_type = _csv_cell_str(row, col, "coil_type")
    dataset_set = _csv_cell_str(row, col, "dataset_set")

    label = isempty(modality) ? "CMRxRecon2024" : "CMRxRecon2024 $modality"
    isempty(subject) || (label = string(label, " ", subject))
    label = string(label, " — ", isempty(matfile) ? last(split(path, '/')) : matfile)

    stem = isempty(matfile) ? String(last(split(path, '/'))) : matfile
    series = _cardiac_series(replace(stem, r"\.mat$"i => ""))

    locator = _zip_span_locator(span)
    locator["path"] = path    # full archive path, used by the fetch engine
    locator["start_frag"] = start_frag
    locator["end_frag"] = end_frag
    locator["archive"] = _csv_cell_str(row, col, "archive")
    _put_optional!(locator, "mat_file", matfile)

    extra = Dict{String, Any}()
    tr_ms = _csv_cell_float(row, col, "tr_ms")
    te_ms = _csv_cell_float(row, col, "te_ms")
    flip_angle = _csv_cell_float(row, col, "flip_angle")
    fov_x = _csv_cell_float(row, col, "fov_x")
    fov_y = _csv_cell_float(row, col, "fov_y")
    nx = _csv_cell_int(row, col, "nx")
    ny = _csv_cell_int(row, col, "ny")
    hardware_coils = _csv_cell_int(row, col, "hardware_coils")
    _put_optional!(extra, "repetition_time_ms", tr_ms)
    _put_optional!(extra, "echo_time_ms", te_ms)
    _put_optional!(extra, "flip_angle_deg", flip_angle)
    (fov_x === nothing || fov_y === nothing) || (extra["reconstruction_fov_mm"] = (fov_x, fov_y))
    (nx === nothing || ny === nothing) || (extra["acquisition_matrix"] = (nx, ny))
    _put_optional!(extra, "multi_coil_elements", hardware_coils)

    # Stored channel count: 10 virtual channels for MultiCoil (SVD-compressed by the
    # challenge organisers), 1 for SingleCoil. hardware_coils is the physical element
    # count (30–38) and is informational only, kept above under extra.
    receiver_channels = coil_type == "multi" ? 10 : (coil_type == "single" ? 1 : nothing)
    # Use measured field strength from info CSV; fall back to nominal 3 T.
    fs_val = something(_csv_cell_float(row, col, "field_strength"), 3.0)

    return DatasetEntry(;
        source = CMRXRECON2024,
        id = _cmrxrecon_path_to_id(path),
        name = label,
        subject_id = isempty(subject) ? nothing : subject,
        split = _normalize_split(dataset_set),
        vendor = :siemens,
        field_strength = fs_val,
        receiver_channels = receiver_channels,
        coil_data = :derived,
        anatomy = series.anatomy,
        contrast = series.contrast,
        orientation = series.orientation,
        sequence = series.sequence,
        quantitative = series.quantitative,
        num_slices = _csv_cell_int(row, col, "nz"),
        num_frames = _csv_cell_int(row, col, "nt"),
        trajectory = :cartesian,
        fully_sampled = true,
        cardiac_sync = series.cardiac_sync,
        phase_contrast = series.phase_contrast,
        blood_signal_nulling = series.blood_signal_nulling,
        file_format = :matlab_v73,
        approx_size_bytes = span.uncompressed_size,
        url = "",
        extra = extra,
        locator = locator,
    )
end

# Parse the offset-map CSV at `path` into entries. Separated from _catalog_entries
# so the precompile workload can call it directly on the bundled map without an
# initialised cache directory.
_cmrxrecon_entries(path::AbstractString) = _parse_offset_map(path, _cmrxrecon_entry)

function _catalog_entries(s::CMRxRecon2024; offline::Bool = false)
    return _cached_index_entries(ensure_index(s; offline = offline), _cmrxrecon_entries)
end

extra_schema(::CMRxRecon2024) = Dict(
    "repetition_time_ms" => "Repetition Time (0018,0080), ms",
    "echo_time_ms" => "Echo Time (0018,0081), ms",
    "flip_angle_deg" => "Flip Angle (0018,1314), degrees",
    "reconstruction_fov_mm" => "(fov_x, fov_y) — Reconstruction FOV (0018,9317), mm",
    "acquisition_matrix" => "(nx, ny) — Acquisition Matrix (0018,1310)",
    "multi_coil_elements" => "physical receiver element count (30–38); the stored k-space is SVD-compressed to `receiver_channels`",
)
