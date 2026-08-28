"""
    DatasetEntry

Metadata describing a single downloadable MRI dataset. Returned by
[`list_datasets`](@ref) and used to drive downloading and loading.

# Fields
- `source::AbstractSource`: which repository hosts the file.
- `id::String`: source-specific identifier (mridata UUID, OCMR file stem).
- `name::String`: human-readable label.
- `anatomy::Symbol`: e.g. `:knee`, `:brain`, `:cardiac`, `:phantom`, `:unknown`.
- `vendor::Union{Symbol,Nothing}`: e.g. `:siemens`, `:ge`, `:philips`.
- `field_strength::Union{Float64,Nothing}`: in tesla, e.g. `1.5`, `3.0`.
- `trajectory::Symbol`: `:cartesian`, `:radial`, `:spiral`, `:custom`, `:unknown`.
- `coils::Union{Int,Nothing}`: number of receive channels, if known.
- `fully_sampled::Union{Bool,Nothing}`: whether k-space is fully sampled.
- `is3D::Union{Bool,Nothing}`: 3D acquisition flag, if known.
- `approx_size_bytes::Union{Int,Nothing}`: rough download size.
- `sha256::Union{String,Nothing}`: pinned checksum, if known.
- `url::String`: resolved download URL.
- `extra::Dict{String,Any}`: source-specific extra metadata.
"""
Base.@kwdef struct DatasetEntry
    source::AbstractSource
    id::String
    name::String
    anatomy::Symbol = :unknown
    vendor::Union{Symbol, Nothing} = nothing
    field_strength::Union{Float64, Nothing} = nothing
    trajectory::Symbol = :unknown
    coils::Union{Int, Nothing} = nothing
    fully_sampled::Union{Bool, Nothing} = nothing
    is3D::Union{Bool, Nothing} = nothing
    approx_size_bytes::Union{Int, Nothing} = nothing
    sha256::Union{String, Nothing} = nothing
    url::String
    extra::Dict{String, Any} = Dict{String, Any}()
end

function Base.show(io::IO, e::DatasetEntry)
    print(io, "DatasetEntry(", source_name(e.source), ":", e.id, ", ", repr(e.name))
    e.anatomy === :unknown || print(io, ", ", e.anatomy)
    e.trajectory === :unknown || print(io, ", ", e.trajectory)
    e.field_strength === nothing || print(io, ", ", e.field_strength, "T")
    return print(io, ")")
end

"""
    DatasetHandle(entry::DatasetEntry)

A [`DatasetEntry`](@ref) bound for download/loading. Currently a thin wrapper that
lets the API accept either an entry or a handle; created by [`dataset`](@ref).
"""
struct DatasetHandle
    entry::DatasetEntry
end

"""
    _filter_hit(value, filter) -> Bool

Test one field `value` against one `filter`, the shared predicate behind
`_matches` (named [`DatasetEntry`](@ref) fields) and `_matches_extra`
(source-specific `extra` keys). A `filter` of `missing` means "no filter" and always
matches; otherwise it is a predicate, a collection to test membership in, or a value to
compare with `==`.
"""
function _filter_hit(value, filter)::Bool
    filter === missing && return true
    filter isa Function && return filter(value)::Bool
    (filter isa AbstractVector || filter isa Tuple || filter isa AbstractSet) &&
        return value in filter
    return value == filter
end

"""
    _matches(e::DatasetEntry, filters::AbstractDict{Symbol}) -> Bool
    _matches(e::DatasetEntry; filters...) -> Bool

Test whether `e` satisfies every `filter`. Each filter key is a field name of
[`DatasetEntry`](@ref); the value may be:

- a scalar — matched by `==`,
- a vector/tuple/set — matched by membership (`in`),
- a predicate function — matched by calling it on the field value,
- `missing` — no filter; matches everything.

Note that `nothing` is a *value*, not a wildcard: `fully_sampled = nothing` selects the
entries whose sampling status is unknown. Use `missing` (or omit the key) to not filter on
a field at all.

The `AbstractDict` form exists because [`query`](@ref) builds its filters at run time;
splatting that dictionary back into keyword arguments would rebuild the keyword tuple for
every candidate entry.
"""
function _matches(e::DatasetEntry, filters::AbstractDict{Symbol})
    for (k, v) in filters
        _filter_hit(getfield(e, k), v) || return false
    end
    return true
end

function _matches(e::DatasetEntry; kwargs...)
    for (k, v) in kwargs
        _filter_hit(getfield(e, k), v) || return false
    end
    return true
end

