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

# The map is static and bundled — there is no upstream to scrape. ensure_index still
# routes through _fetch_index, so "fetching" simply copies the bundled map into the
# cache (no network). The sentinel URL is only used for the meta sidecar / logging.
_index_source_url(::CMRxRecon2024) = "bundled://cmrxrecon2024_map.csv"

function _fetch_index(::CMRxRecon2024, dest::AbstractString; progress::Bool = false, fetch_sizes::Bool = false)
    mkpath(dirname(dest))
    cp(_CMRXRECON_MAP_PATH, dest; force = true)
    return dest
end

# Read a (possibly Int- or Float-parsed) numeric cell as Int. Mirrors OCMR's
# defensive cell reading; a missing column index (0) means "absent".
function _cmrxrecon_int(row, col, key)
    idx = get(col, key, 0)
    idx == 0 && return nothing
    v = row[idx]
    v isa Integer && return Int(v)
    v isa Real && return round(Int, v)
    return tryparse(Int, strip(String(v)))
end

# Read a (possibly String-parsed) Float64 cell. Returns nothing for absent or unparseable.
function _cmrxrecon_float(row, col, key)
    idx = get(col, key, 0)
    idx == 0 && return nothing
    v = row[idx]
    v isa AbstractFloat && return Float64(v)
    v isa Real && return Float64(v)
    s = strip(v isa AbstractString ? String(v) : string(v))
    isempty(s) && return nothing
    return tryparse(Float64, s)
end

# Read a string cell; returns "" for absent or empty columns.
function _cmrxrecon_str(row, col, key)
    idx = get(col, key, 0)
    idx == 0 && return ""
    v = row[idx]
    return strip(v isa AbstractString ? String(v) : string(v))
end

# Convert an archive-canonical path to a user-facing entry id. Strips the redundant
# "MultiCoil/" prefix (all distributed data is MultiCoil), the "FullSample/" folder
# component (retained TrainingSet data is entirely FullSample), and the ".mat" extension.
function _cmrxrecon_path_to_id(path::AbstractString)
    s = replace(String(path), r"^MultiCoil/" => "")
    s = replace(s, "/FullSample/" => "/")
    return replace(s, r"\.mat$" => "")
end

