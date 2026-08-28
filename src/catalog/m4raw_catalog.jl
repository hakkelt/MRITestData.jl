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
#
# Scanner: 0.3 T "Oper-0.3" (Ningbo Xingaoyi), four-channel head coil, 18 axial slices
# (Lyu et al., Scientific Data 2023 — see docs/dev/taxonomy-refactor-plan.md §12).

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

# T1/T2 are turbo spin echo; FLAIR adds an inversion-recovery prep; GRE is a spoiled
# gradient echo. GRE's weighting is not explicitly stated in the M4Raw paper's sequence
# table and is carried over from the pre-refactor label — unconfirmed (plan §13 ¹).
function _m4raw_series(contrast_str::AbstractString)
    contrast_str == "T1" && return (contrast = :t1, sequence = "turbo spin echo", echo_type = :spin)
    contrast_str == "T2" && return (contrast = :t2, sequence = "turbo spin echo", echo_type = :spin)
    contrast_str == "FLAIR" && return (
        contrast = :fluid_attenuated, sequence = "turbo spin echo (inversion-recovery prepared)",
        echo_type = :spin,
    )
    contrast_str == "GRE" && return (contrast = :t1, sequence = "spoiled gradient echo", echo_type = :gradient)
    return (contrast = :unknown, sequence = nothing, echo_type = nothing)
end

function _m4raw_entry(row, col)
    path = _csv_cell_str(row, col, "path")
    isempty(path) && return nothing

    # A usable entry must carry the full coordinate tuple needed to fetch it.
    span = _zip_span_from_row(row, col)
    archive = _csv_cell_str(row, col, "archive")
    (span === nothing || isempty(archive)) && return nothing

    contrast_str = _csv_cell_str(row, col, "contrast")
    set = _csv_cell_str(row, col, "set")
    study = _csv_cell_str(row, col, "study")
    repetition = _csv_cell_int(row, col, "repetition")
    series = _m4raw_series(contrast_str)

    id = _m4raw_path_to_id(path, set)
    label = string("M4Raw ", isempty(contrast_str) ? last(split(id, '/')) : contrast_str, " — ", last(split(id, '/')))

    locator = _zip_span_locator(span)
    locator["path"] = path    # full archive path, for reference
    locator["archive"] = archive

    return DatasetEntry(;
        source = M4RAW,
        id = id,
        name = label,
        subject_id = isempty(study) ? nothing : study,
        cohort = :volunteer,
        split = _normalize_split(set),
        repetition = repetition,
        vendor = :ningbo_xingaoyi,
        scanner_model = "Oper-0.3",
        field_strength = 0.3,
        receiver_channels = 4,
        anatomy = :brain,
        contrast = series.contrast,
        orientation = :axial,
        sequence = series.sequence,
        echo_type = series.echo_type,
        num_slices = 18,
        trajectory = :cartesian,
        # Each member holds one fully-sampled multi-slice Cartesian acquisition.
        fully_sampled = true,
        file_format = :fastmri_h5,
        approx_size_bytes = span.uncompressed_size,
        url = "",
        extra = Dict{String, Any}(),
        locator = locator,
    )
end

# Parse the offset-map CSV at `path` into entries. Separated from _catalog_entries so the
# precompile workload can call it directly on the bundled map without an initialised cache
# directory.
_m4raw_entries(path::AbstractString) = _parse_offset_map(path, _m4raw_entry)

function _catalog_entries(s::M4Raw; offline::Bool = false)
    return _cached_index_entries(ensure_index(s; offline = offline), _m4raw_entries)
end
