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
_is_static_index(::USCSpeech) = true

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
    path = _csv_cell_str(row, col, "path")
    isempty(path) && return nothing

    # A usable entry must carry the full coordinate tuple needed to fetch it.
    span = _zip_span_from_row(row, col)
    file_id = _csv_cell_str(row, col, "file_id")
    (span === nothing || isempty(file_id)) && return nothing

    subject = _csv_cell_str(row, col, "subject")

    id = _usc_path_to_id(path)
    label = string("USC Speech ", isempty(subject) ? first(split(id, '/')) : subject, " — ", last(split(id, '/')))

    extra = _zip_span_extra(span)
    extra["path"] = path    # full archive path, for reference
    extra["file_id"] = file_id
    _put_columns!(extra, row, col, _csv_cell_str, ("subject", "modality", "stimulus", "repetition"))

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
        approx_size_bytes = span.uncompressed_size,
        url = "",
        extra = extra,
    )
end

# Parse the offset-map CSV at `path` into entries. Separated from _catalog_entries so
# the precompile workload can call it directly on the bundled map without an
# initialised cache directory.
_usc_speech_entries(path::AbstractString) = _parse_offset_map(path, _usc_speech_entry)

function _catalog_entries(s::USCSpeech; offline::Bool = false)
    return _cached_index_entries(ensure_index(s; offline = offline), _usc_speech_entries)
end
