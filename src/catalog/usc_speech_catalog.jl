# USC SPAN 75-speaker speech rtMRI catalog. Like CMRxRecon2024 (and unlike
# OCMR/mridata) there is no remote index to scrape: the catalog is a *static* offset
# map, generated once from the figshare archive (see scripts/generate_usc_speech_map.jl)
# and committed to the package as `data/usc_speech_map.csv`. Each row records where one
# 2drt raw spiral k-space `.h5` member lives inside the single ~570 GB `dataset.zip`
# (figshare file id 26378810) — as a byte span (start_off..end_off), the ZIP local-header
# length, compressed/uncompressed sizes and compression method — plus the subject,
# stimulus and repetition parsed from the member path. The runtime uses this to pull and
# (if needed) inflate one `.h5` with HTTP range requests instead of downloading the whole
# archive. The extracted file is already MRD/ISMRMRD, so it loads through the default
# `load_raw` path with no conversion.
#
# Map CSV schema:
#   path, start_off, end_off, lfh_size, compressed_size, uncompressed_size, compression,
#   file_id, subject, modality, stimulus, repetition

# Committed offset map shipped with the package.
const _USC_MAP_PATH = normpath(joinpath(@__DIR__, "..", "..", "data", "usc_speech_map.csv"))
_bundled_index_path(::USCSpeech) = _USC_MAP_PATH

# The map is static and bundled — there is no upstream to scrape. ensure_index still
# routes through _fetch_index, so "fetching" simply copies the bundled map into the
# cache (no network). The sentinel URL is only used for the meta sidecar / logging.
_index_source_url(::USCSpeech) = "bundled://usc_speech_map.csv"

function _fetch_index(::USCSpeech, dest::AbstractString; progress::Bool = false, fetch_sizes::Bool = false)
    mkpath(dirname(dest))
    cp(_USC_MAP_PATH, dest; force = true)
    return dest
end

# Read a (possibly Int- or Float-parsed) numeric cell as Int. A missing column index
# (0) means "absent".
function _usc_int(row, col, key)
    idx = get(col, key, 0)
    idx == 0 && return nothing
    v = row[idx]
    v isa Integer && return Int(v)
    v isa Real && return round(Int, v)
    return tryparse(Int, strip(String(v)))
end

# Read a string cell; returns "" for absent or empty columns.
function _usc_str(row, col, key)
    idx = get(col, key, 0)
    idx == 0 && return ""
    v = row[idx]
    return strip(v isa AbstractString ? String(v) : string(v))
end

# Convert an in-archive member path to a user-facing entry id. The member is
# `<subject>/2drt/raw/<subject>_2drt_<stem>_raw.h5`; the id keeps `<subject>/2drt/`
# and the per-utterance `<stem>`, dropping the redundant `raw/` folder, the repeated
# subject/modality filename prefix, and the `_raw.h5` suffix
# (e.g. "sub001/2drt/raw/sub001_2drt_01_vcv1_r1_raw.h5" -> "sub001/2drt/01_vcv1_r1").
function _usc_path_to_id(path::AbstractString)
    parts = split(String(path), '/')
    subject = first(parts)
    stem = replace(String(last(parts)), r"_raw\.h5$"i => "")
    stem = replace(stem, Regex("^" * subject * "_2drt_") => "")
    return string(subject, "/2drt/", stem)
end

function _usc_speech_entry(row, col)
    path = strip(String(row[col["path"]]))
    isempty(path) && return nothing

    start_off = _usc_int(row, col, "start_off")
    end_off = _usc_int(row, col, "end_off")
    lfh_size = _usc_int(row, col, "lfh_size")
    compressed_size = _usc_int(row, col, "compressed_size")
    uncompressed_size = _usc_int(row, col, "uncompressed_size")
    compression = _usc_int(row, col, "compression")
    file_id = _usc_str(row, col, "file_id")

    # A usable entry must carry the full coordinate tuple needed to fetch it.
    any(x -> x === nothing, (start_off, end_off, lfh_size, compressed_size, compression)) && return nothing
    isempty(file_id) && return nothing

    subject = _usc_str(row, col, "subject")
    modality = _usc_str(row, col, "modality")
    stimulus = _usc_str(row, col, "stimulus")
    repetition = _usc_str(row, col, "repetition")

    id = _usc_path_to_id(path)
    label = string("USC Speech ", isempty(subject) ? first(split(id, '/')) : subject, " — ", last(split(id, '/')))

    extra = Dict{String, Any}(
        "path" => path,    # full archive path, for reference
        "file_id" => file_id,
        "start_off" => start_off,
        "end_off" => end_off,
        "lfh_size" => lfh_size,
        "compressed_size" => compressed_size,
        "compression" => compression,
    )
    isempty(subject) || (extra["subject"] = subject)
    isempty(modality) || (extra["modality"] = modality)
    isempty(stimulus) || (extra["stimulus"] = stimulus)
    isempty(repetition) || (extra["repetition"] = repetition)

    return DatasetEntry(;
        source = USC_SPEECH,
        id = id,
        name = label,
        anatomy = :vocal_tract,
        vendor = :ge,
        field_strength = 1.5,
        trajectory = :spiral,
        coils = 8,
        # A single 13-interleaf spiral frame is undersampled; the raw file holds the
        # full acquisition. Leave the per-frame sampling status unasserted.
        fully_sampled = nothing,
        is3D = false,
        approx_size_bytes = uncompressed_size,
        url = "",
        extra = extra,
    )
end

# Parse the offset-map CSV at `path` into entries. Separated from _catalog_entries so
# the precompile workload can call it directly on the bundled map without an
# initialised cache directory.
function _usc_speech_entries(path::AbstractString)
    isfile(path) || return DatasetEntry[]
    data, header = readdlm(path, ','; header = true)
    col = Dict(strip(String(h)) => i for (i, h) in enumerate(vec(header)))
    haskey(col, "path") || return DatasetEntry[]
    entries = DatasetEntry[]
    for r in axes(data, 1)
        e = _usc_speech_entry(data[r, :], col)
        e === nothing || push!(entries, e)
    end
    return entries
end

function _catalog_entries(s::USCSpeech; offline::Bool = false)
    path = ensure_index(s; offline = offline)
    return _usc_speech_entries(path)
end

# A USC Speech file can only be fetched if its byte coordinates are in the map, so an
# id absent from the catalog cannot be synthesised into a usable entry.
function _synthesize_entry(::USCSpeech, id::String)
    error(
        "unknown USC Speech file $(repr(id)); ids have the form " *
            "\"<subject>/2drt/<stimulus>_r<rep>\" and must be present in the bundled " *
            "offset map (data/usc_speech_map.csv).",
    )
end
