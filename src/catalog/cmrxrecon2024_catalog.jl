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
# MultiCoil acquisitions. DatasetEntry.coils reflects the stored channel count (10/1),
# not the hardware count.

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

# Acquisition parameters annotated from the challenge info CSVs (present for TrainingSet,
# blank elsewhere). Copied verbatim into `extra` under the column's own name.
const _CMRXRECON_INT_COLUMNS = ("hardware_coils", "nx", "ny", "nz", "nt")
const _CMRXRECON_FLOAT_COLUMNS = ("fov_x", "fov_y", "tr_ms", "te_ms", "flip_angle")
# Descriptive columns pre-computed by scripts/annotate_cmrxrecon2024_map.jl. `mat_file` is
# stored under a different key than its `matfile` column, so it is handled separately.
const _CMRXRECON_STR_COLUMNS = ("coil_type", "modality", "dataset_set", "subject")

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

    label = isempty(modality) ? "CMRxRecon2024" : "CMRxRecon2024 $modality"
    isempty(subject) || (label = string(label, " ", subject))
    label = string(label, " — ", isempty(matfile) ? last(split(path, '/')) : matfile)

    extra = _zip_span_extra(span)
    extra["path"] = path    # full archive path, used by the fetch engine
    extra["start_frag"] = start_frag
    extra["end_frag"] = end_frag
    extra["archive"] = _csv_cell_str(row, col, "archive")
    extra["sampling"] = _csv_cell_str(row, col, "sampling")
    _put_optional!(extra, "mat_file", matfile)
    _put_columns!(extra, row, col, _csv_cell_str, _CMRXRECON_STR_COLUMNS)
    _put_columns!(extra, row, col, _csv_cell_int, _CMRXRECON_INT_COLUMNS)
    _put_columns!(extra, row, col, _csv_cell_float, _CMRXRECON_FLOAT_COLUMNS)

    # Stored channel count: 10 virtual channels for MultiCoil (SVD-compressed by the
    # challenge organisers), 1 for SingleCoil. hardware_coils is the physical element
    # count (30–38) and is informational only.
    coils_val = coil_type == "multi" ? 10 : (coil_type == "single" ? 1 : nothing)
    # Use measured field strength from info CSV; fall back to nominal 3 T.
    fs_val = something(_csv_cell_float(row, col, "field_strength"), 3.0)

    return DatasetEntry(;
        source = CMRXRECON2024,
        id = _cmrxrecon_path_to_id(path),
        name = label,
        anatomy = :cardiac,
        vendor = :siemens,
        field_strength = fs_val,
        trajectory = :cartesian,
        coils = coils_val,
        fully_sampled = true,
        is3D = false,
        approx_size_bytes = span.uncompressed_size,
        url = "",
        extra = extra,
    )
end

# Parse the offset-map CSV at `path` into entries. Separated from _catalog_entries
# so the precompile workload can call it directly on the bundled map without an
# initialised cache directory.
_cmrxrecon_entries(path::AbstractString) = _parse_offset_map(path, _cmrxrecon_entry)

function _catalog_entries(s::CMRxRecon2024; offline::Bool = false)
    return _cached_index_entries(ensure_index(s; offline = offline), _cmrxrecon_entries)
end
