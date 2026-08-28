# OCMR catalog. Entries come from OCMR's authoritative attributes CSV, fetched and
# cached by the index layer (see index_cache.jl) with the committed CSV as the
# offline fallback.
#
# OCMR serves ISMRMRD .h5 cardiac data from an S3 bucket. The real CSV schema is
#   file name,scn,smp,ech,dur,viw,sli,fov,sub,,slices
# The columns are short codes (see the decode tables below). Field strength and
# fully/under-sampled are *also* encoded in the file name, e.g. "fs_0001_1_5T.h5"
# (fully sampled, 1.5 T), "us_0014_3T.h5" (undersampled, 3 T) — used as a fallback
# when the corresponding column is absent. Field strength + scanner model + vendor
# are derived from the `scn` (scanner) column when present; the remaining coded
# columns (smp/ech/dur/sli/fov/sub/viw) are decoded onto DICOM-anchored core fields
# where one exists, and into `extra` (DICOM-keyword-named) otherwise.

"""Base URL pattern for OCMR downloads (ISMRMRD `.h5` by file name)."""
ocmr_url(name::AbstractString) = "https://ocmr.s3.amazonaws.com/data/$(name)"

# Committed fallback shipped with the package.
const _BUNDLED_OCMR_CSV = normpath(joinpath(@__DIR__, "..", "..", "data", "ocmr_attributes.csv"))
_bundled_index_path(::OCMR) = _BUNDLED_OCMR_CSV

# Field strength from the file name suffix: "1_5T" -> 1.5, "3T" -> 3.0, "0_55T" ->
# 0.55. The integer part is a single digit (0-9 T scanners), so we anchor on a
# single leading digit to avoid swallowing the preceding sequence number, e.g.
# "fs_9999_3T" -> 3.0 (not 9999.3).
function _ocmr_field_strength(stem::AbstractString)
    m = match(r"_(\d(?:_\d+)?)t$"i, stem)
    m === nothing && return nothing
    return tryparse(Float64, replace(m.captures[1], "_" => "."))
end

# "fs_..." is fully sampled, "us_..." is undersampled. The CSV `smp` column agrees
# ("fs"=fully sampled, "pse"=pseudo-random undersampled) and is used as a fallback.
function _ocmr_fully_sampled(stem::AbstractString)
    startswith(stem, "fs_") && return true
    startswith(stem, "us_") && return false
    return nothing
end

# Decode tables for OCMR's coded CSV columns (per the OCMR data dictionary at
# ocmr.info). Unknown codes pass through unchanged so nothing is silently dropped.
#
# scn (scanner) also encodes field strength + vendor; we derive both from it and
# only fall back to the filename suffix when the column is missing.
const _OCMR_SCANNER = Dict(
    "0_55freemax" => (model = "Siemens MAGNETOM Free.Max", vendor = "siemens", field = 0.55),
    "15avan" => (model = "Siemens MAGNETOM Avanto", vendor = "siemens", field = 1.5),
    "15sola" => (model = "Siemens MAGNETOM Sola", vendor = "siemens", field = 1.5),
    "30pris" => (model = "Siemens MAGNETOM Prisma", vendor = "siemens", field = 3.0),
    "30vida" => (model = "Siemens MAGNETOM Vida", vendor = "siemens", field = 3.0),
)
const _OCMR_SAMPLING = Dict("fs" => "fully sampled", "pse" => "pseudo-random undersampled")
const _OCMR_ECHO = Dict("asy" => "asymmetric", "sym" => "symmetric")
const _OCMR_DURATION = Dict("lng" => "long", "shr" => "short")
const _OCMR_SLICEMODE = Dict("ind" => "individual", "mul" => "multiple", "stk" => "stack")
const _OCMR_FOV = Dict("ali" => "with aliasing", "noa" => "no aliasing")
const _OCMR_SUBJECT = Dict("vol" => :volunteer, "pat" => :patient)
# `viw` (view) onto `orientation` — DICOM View Code Sequence (0054,0220); no cardiac-MR
# Context Group exists (plan §4.6), so these are local symbols from `ORIENTATIONS`.
const _OCMR_VIEW = Dict("lax" => :long_axis, "sax" => :short_axis)

# A coded column, or `nothing` when the column is absent or the cell is blank.
function _ocmr_cell(row, col, key)
    s = _csv_cell_str(row, col, key)
    return isempty(s) ? nothing : s
end

