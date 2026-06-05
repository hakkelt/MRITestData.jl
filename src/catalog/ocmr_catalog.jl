# OCMR catalog. Entries come from OCMR's authoritative attributes CSV, fetched and
# cached by the index layer (see index_cache.jl) with the committed CSV as the
# offline fallback.
#
# OCMR serves ISMRMRD .h5 cardiac data from an S3 bucket. The real CSV schema is
#   file name,scn,smp,ech,dur,viw,sli,fov,sub,,slices
# There is no field-strength or fully/under column: both are encoded in the file
# name, e.g. "fs_0001_1_5T.h5" (fully sampled, 1.5 T), "us_0014_3T.h5"
# (undersampled, 3 T), "fs_0001_0_55T.h5" (0.55 T).

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

# "fs_..." is fully sampled, "us_..." is undersampled.
function _ocmr_fully_sampled(stem::AbstractString)
    startswith(stem, "fs_") && return true
    startswith(stem, "us_") && return false
    return nothing
end

function _ocmr_entry(row, col)
    fname = strip(String(row[col["file name"]]))
    isempty(fname) && return nothing
    stem = replace(fname, r"\.h5$" => "")

    slices = _cell_int(row, get(col, "slices", 0))
    view = _isempty_cell(row, get(col, "viw", 0)) ? nothing : strip(String(row[col["viw"]]))

    extra = Dict{String,Any}("file_name" => fname)
    slices === nothing || (extra["slices"] = slices)
    view === nothing || (extra["view"] = view)

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
        extra = extra,
    )
end

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
    return entries
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
        extra = Dict{String,Any}("file_name" => fname),
    )
end
