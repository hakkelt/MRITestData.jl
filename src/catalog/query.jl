# Cross-source query: search one or several sources with the same filter
# vocabulary as `list_datasets`, plus free-text and `extra`-field matching.
# Backs the interactive browser in `browse.jl`.

"""
    query(; sources = list_sources(), text = missing, offline = false, filters...)
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
  the entry's `name`, `id`, and the string values in `extra`. `missing` (the default)
  disables it.
- `offline`: pass `true` to use only the committed fallback index (no network).
- `filters...`: per-field filters as in [`list_datasets`](@ref) / `_matches`. A
  filter value may be a scalar (`==`), a collection (`in`), a predicate, or `missing` for
  no filter. Keys that are not `DatasetEntry` fields are looked up in `extra`, where a key
  the entry does not carry reads as `nothing`.

`nothing` is a value rather than a wildcard, so `fully_sampled = nothing` selects entries
with unknown sampling and `subject = nothing` selects entries carrying no `subject` key.

# Examples
```julia
query(; anatomy = :knee, fully_sampled = true)                 # every source
query(; sources = OCMR_SOURCE, field_strength = (1.5, 3.0))
query(; text = "prisma")                                       # free-text over name/id/extra
query(; subject = "patient")                                   # an OCMR `extra` field
query(; field_strength = f -> f !== nothing && f >= 3.0)
query(; coils = nothing)                                       # coil count not recorded
```
"""
function query(;
        sources = list_sources(),
        text::Union{Missing, Nothing, AbstractString, Regex, Function} = missing,
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
    # Case-insensitive substring search compares against lowercased haystacks, so fold the
    # needle once here rather than once per candidate string of every entry.
    needle = text isa AbstractString ? lowercase(text) : text
    out = DatasetEntry[]
    for s in srcs
        for e in _catalog_entries(s; offline = offline)
            # The filters are passed as dictionaries, not splatted back into keyword
            # arguments: splatting a run-time `Dict` rebuilds the keyword tuple for every
            # candidate entry, which dominates the cost of a filtered query.
            _matches(e, field_filters) || continue
            _matches_extra(e, extra_filters) || continue
            _matches_text(e, needle) || continue
            push!(out, e)
        end
    end
    return out
end

const _DATASET_ENTRY_FIELDS = Set(fieldnames(DatasetEntry))

# Match `extra` filters with the same semantics as `_matches`, against `extra` keys instead
# of named fields. A key the entry does not carry reads as `nothing`.
function _matches_extra(e::DatasetEntry, filters::AbstractDict{String})
    for (k, v) in filters
        _filter_hit(get(e.extra, k, nothing), v) || return false
    end
    return true
end

# Free-text match over name, id, and the string-valued `extra` entries. A string `needle`
# must already be lowercased — `query` folds it once before the entry loop. `nothing` is
# accepted alongside `missing` for "no text filter": unlike a field filter, it cannot be
# confused with a value to match, since `name`/`id`/`extra` strings are never `nothing`.
_matches_text(::DatasetEntry, ::Missing) = true
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
# `needle` is already lowercased by `query`; only the haystack is folded here.
_text_hit(hay::AbstractString, needle::AbstractString) = occursin(needle, lowercase(hay))