# Decode `code` via `table`, returning the verbatim code if unmapped.
_ocmr_decode(table, code) = code === nothing ? nothing : get(table, code, code)

function _ocmr_entry(row, col)
    fname = _csv_cell_str(row, col, "file name")
    isempty(fname) && return nothing
    stem = replace(fname, r"\.h5$" => "")

    slices = _csv_cell_int(row, col, "slices")
    scn = _ocmr_cell(row, col, "scn")
    scanner = scn === nothing ? nothing : get(_OCMR_SCANNER, scn, nothing)

    # Field strength: prefer the scanner column (authoritative), fall back to the
    # filename suffix ("_1_5T" etc.).
    field = scanner === nothing ? _ocmr_field_strength(stem) : scanner.field
    vendor = scanner === nothing ? :siemens : Symbol(scanner.vendor)

    # Fully-sampled: prefer the filename prefix, fall back to the `smp` column.
    smp = _ocmr_cell(row, col, "smp")
    fully = _ocmr_fully_sampled(stem)
    fully === nothing && smp !== nothing && (fully = smp == "fs" ? true : smp == "pse" ? false : nothing)

    ech = _ocmr_cell(row, col, "ech")
    partial_fourier = ech === nothing ? nothing : ech == "asy" ? true : ech == "sym" ? false : nothing
    viw = _ocmr_cell(row, col, "viw")
    orientation = viw === nothing ? nothing : get(_OCMR_VIEW, viw, nothing)
    sub = _ocmr_cell(row, col, "sub")
    cohort = sub === nothing ? nothing : get(_OCMR_SUBJECT, sub, nothing)

    extra = Dict{String, Any}("file_name" => fname)
    _put_optional!(extra, "scanner_model", scanner === nothing ? nothing : scanner.model)
    _put_optional!(extra, "sampling", _ocmr_decode(_OCMR_SAMPLING, smp))
    _put_optional!(extra, "partial_fourier_direction", _ocmr_decode(_OCMR_ECHO, ech))
    for (key, column, table) in (
            ("acquisition_duration_class", "dur", _OCMR_DURATION),
            ("slice_mode", "sli", _OCMR_SLICEMODE),
            ("phase_wrap", "fov", _OCMR_FOV),
        )
        _put_optional!(extra, key, _ocmr_decode(table, _ocmr_cell(row, col, column)))
    end

    return DatasetEntry(;
        source = OCMR_SOURCE,
        id = stem,
        name = "OCMR $(stem)",
        cohort = cohort,
        vendor = vendor,
        scanner_model = scanner === nothing ? nothing : scanner.model,
        field_strength = field,
        anatomy = :heart,
        orientation = orientation,
        partial_fourier = partial_fourier,
        num_slices = slices,
        trajectory = :cartesian,
        fully_sampled = fully,
        url = ocmr_url(fname),
        extra = extra,
    )
end

_ocmr_entries(path::AbstractString) =
    _parse_offset_map(path, _ocmr_entry; key_column = "file name")

function _catalog_entries(s::OCMR; offline::Bool = false)
    entries = _cached_index_entries(ensure_index(s; offline = offline), _ocmr_entries)
    return merge_sizes(entries, s)
end

extra_schema(::OCMR) = Dict(
    "file_name" => "the .h5 file name in the OCMR S3 bucket",
    "scanner_model" => "scanner model name, decoded from the `scn` column",
    "sampling" => "sampling scheme in prose, decoded from the `smp` column",
    "partial_fourier_direction" => "asymmetric/symmetric echo, decoded from the `ech` column",
    "acquisition_duration_class" => "long/short, decoded from the `dur` column",
    "slice_mode" => "individual/multiple/stack, decoded from the `sli` column",
    "phase_wrap" => "with/no aliasing, decoded from the `fov` column",
)

# OCMR ids are file stems; an unknown id is assumed to be a valid bucket file.
_can_synthesize(::OCMR) = true

function _synthesize_entry(::OCMR, id::String)
    fname = endswith(id, ".h5") ? id : id * ".h5"
    stem = replace(fname, r"\.h5$" => "")
    return DatasetEntry(;
        source = OCMR_SOURCE,
        id = stem,
        name = "OCMR $(stem)",
        anatomy = :heart,
        field_strength = _ocmr_field_strength(stem),
        trajectory = :cartesian,
        fully_sampled = _ocmr_fully_sampled(stem),
        url = ocmr_url(fname),
        extra = Dict{String, Any}("file_name" => fname),
    )
end
