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
# columns (smp/ech/dur/sli/fov/sub/viw) are decoded into `extra`.

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
const _OCMR_SLICEMODE = Dict("ind" => "individual", "stk" => "stack")
const _OCMR_FOV = Dict("ali" => "with aliasing", "noa" => "no aliasing")
const _OCMR_SUBJECT = Dict("vol" => "volunteer", "pat" => "patient")

_ocmr_cell(row, col, key) = _isempty_cell(row, get(col, key, 0)) ? nothing : strip(String(row[col[key]]))

# Decode `code` via `table`, returning the verbatim code if unmapped.
_ocmr_decode(table, code) = code === nothing ? nothing : get(table, code, code)

function _ocmr_entry(row, col)
    fname = strip(String(row[col["file name"]]))
    isempty(fname) && return nothing
    stem = replace(fname, r"\.h5$" => "")

    slices = _cell_int(row, get(col, "slices", 0))
    scn = _ocmr_cell(row, col, "scn")
    scanner = scn === nothing ? nothing : get(_OCMR_SCANNER, scn, nothing)

    # Field strength: prefer the scanner column (authoritative), fall back to the
    # filename suffix ("_1_5T" etc.).
    field = scanner === nothing ? _ocmr_field_strength(stem) : scanner.field
    vendor = scanner === nothing ? nothing : Symbol(scanner.vendor)

    # Fully-sampled: prefer the filename prefix, fall back to the `smp` column.
    smp = _ocmr_cell(row, col, "smp")
    fully = _ocmr_fully_sampled(stem)
    fully === nothing && smp !== nothing && (fully = smp == "fs" ? true : smp == "pse" ? false : nothing)

    extra = Dict{String, Any}("file_name" => fname)
    slices === nothing || (extra["slices"] = slices)
    scanner === nothing || (extra["scanner_model"] = scanner.model)
    _ocmr_put!(extra, "view", _ocmr_cell(row, col, "viw"))
    _ocmr_put!(extra, "sampling", _ocmr_decode(_OCMR_SAMPLING, smp))
    _ocmr_put!(extra, "echo", _ocmr_decode(_OCMR_ECHO, _ocmr_cell(row, col, "ech")))
    _ocmr_put!(extra, "duration", _ocmr_decode(_OCMR_DURATION, _ocmr_cell(row, col, "dur")))
    _ocmr_put!(extra, "slice_mode", _ocmr_decode(_OCMR_SLICEMODE, _ocmr_cell(row, col, "sli")))
    _ocmr_put!(extra, "fov", _ocmr_decode(_OCMR_FOV, _ocmr_cell(row, col, "fov")))
    _ocmr_put!(extra, "subject", _ocmr_decode(_OCMR_SUBJECT, _ocmr_cell(row, col, "sub")))

    return DatasetEntry(;
        source = OCMR_SOURCE,
        id = stem,
        name = "OCMR $(stem)",
        anatomy = :cardiac,
        vendor = vendor,
        field_strength = field,
        trajectory = :cartesian,
        fully_sampled = fully,
        is3D = false,
        url = ocmr_url(fname),
        extra = extra,
    )
end

# Store a decoded value under `key` only when present (keeps `extra` keys meaningful).
_ocmr_put!(extra, key, val) = val === nothing ? nothing : (extra[key] = val)

# `readdlm` yields already-typed cells (Bool/Float64/String/SubString); these
# helpers read a column defensively regardless of how a given cell was parsed.
# A column index of 0 means "column absent".
_isempty_cell(row, idx) = idx == 0 || (row[idx] isa AbstractString && isempty(strip(row[idx])))

function _cell_int(row, idx)
    _isempty_cell(row, idx) && return nothing
    v = row[idx]
    v isa Integer && return Int(v)
    v isa Real && return round(Int, v)
    return tryparse(Int, strip(String(v)))
end

function _catalog_entries(s::OCMR; offline::Bool = false)
    path = ensure_index(s; offline = offline)
    isfile(path) || return DatasetEntry[]
    data, header = readdlm(path, ','; header = true)
    col = Dict(strip(String(h)) => i for (i, h) in enumerate(vec(header)))
    haskey(col, "file name") || return DatasetEntry[]
    entries = DatasetEntry[]
    for r in axes(data, 1)
        e = _ocmr_entry(data[r, :], col)
        e === nothing || push!(entries, e)
    end
    return merge_sizes(entries, s)
end

# OCMR ids are file stems; an unknown id is assumed to be a valid bucket file.
function _synthesize_entry(::OCMR, id::String)
    fname = endswith(id, ".h5") ? id : id * ".h5"
    stem = replace(fname, r"\.h5$" => "")
    return DatasetEntry(;
        source = OCMR_SOURCE,
        id = stem,
        name = "OCMR $(stem)",
        anatomy = :cardiac,
        field_strength = _ocmr_field_strength(stem),
        trajectory = :cartesian,
        fully_sampled = _ocmr_fully_sampled(stem),
        is3D = false,
        url = ocmr_url(fname),
        extra = Dict{String, Any}("file_name" => fname),
    )
end