"""
    list_datasets(source::AbstractSource; filters...) -> Vector{DatasetEntry}

Return the catalog entries for `source`, optionally narrowed by keyword `filters`
(see `_matches`). The catalog is read from a committed metadata file, so
this works offline.

A filter value of `missing` (or an omitted key) does not filter; `nothing` matches entries
whose field is unset, so `fully_sampled = nothing` finds the ones with unknown sampling.

# Examples
```julia
list_datasets(MRIDATA; anatomy = :knee, fully_sampled = true)
list_datasets(OCMR_SOURCE; field_strength = (1.5, 3.0))
list_datasets(MRIDATA; coils = c -> c !== nothing && c >= 8)
list_datasets(FASTMRI; coils = nothing)          # coil count not recorded
```
"""
function list_datasets(source::AbstractSource; offline::Bool = false, kwargs...)
    all_entries = _catalog_entries(source; offline = offline)
    # `_catalog_entries` may hand back a memoised vector shared with other callers, so an
    # unfiltered listing still needs its own copy — but not a per-entry predicate call.
    isempty(kwargs) && return copy(all_entries)
    return filter(e -> _matches(e; kwargs...), all_entries)
end

"""
    dataset(source::AbstractSource, id::AbstractString) -> DatasetHandle

Look up a dataset by `id`. If `id` is in the curated catalog the full metadata is
used; otherwise (where the source supports it, e.g. an arbitrary mridata UUID) a
minimal entry is synthesised from `id`.
"""
function dataset(source::AbstractSource, id::AbstractString; offline::Bool = false)
    for e in _catalog_entries(source; offline = offline)
        e.id == id && return DatasetHandle(e)
    end
    _can_synthesize(source) || error(
        "unknown $(source_name(source)) id $(repr(id)); it is not in the catalog, and this " *
            "source can only serve files recorded in its committed map — the id must appear " *
            "in $(basename(_bundled_index_path(source))).",
    )
    return DatasetHandle(_synthesize_entry(source, String(id)))
end

# Per-source hooks implemented in mridata_catalog.jl / ocmr_catalog.jl.
function _catalog_entries end
function _synthesize_entry end

"""
    _can_synthesize(source) -> Bool

Whether `source` can build a usable entry for an id that is not in its catalog. True for
mridata.org (any UUID resolves to a download URL) and OCMR (any bucket file name); false
for the map-backed sources, whose files can only be fetched from byte coordinates recorded
in a committed offset map. [`dataset`](@ref) raises a uniform error for the latter rather
than each source spelling out its own.
"""
_can_synthesize(::AbstractSource) = false

# Return a copy of `e` with `approx_size_bytes` replaced. `DatasetEntry` is immutable, so
# size discovery (`fetch_sizes`, `merge_sizes`) has to rebuild the entry; doing it in one
# place keeps the field list from being transcribed at each call site.
function _with_size(e::DatasetEntry, sz::Union{Int, Nothing})
    return DatasetEntry(;
        source = e.source,
        id = e.id,
        name = e.name,
        anatomy = e.anatomy,
        vendor = e.vendor,
        field_strength = e.field_strength,
        trajectory = e.trajectory,
        coils = e.coils,
        fully_sampled = e.fully_sampled,
        is3D = e.is3D,
        approx_size_bytes = sz,
        sha256 = e.sha256,
        url = e.url,
        extra = e.extra,
    )
end

# ── Shared offset-map CSV cell readers ────────────────────────────────────────────
# The map-backed sources read `readdlm`-parsed rows whose cells arrive as Int, Float64 or
# SubString depending on the column. A missing column index (0, from `get(col, key, 0)`)
# means the column is absent.

# Read a numeric cell as Int; `nothing` when the column is absent or unparseable.
function _csv_cell_int(row, col, key)
    idx = get(col, key, 0)
    idx == 0 && return nothing
    v = row[idx]
    v isa Integer && return Int(v)
    v isa Real && return round(Int, v)
    return tryparse(Int, strip(String(v)))
end

# Read a numeric cell as Float64; `nothing` when the column is absent or unparseable.
function _csv_cell_float(row, col, key)
    idx = get(col, key, 0)
    idx == 0 && return nothing
    v = row[idx]
    v isa Real && return Float64(v)
    s = strip(v isa AbstractString ? String(v) : string(v))
    isempty(s) && return nothing
    return tryparse(Float64, s)
end

# Read a string cell; `""` when the column is absent or empty.
function _csv_cell_str(row, col, key)
    idx = get(col, key, 0)
    idx == 0 && return ""
    v = row[idx]
    return strip(v isa AbstractString ? String(v) : string(v))
