# M4Raw low-field brain catalog. Like USC_SPEECH (and unlike OCMR/mridata) there is no
# remote index to scrape: the catalog is a *static* offset map, generated once from the
# Zenodo ZIP archives (see scripts/generate_m4raw_map.jl) and committed to the package as
# `data/m4raw_map.csv`. Each row records where one fastMRI-layout `.h5` member lives inside
# one of the multi-GB Zenodo archives (`M4RawV1.5_multicoil_{train,val}.zip`,
# `M4Raw_multicoil_test.zip`, `M4RawV1.5_gre_data.zip`) — as a byte span
# (start_off..end_off), the ZIP local-header length, compressed/uncompressed sizes and
# compression method — plus the archive name and the study/contrast/repetition/set parsed
# from the member path. The runtime uses this to pull and (if needed) inflate one `.h5`
# with an HTTP range request instead of downloading the whole archive. The extracted file
# is fastMRI-layout (not a complete ISMRMRD file), so it is converted on first load
# (see src/load/m4raw_ismrmrd.jl).
#
# Map CSV schema:
#   path, start_off, end_off, lfh_size, compressed_size, uncompressed_size, compression,
#   archive, study, contrast, repetition, set

# Committed offset map shipped with the package.
const _M4RAW_MAP_PATH = normpath(joinpath(@__DIR__, "..", "..", "data", "m4raw_map.csv"))
_bundled_index_path(::M4Raw) = _M4RAW_MAP_PATH

# The map is static and bundled — there is no upstream to scrape. ensure_index still
# routes through _fetch_index, so "fetching" simply copies the bundled map into the cache
# (no network). The sentinel URL is only used for the meta sidecar / logging.
_index_source_url(::M4Raw) = "bundled://m4raw_map.csv"

function _fetch_index(::M4Raw, dest::AbstractString; progress::Bool = false, fetch_sizes::Bool = false)
    mkpath(dirname(dest))
    cp(_M4RAW_MAP_PATH, dest; force = true)
    return dest
end

# Read a (possibly Int- or Float-parsed) numeric cell as Int. A missing column index
# (0) means "absent".
function _m4raw_int(row, col, key)
    idx = get(col, key, 0)
    idx == 0 && return nothing
    v = row[idx]
    v isa Integer && return Int(v)
    v isa Real && return round(Int, v)
    return tryparse(Int, strip(String(v)))
end

# Read a string cell; returns "" for absent or empty columns.
function _m4raw_str(row, col, key)
    idx = get(col, key, 0)
    idx == 0 && return ""
    v = row[idx]
    return strip(v isa AbstractString ? String(v) : string(v))
end

# Convert an in-archive member path to a user-facing entry id. The member is
# `<set>/<study>_<contrast><rep>.h5` (the ZIP top-level folder names the set); the id
# keeps `<set>/<stem>`, dropping the `.h5` suffix
# (e.g. "multicoil_val/2022061003_FLAIR01.h5" -> "multicoil_val/2022061003_FLAIR01").
function _m4raw_path_to_id(path::AbstractString, set::AbstractString)
    stem = replace(String(basename(String(path))), r"\.h5$"i => "")
    folder = isempty(set) ? "" : string(strip(String(set)), "/")
    return string(folder, stem)
end

function _m4raw_entry(row, col)
    path = strip(String(row[col["path"]]))
    isempty(path) && return nothing

    start_off = _m4raw_int(row, col, "start_off")
    end_off = _m4raw_int(row, col, "end_off")
    lfh_size = _m4raw_int(row, col, "lfh_size")
    compressed_size = _m4raw_int(row, col, "compressed_size")
    uncompressed_size = _m4raw_int(row, col, "uncompressed_size")
    compression = _m4raw_int(row, col, "compression")
    archive = _m4raw_str(row, col, "archive")

    # A usable entry must carry the full coordinate tuple needed to fetch it.
    any(x -> x === nothing, (start_off, end_off, lfh_size, compressed_size, compression)) && return nothing
    isempty(archive) && return nothing

    study = _m4raw_str(row, col, "study")
    contrast = _m4raw_str(row, col, "contrast")
    repetition = _m4raw_str(row, col, "repetition")
    set = _m4raw_str(row, col, "set")

    id = _m4raw_path_to_id(path, set)
    label = string("M4Raw ", isempty(contrast) ? last(split(id, '/')) : contrast, " — ", last(split(id, '/')))

    extra = Dict{String, Any}(
        "path" => path,    # full archive path, for reference
        "archive" => archive,
        "start_off" => start_off,
        "end_off" => end_off,
        "lfh_size" => lfh_size,
        "compressed_size" => compressed_size,
        "compression" => compression,
    )
    isempty(study) || (extra["study"] = study)
    isempty(contrast) || (extra["contrast"] = contrast)
    isempty(repetition) || (extra["repetition"] = repetition)
    isempty(set) || (extra["set"] = set)

    return DatasetEntry(;
        source = M4RAW,
        id = id,
        name = label,
        anatomy = :brain,
        # M4Raw was acquired on a 0.3 T whole-body system; the descriptor does not name a
        # major vendor, so leave it unset rather than guess.
        vendor = nothing,
        field_strength = 0.3,
        trajectory = :cartesian,
        coils = 4,
        # Each member holds one fully-sampled multi-slice Cartesian acquisition.
        fully_sampled = true,
        is3D = false,
        approx_size_bytes = uncompressed_size,
        url = "",
        extra = extra,
    )
end

# Parse the offset-map CSV at `path` into entries. Separated from _catalog_entries so the
# precompile workload can call it directly on the bundled map without an initialised cache
# directory.
function _m4raw_entries(path::AbstractString)
    isfile(path) || return DatasetEntry[]
    data, header = readdlm(path, ','; header = true)
    col = Dict(strip(String(h)) => i for (i, h) in enumerate(vec(header)))
    haskey(col, "path") || return DatasetEntry[]
    entries = DatasetEntry[]
    for r in axes(data, 1)
        e = _m4raw_entry(data[r, :], col)
        e === nothing || push!(entries, e)
    end
    return entries
end

function _catalog_entries(s::M4Raw; offline::Bool = false)
    path = ensure_index(s; offline = offline)
    return _m4raw_entries(path)
end

# An M4Raw file can only be fetched if its byte coordinates are in the map, so an id absent
# from the catalog cannot be synthesised into a usable entry.
function _synthesize_entry(::M4Raw, id::String)
    error(
        "unknown M4Raw file $(repr(id)); ids have the form " *
            "\"<set>/<study>_<contrast><rep>\" and must be present in the bundled " *
            "offset map (data/m4raw_map.csv).",
    )
end
