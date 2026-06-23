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

function _cmrx300_entry(row, col; base_id::String)
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

    label = "CMRxRecon-300"
    isempty(modality) || (label = string(label, " ", modality))
    isempty(subject) || (label = string(label, " ", subject))

    extra = Dict{String, Any}(
        "path" => path,
        "set" => set,
        "data_offset" => data_offset,
        "size" => size,
        "mat_file" => matfile
    )
    isempty(subject) || (extra["subject"] = subject)
    isempty(modality) || (extra["modality"] = modality)

    return DatasetEntry(;
        source = CMRXRECON300,
        id = base_id,
        name = label,
        anatomy = :cardiac,
        vendor = :siemens,
        field_strength = 3.0,
        trajectory = :cartesian,
        coils = nothing,
        fully_sampled = false,
        is3D = false,
        approx_size_bytes = size,
        url = "",
        extra = extra,
    )
end

function _cmrx300_entries(path::AbstractString)
    isfile(path) || return DatasetEntry[]
    data, header = readdlm(path, ','; header = true)
    col = Dict(strip(String(h)) => i for (i, h) in enumerate(vec(header)))
    haskey(col, "path") || return DatasetEntry[]
    
    groups = Dict{String, Dict{String, Any}}()
    for r in axes(data, 1)
        p = _cmrx300_str(data[r, :], col, "path")
        isempty(p) && continue
        matfile = _cmrx300_str(data[r, :], col, "matfile")
        isempty(matfile) && (matfile = String(last(split(p, '/'))))
        
        base_id = replace(replace(p, r"\.mat$" => ""), r"(_ks|_calib)$" => "")
        
        g = get!(groups, base_id, Dict{String, Any}())
        kind = endswith(lowercase(matfile), "_calib.mat") ? "calib" : "ks"
        g[kind] = data[r, :]
    end
    
    entries = DatasetEntry[]
    for (base_id, rows) in groups
        main_row = get(rows, "ks", get(rows, "calib", nothing))
        main_row === nothing && continue
        
        e = _cmrx300_entry(main_row, col; base_id=base_id)
        if e !== nothing
            if haskey(rows, "calib") && haskey(rows, "ks")
                calib_row = rows["calib"]
                e.extra["calib_path"] = _cmrx300_str(calib_row, col, "path")
                e.extra["calib_data_offset"] = _cmrx300_int(calib_row, col, "data_offset")
                e.extra["calib_size"] = _cmrx300_int(calib_row, col, "size")
            end
            push!(entries, e)
        end
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
