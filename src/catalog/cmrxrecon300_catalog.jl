# CMRxRecon-300 catalog. Like CMRxRecon2024 there is no remote index to scrape: the
# catalog is built from static member maps generated once by the maintainer indexer
# (scripts/index_cmrxrecon300.jl) and committed to the package as
# `data/cmrxrecon300_<set>_map.csv` (set = demo | training | validation | test). Each row
# records one fully-sampled `.mat` member as its in-archive path plus the uncompressed
# payload offset + size the runtime needs to extract it via the zran index. Sets are read
# independently and concatenated, so the catalog reflects whichever maps are committed.
#
# Map CSV schema: path, set, subject, modality, matfile, data_offset, size

const _CMRX300_SETS = ("demo", "training", "validation", "test")
const _CMRX300_MAP_DIR = normpath(joinpath(@__DIR__, "..", "..", "data"))
_cmrx300_map_path(set::AbstractString) = joinpath(_CMRX300_MAP_DIR, "cmrxrecon300_$(set)_map.csv")

# Unlike the other map-backed sources, CMRxRecon-300's catalog spans *several* committed
# maps (one per set), so `_catalog_entries` reads them directly. `_bundled_index_path` names
# the demo map so `index_path` and the generic static-source machinery still resolve.
_is_static_index(::CMRxRecon300) = true
_bundled_index_path(::CMRxRecon300) = _cmrx300_map_path("demo")

# The member file recorded by one map row: `matfile` falls back to the path's basename.
_cmrx300_matfile(row, col, path) =
    something(_nonempty(_csv_cell_str(row, col, "matfile")), String(last(split(path, '/'))))

_nonempty(s::AbstractString) = isempty(s) ? nothing : String(s)

function _cmrx300_entry(row, col; base_id::String)
    path = _csv_cell_str(row, col, "path")
    isempty(path) && return nothing
    data_offset = _csv_cell_int(row, col, "data_offset")
    size = _csv_cell_int(row, col, "size")
    (data_offset === nothing || size === nothing) && return nothing

    subject = _csv_cell_str(row, col, "subject")
    modality = _csv_cell_str(row, col, "modality")
    set = _csv_cell_str(row, col, "set")
    matfile = _cmrx300_matfile(row, col, path)

    label = "CMRxRecon-300"
    isempty(modality) || (label = string(label, " ", modality))
    isempty(subject) || (label = string(label, " ", subject))

    series = _cardiac_series(replace(modality, r"\.mat$"i => ""))

    locator = Dict{String, Any}(
        "path" => path,
        "data_offset" => data_offset,
        "size" => size,
        "mat_file" => matfile,
    )
    _put_optional!(locator, "set", set)

    return DatasetEntry(;
        source = CMRXRECON300,
        id = base_id,
        name = label,
        subject_id = isempty(subject) ? nothing : subject,
        split = _normalize_split(set),
        cohort = :volunteer,
        vendor = :siemens,
        field_strength = 3.0,
        receiver_channels = 30,
        coil_data = :original,
        anatomy = series.anatomy,
        contrast = series.contrast,
        orientation = series.orientation,
        sequence = series.sequence,
        quantitative = series.quantitative,
        cardiac_sync = series.cardiac_sync,
        phase_contrast = series.phase_contrast,
        blood_signal_nulling = series.blood_signal_nulling,
        trajectory = :cartesian,
        fully_sampled = false,
        acceleration = 3.0,
        undersampling_pattern = :uniform,
        has_acs = true,
        file_format = :matlab_v73,
        approx_size_bytes = size,
        url = "",
        extra = Dict{String, Any}(),
        locator = locator,
    )
end

# Each acquisition is one or two rows — the undersampled `_ks` member and its fully-sampled
# `_calib` ACS companion — which share a base id and become a single entry carrying the
# calibration member's coordinates in `locator`. Entries are sorted by base id so the
# catalog order does not depend on Dict iteration order.
function _cmrx300_entries(path::AbstractString)
    parsed = _read_offset_map(path)
    parsed === nothing && return DatasetEntry[]
    data, col = parsed

    groups = Dict{String, Dict{String, Any}}()
    for row in eachrow(data)
        p = _csv_cell_str(row, col, "path")
        isempty(p) && continue
        base_id = replace(replace(p, r"\.mat$" => ""), r"(_ks|_calib)$" => "")
        kind = endswith(lowercase(_cmrx300_matfile(row, col, p)), "_calib.mat") ? "calib" : "ks"
        get!(groups, base_id, Dict{String, Any}())[kind] = row
    end

    entries = DatasetEntry[]
    for base_id in sort!(collect(keys(groups)))
        rows = groups[base_id]
        main_row = get(rows, "ks", get(rows, "calib", nothing))
        main_row === nothing && continue
        e = _cmrx300_entry(main_row, col; base_id = base_id)
        e === nothing && continue
        if haskey(rows, "calib") && haskey(rows, "ks")
            calib_row = rows["calib"]
            e.locator["calib_path"] = _csv_cell_str(calib_row, col, "path")
            e.locator["calib_data_offset"] = _csv_cell_int(calib_row, col, "data_offset")
            e.locator["calib_size"] = _csv_cell_int(calib_row, col, "size")
        end
        push!(entries, e)
    end
    return entries
end

function _catalog_entries(::CMRxRecon300; offline::Bool = false)
    entries = DatasetEntry[]
    for set in _CMRX300_SETS
        append!(entries, _cached_index_entries(_cmrx300_map_path(set), _cmrx300_entries))
    end
    return entries
end
