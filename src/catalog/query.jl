# Cross-source query: search one or several sources with the same filter
# vocabulary as `list_datasets`, plus free-text and `extra`-field matching.
# Backs the interactive TUI in `tui.jl`.

"""
    query(; sources = list_sources(), text = nothing, offline = false, filters...)
        -> Vector{DatasetEntry}

Search across one or several dataset sources and return the matching entries.

This is the cross-source counterpart of [`list_datasets`](@ref): it queries every
source in `sources` and concatenates the results, applying the same keyword
`filters`. Unknown keywords (those that are not [`DatasetEntry`](@ref) fields) are
matched against the per-source `extra` metadata, so you can filter on source-specific
attributes such as `subject = "patient"` or `scanner_model = "Siemens MAGNETOM Sola"`.

# Keywords
- `sources`: a single source or a collection of sources to search
  (default: all of [`list_sources`](@ref)).
- `text`: a case-insensitive substring (or a predicate, or a `Regex`) matched against
  the entry's `name`, `id`, and the string values in `extra`. `nothing` disables it.
- `offline`: pass `true` to use only the committed fallback index (no network).
- `filters...`: per-field filters as in [`list_datasets`](@ref) / `_matches`. A field
  filter value may be a scalar (`==`), a collection (`in`), or a predicate. Keys that
  are not `DatasetEntry` fields are looked up in `extra`.

# Examples
```julia
query(; anatomy = :knee, fully_sampled = true)                 # both sources
query(; sources = OCMR_SOURCE, field_strength = (1.5, 3.0))
query(; text = "prisma")                                       # free-text over name/id/extra
query(; subject = "patient")                                   # an OCMR `extra` field
query(; field_strength = f -> f !== nothing && f >= 3.0)
```
"""
function query(;
        sources = list_sources(),
        text::Union{Nothing, AbstractString, Regex, Function} = nothing,
        offline::Bool = false,
        kwargs...,
    )
    srcs = sources isa AbstractSource ? (sources,) : sources
    field_filters = Dict{Symbol, Any}()
    extra_filters = Dict{String, Any}()
    for (k, v) in kwargs
        if k in _DATASET_ENTRY_FIELDS
            field_filters[k] = v
        else
            extra_filters[String(k)] = v
        end
    end
    out = DatasetEntry[]
    for s in srcs
        for e in _catalog_entries(s; offline = offline)
            _matches(e; field_filters...) || continue
            _matches_extra(e, extra_filters) || continue
            _matches_text(e, text) || continue
            push!(out, e)
        end
    end
    return out
end

const _DATASET_ENTRY_FIELDS = Set(fieldnames(DatasetEntry))

# Match `extra` filters with the same semantics as `_matches` (scalar/collection/
# predicate). A missing key is `nothing`; a `nothing` filter value matches anything.
function _matches_extra(e::DatasetEntry, filters::AbstractDict)
    for (k, v) in filters
        v === nothing && continue
        fv = get(e.extra, k, nothing)
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

# Free-text match over name, id, and the string-valued `extra` entries.
_matches_text(::DatasetEntry, ::Nothing) = true
_matches_text(e::DatasetEntry, pred::Function) = pred(e)::Bool
function _matches_text(e::DatasetEntry, needle::Union{AbstractString, Regex})
    _text_hit(e.name, needle) && return true
    _text_hit(e.id, needle) && return true
    for v in values(e.extra)
        v isa AbstractString && _text_hit(v, needle) && return true
    end
    return false
end

_text_hit(hay::AbstractString, needle::Regex) = occursin(needle, hay)
_text_hit(hay::AbstractString, needle::AbstractString) =
    occursin(lowercase(needle), lowercase(hay))
