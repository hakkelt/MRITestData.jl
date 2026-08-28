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
_is_static_index(::M4Raw) = true

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
    path = _csv_cell_str(row, col, "path")
    isempty(path) && return nothing

    # A usable entry must carry the full coordinate tuple needed to fetch it.
    span = _zip_span_from_row(row, col)
    archive = _csv_cell_str(row, col, "archive")
    (span === nothing || isempty(archive)) && return nothing

    contrast = _csv_cell_str(row, col, "contrast")
    set = _csv_cell_str(row, col, "set")

    id = _m4raw_path_to_id(path, set)
    label = string("M4Raw ", isempty(contrast) ? last(split(id, '/')) : contrast, " — ", last(split(id, '/')))

    extra = _zip_span_extra(span)
    extra["path"] = path    # full archive path, for reference
    extra["archive"] = archive
    _put_columns!(extra, row, col, _csv_cell_str, ("study", "contrast", "repetition", "set"))

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
        approx_size_bytes = span.uncompressed_size,
        url = "",
        extra = extra,
    )
end

# Parse the offset-map CSV at `path` into entries. Separated from _catalog_entries so the
# precompile workload can call it directly on the bundled map without an initialised cache
# directory.
_m4raw_entries(path::AbstractString) = _parse_offset_map(path, _m4raw_entry)

function _catalog_entries(s::M4Raw; offline::Bool = false)
    return _cached_index_entries(ensure_index(s; offline = offline), _m4raw_entries)
end