function _cmrxrecon_entry(row, col)
    path = strip(String(row[col["path"]]))
    isempty(path) && return nothing

    start_frag = _cmrxrecon_int(row, col, "start_frag")
    start_off = _cmrxrecon_int(row, col, "start_off")
    end_frag = _cmrxrecon_int(row, col, "end_frag")
    end_off = _cmrxrecon_int(row, col, "end_off")
    lfh_size = _cmrxrecon_int(row, col, "lfh_size")
    compressed_size = _cmrxrecon_int(row, col, "compressed_size")
    uncompressed_size = _cmrxrecon_int(row, col, "uncompressed_size")
    compression = _cmrxrecon_int(row, col, "compression")

    # A usable entry must carry the full coordinate tuple needed to fetch it.
    any(x -> x === nothing, (start_frag, start_off, end_frag, end_off, lfh_size, compressed_size, compression)) && return nothing

    archive = _cmrxrecon_str(row, col, "archive")
    # Metadata columns pre-computed by scripts/annotate_cmrxrecon2024_map.jl.
    sampling = _cmrxrecon_str(row, col, "sampling")
    coil_type = _cmrxrecon_str(row, col, "coil_type")
    modality = _cmrxrecon_str(row, col, "modality")
    dataset_set = _cmrxrecon_str(row, col, "dataset_set")
    subject = _cmrxrecon_str(row, col, "subject")
    matfile = _cmrxrecon_str(row, col, "matfile")
    # Acquisition parameters from info CSVs (present for TrainingSet; "" for others).
    hardware_coils = _cmrxrecon_int(row, col, "hardware_coils")
    field_strength = _cmrxrecon_float(row, col, "field_strength")
    fov_x = _cmrxrecon_float(row, col, "fov_x")
    fov_y = _cmrxrecon_float(row, col, "fov_y")
    nx = _cmrxrecon_int(row, col, "nx")
    ny = _cmrxrecon_int(row, col, "ny")
    nz = _cmrxrecon_int(row, col, "nz")
    nt = _cmrxrecon_int(row, col, "nt")
    tr_ms = _cmrxrecon_float(row, col, "tr_ms")
    te_ms = _cmrxrecon_float(row, col, "te_ms")
    flip_angle = _cmrxrecon_float(row, col, "flip_angle")

    label = isempty(modality) ? "CMRxRecon2024" : "CMRxRecon2024 $modality"
    isempty(subject) || (label = string(label, " ", subject))
    label = string(label, " — ", isempty(matfile) ? last(split(path, '/')) : matfile)

    extra = Dict{String, Any}(
        "path" => path,    # full archive path, used by the fetch engine
        "start_frag" => start_frag,
        "start_off" => start_off,
        "end_frag" => end_frag,
        "end_off" => end_off,
        "lfh_size" => lfh_size,
        "compressed_size" => compressed_size,
        "compression" => compression,
        "archive" => archive,
        "sampling" => sampling,
    )
    isempty(coil_type) || (extra["coil_type"] = coil_type)
    isempty(modality) || (extra["modality"] = modality)
    isempty(dataset_set) || (extra["dataset_set"] = dataset_set)
    isempty(subject) || (extra["subject"] = subject)
    isempty(matfile) || (extra["mat_file"] = matfile)
    hardware_coils === nothing || (extra["hardware_coils"] = hardware_coils)
    fov_x === nothing || (extra["fov_x"] = fov_x)
    fov_y === nothing || (extra["fov_y"] = fov_y)
    nx === nothing || (extra["nx"] = nx)
    ny === nothing || (extra["ny"] = ny)
    nz === nothing || (extra["nz"] = nz)
    nt === nothing || (extra["nt"] = nt)
    tr_ms === nothing || (extra["tr_ms"] = tr_ms)
    te_ms === nothing || (extra["te_ms"] = te_ms)
    flip_angle === nothing || (extra["flip_angle"] = flip_angle)

    # Stored channel count: 10 virtual channels for MultiCoil (SVD-compressed by the
    # challenge organisers), 1 for SingleCoil. hardware_coils is the physical element
    # count (30–38) and is informational only.
    coils_val = coil_type == "multi" ? 10 : (coil_type == "single" ? 1 : nothing)
    # Use measured field strength from info CSV; fall back to nominal 3 T.
    fs_val = field_strength !== nothing ? field_strength : 3.0

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
        approx_size_bytes = uncompressed_size,
        url = "",
        extra = extra,
    )
end

# Parse the offset-map CSV at `path` into entries. Separated from _catalog_entries
# so the precompile workload can call it directly on the bundled map without an
# initialised cache directory.
function _cmrxrecon_entries(path::AbstractString)
    isfile(path) || return DatasetEntry[]
    data, header = readdlm(path, ','; header = true)
    col = Dict(strip(String(h)) => i for (i, h) in enumerate(vec(header)))
    haskey(col, "path") || return DatasetEntry[]
    entries = DatasetEntry[]
    for r in axes(data, 1)
        e = _cmrxrecon_entry(data[r, :], col)
        e === nothing || push!(entries, e)
    end
    return entries
end

function _catalog_entries(s::CMRxRecon2024; offline::Bool = false)
    path = ensure_index(s; offline = offline)
    return _cmrxrecon_entries(path)
end

# A CMRxRecon2024 file can only be fetched if its byte coordinates are in the map.
# An id absent from the catalog therefore cannot be synthesised into a usable entry.
function _synthesize_entry(::CMRxRecon2024, id::String)
    error(
        "unknown CMRxRecon2024 file $(repr(id)); ids have the form " *
            "\"<Modality>/{TrainingSet,ValidationSet,TestSet}/<Subject>/<file>\" (no .mat " *
            "extension) and must be present in the bundled offset map (data/cmrxrecon2024_map.csv).",
    )
end
