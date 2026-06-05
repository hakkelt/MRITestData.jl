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
    vendor::Union{Symbol,Nothing} = nothing
    field_strength::Union{Float64,Nothing} = nothing
    trajectory::Symbol = :unknown
    coils::Union{Int,Nothing} = nothing
    fully_sampled::Union{Bool,Nothing} = nothing
    is3D::Union{Bool,Nothing} = nothing
    approx_size_bytes::Union{Int,Nothing} = nothing
    sha256::Union{String,Nothing} = nothing
    url::String
    extra::Dict{String,Any} = Dict{String,Any}()
end

function Base.show(io::IO, e::DatasetEntry)
    print(io, "DatasetEntry(", source_name(e.source), ":", e.id, ", ", repr(e.name))
    e.anatomy === :unknown || print(io, ", ", e.anatomy)
    e.trajectory === :unknown || print(io, ", ", e.trajectory)
    e.field_strength === nothing || print(io, ", ", e.field_strength, "T")
    print(io, ")")
end

"""
    DatasetHandle(entry::DatasetEntry)

A [`DatasetEntry`](@ref) bound for download/loading. Currently a thin wrapper that
lets the API accept either an entry or a handle; created by [`dataset`](@ref).
"""
struct DatasetHandle
    entry::DatasetEntry
end

entry(h::DatasetHandle) = h.entry
entry(e::DatasetEntry) = e

"""
    _matches(e::DatasetEntry; filters...) -> Bool

Test whether `e` satisfies every keyword `filter`. Each filter key is a field name
of [`DatasetEntry`](@ref); the value may be:

- a scalar — matched by `==`,
- a vector/tuple/set — matched by membership (`in`),
- a predicate function — matched by calling it on the field value.

A filter value of `nothing` is ignored (matches everything).
"""
function _matches(e::DatasetEntry; kwargs...)
    for (k, v) in kwargs
        v === nothing && continue
        fv = getfield(e, k)
        ok = if v isa Function
            v(fv)::Bool
        elseif v isa AbstractVector || v isa Tuple || v isa AbstractSet
            fv in v
        else
            fv == v
        end
        ok || return false
    end
    return true
end

"""
    list_datasets(source::AbstractSource; filters...) -> Vector{DatasetEntry}

Return the catalog entries for `source`, optionally narrowed by keyword `filters`
(see `_matches`). The catalog is read from a committed metadata file, so
this works offline.

# Examples
```julia
list_datasets(MRIDATA; anatomy = :knee, fully_sampled = true)
list_datasets(OCMR_SOURCE; field_strength = (1.5, 3.0))
list_datasets(MRIDATA; coils = c -> c !== nothing && c >= 8)
```
"""
function list_datasets(source::AbstractSource; offline::Bool = false, kwargs...)
    all_entries = _catalog_entries(source; offline = offline)
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
    return DatasetHandle(_synthesize_entry(source, String(id)))
end

# Per-source hooks implemented in mridata_catalog.jl / ocmr_catalog.jl.
function _catalog_entries end
function _synthesize_entry end