end

# Store `value` in `extra` under `key` only when it carries information, so `extra` never
# holds empty strings or `nothing` placeholders that callers would have to filter out.
_put_optional!(extra::AbstractDict, key::AbstractString, value) =
    (value === nothing || value == "") ? extra : (extra[key] = value; extra)

# Copy the columns named in `keys` from `row` into `extra`, reading each with `reader` and
# skipping the ones the row leaves blank.
function _put_columns!(extra::AbstractDict, row, col, reader, keys)
    for k in keys
        _put_optional!(extra, k, reader(row, col, k))
    end
    return extra
end

# Parse an offset-map CSV into `(data, col)` where `col` maps header name → column index.
# Returns `nothing` if the file is missing or lacks the mandatory `key_column`.
function _read_offset_map(path::AbstractString; key_column::AbstractString = "path")
    isfile(path) || return nothing
    data, header = readdlm(path, ','; header = true)
    col = Dict(strip(String(h)) => i for (i, h) in enumerate(vec(header)))
    haskey(col, key_column) || return nothing
    return data, col
end

# ── ZIP member coordinates ────────────────────────────────────────────────────────

"""
    ZipSpan

Where one member lives inside a ZIP archive, as recorded by the map-generator scripts.
`start_off`/`end_off` bound the member's local file header plus its (possibly compressed)
payload; `lfh_size` is how many of those bytes the header occupies, and `compression` is
the ZIP method (0 = stored, 8 = Deflate). Shared by M4Raw, USC Speech and CMRxRecon2024,
whose maps all carry the same six columns.
"""
struct ZipSpan
    start_off::Int
    end_off::Int
    lfh_size::Int
    compressed_size::Int
    uncompressed_size::Union{Int, Nothing}
    compression::Int
end

# Read a `ZipSpan` from an offset-map row, or `nothing` when the row lacks any of the
# coordinates needed to fetch the member. `uncompressed_size` is optional (it only feeds
# `approx_size_bytes`), so its absence does not reject the row.
function _zip_span_from_row(row, col)
    start_off = _csv_cell_int(row, col, "start_off")
    end_off = _csv_cell_int(row, col, "end_off")
    lfh_size = _csv_cell_int(row, col, "lfh_size")
    compressed_size = _csv_cell_int(row, col, "compressed_size")
    compression = _csv_cell_int(row, col, "compression")
    any(x -> x === nothing, (start_off, end_off, lfh_size, compressed_size, compression)) &&
        return nothing
    return ZipSpan(
        start_off, end_off, lfh_size, compressed_size,
        _csv_cell_int(row, col, "uncompressed_size"), compression,
    )
end

# The `extra` keys the fetch engines read back out of a `ZipSpan`.
function _zip_span_extra(span::ZipSpan)
    return Dict{String, Any}(
        "start_off" => span.start_off,
        "end_off" => span.end_off,
        "lfh_size" => span.lfh_size,
        "compressed_size" => span.compressed_size,
        "compression" => span.compression,
    )
end

# `list_datasets` and `query` re-read the index on every call, and the committed maps are
# large (fastMRI ships ~10k rows), so memoise the parsed entries. The key carries mtime and
# size, so a refreshed or hand-edited index invalidates the memo on its own. Entries are
# immutable, so handing the same vector to several callers is safe.
const _INDEX_ENTRY_CACHE = Dict{Tuple{String, Float64, Int}, Vector{DatasetEntry}}()

function _cached_index_entries(path::AbstractString, parse)::Vector{DatasetEntry}
    isfile(path) || return DatasetEntry[]
    key = (String(path), mtime(path), filesize(path))
    hit = get(_INDEX_ENTRY_CACHE, key, nothing)
    hit === nothing || return hit
    entries = parse(path)::Vector{DatasetEntry}
    _INDEX_ENTRY_CACHE[key] = entries
    return entries
end

# Parse every row of an offset-map CSV with `row_to_entry(row, col)`, dropping rows it
# rejects (`nothing`). Shared by every map-backed source.
function _parse_offset_map(
        path::AbstractString, row_to_entry; key_column::AbstractString = "path",
    )::Vector{DatasetEntry}
    parsed = _read_offset_map(path; key_column = key_column)
    parsed === nothing && return DatasetEntry[]
    data, col = parsed
    entries = DatasetEntry[]
    for row in eachrow(data)
        e = row_to_entry(row, col)
        e === nothing || push!(entries, e)
    end
    return entries
end
