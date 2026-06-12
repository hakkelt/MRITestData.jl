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

# The catalog is built from the committed per-set member maps (read directly by
# `_catalog_entries` below), so there is no upstream index to fetch or refresh. The
# index-framework hooks below exist only so `refresh_index()` — which iterates every
# source — treats CMRxRecon-300 as static rather than erroring.
index_ext(::CMRxRecon300) = "txt"
_index_source_url(::CMRxRecon300) = "bundled://cmrxrecon300 (static maps in data/)"
_bundled_index_path(::CMRxRecon300) = _cmrx300_map_path("demo")

function _fetch_index(::CMRxRecon300, dest::AbstractString; progress::Bool = false, fetch_sizes::Bool = false)
    open(dest, "w") do io
        println(io, "CMRxRecon-300 uses static committed member maps; nothing to fetch.")
        for set in _CMRX300_SETS
            p = _cmrx300_map_path(set)
            isfile(p) && println(io, "data/", basename(p))
        end
    end
    return dest
end

# Defensive cell readers: readdlm types numeric cells as Float64 and text as strings.
function _cmrx300_str(row, col, key)
    idx = get(col, key, 0)
    idx == 0 && return ""
    v = row[idx]
    return strip(v isa AbstractString ? String(v) : string(v))
end

function _cmrx300_int(row, col, key)
    idx = get(col, key, 0)
    idx == 0 && return nothing
    v = row[idx]
    v isa Integer && return Int(v)
    v isa Real && return round(Int, v)
    return tryparse(Int, strip(String(v)))
end

# cine_lax_ks.mat / t1map_calib.mat → "k-space" vs "calibration" hint for the label.
function _cmrx300_kind(matfile::AbstractString)
    base = lowercase(matfile)
    endswith(base, "_ks.mat") && return "k-space"
    endswith(base, "_calib.mat") && return "calibration"
    return ""
end

function _cmrx300_entry(row, col)
    path = _cmrx300_str(row, col, "path")
    isempty(path) && return nothing
    data_offset = _cmrx300_int(row, col, "data_offset")
    size = _cmrx300_int(row, col, "size")
    (data_offset === nothing || size === nothing) && return nothing

    set = _cmrx300_str(row, col, "set")
    subject = _cmrx300_str(row, col, "subject")
    modality = _cmrx300_str(row, col, "modality")
    matfile = _cmrx300_str(row, col, "matfile")
    isempty(matfile) && (matfile = String(last(split(path, '/'))))

    kind = _cmrx300_kind(matfile)
    label = "CMRxRecon-300"
    isempty(modality) || (label = string(label, " ", modality))
    isempty(subject) || (label = string(label, " ", subject))
    label = string(label, " — ", matfile)
    isempty(kind) || (label = string(label, " (", kind, ")"))

    extra = Dict{String, Any}(
        "path" => path,
        "set" => set,
        "data_offset" => data_offset,
        "size" => size,
    )
    isempty(subject) || (extra["subject"] = subject)
    isempty(modality) || (extra["modality"] = modality)
    isempty(matfile) || (extra["mat_file"] = matfile)
    # The `_ks` k-space is *undersampled* (regular k-t pattern, R≈3); only the `_calib`
    # ACS file is fully sampled. Record the paired calibration id for `_ks` entries.
    is_calib = endswith(lowercase(matfile), "_calib.mat")
    is_ks = endswith(lowercase(matfile), "_ks.mat")
    is_ks && (extra["calib_id"] = replace(replace(path, r"\.mat$" => ""), r"_ks$" => "_calib"))

    return DatasetEntry(;
        source = CMRXRECON300,
        id = replace(path, r"\.mat$" => ""),   # user-facing id drops the .mat extension
        name = label,
        anatomy = :cardiac,
        vendor = :siemens,
        field_strength = 3.0,
        trajectory = :cartesian,
        coils = nothing,
        fully_sampled = is_calib ? true : false,
        is3D = false,
        approx_size_bytes = size,
        url = "",
        extra = extra,
    )
end

# Parse one set's member-map CSV into entries (empty if the file is absent).
function _cmrx300_entries(path::AbstractString)
    isfile(path) || return DatasetEntry[]
    data, header = readdlm(path, ','; header = true)
    col = Dict(strip(String(h)) => i for (i, h) in enumerate(vec(header)))
    haskey(col, "path") || return DatasetEntry[]
    entries = DatasetEntry[]
    for r in axes(data, 1)
        e = _cmrx300_entry(data[r, :], col)
        e === nothing || push!(entries, e)
    end
    return entries
end

function _catalog_entries(::CMRxRecon300; offline::Bool = false)
    entries = DatasetEntry[]
    for set in _CMRX300_SETS
        append!(entries, _cmrx300_entries(_cmrx300_map_path(set)))
    end
    return entries
end

# A CMRxRecon-300 file can only be fetched if its payload offset + size are in the map.
function _synthesize_entry(::CMRxRecon300, id::String)
    return error(
        "unknown CMRxRecon-300 file $(repr(id)); ids have the form " *
            "\"<Set>/<Subject>/<file>\" (no .mat extension) and must be present in a " *
            "committed member map (data/cmrxrecon300_<set>_map.csv).",
    )
end
