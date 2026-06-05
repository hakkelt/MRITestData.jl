# On-disk cache layout and metadata sidecars.
#
# Files live under the package scratchspace (CACHE_DIR):
#   <cache>/<source_name>/<id>.h5         the dataset
#   <cache>/<source_name>/<id>.meta.toml  sidecar: url, size, sha256, timestamp
#
# Tests may override CACHE_DIR[] to point at a temporary directory.

"""Return the cache directory for `source`, creating it if necessary."""
function _source_dir(source::AbstractSource)
    isempty(CACHE_DIR[]) && error("cache directory not initialised; is MRITestData loaded?")
    dir = joinpath(CACHE_DIR[], source_name(source))
    isdir(dir) || mkpath(dir)
    return dir
end

# OCMR ids may contain no extension; mridata ids are bare UUIDs. We always store
# with a .h5 extension since both sources serve ISMRMRD HDF5.
_cache_basename(e::DatasetEntry) = string(e.id, ".h5")

"""
    cache_path(x) -> String

The path where the dataset for `x` (a [`DatasetEntry`](@ref) or
[`DatasetHandle`](@ref)) is or would be cached. Does not check existence.
"""
cache_path(e::DatasetEntry) = joinpath(_source_dir(e.source), _cache_basename(e))
cache_path(h::DatasetHandle) = cache_path(h.entry)

_meta_path(e::DatasetEntry) = cache_path(e) * ".meta.toml"

"""
    is_cached(x) -> Bool

Whether the dataset for `x` is already present in the cache. If the entry pins a
`sha256`, a recorded matching checksum in the sidecar is also required; otherwise
file existence suffices.
"""
function is_cached(e::DatasetEntry)
    path = cache_path(e)
    isfile(path) || return false
    e.sha256 === nothing && return true
    meta = _read_meta(e)
    return get(meta, "sha256", nothing) == e.sha256
end
is_cached(h::DatasetHandle) = is_cached(h.entry)

function _read_meta(e::DatasetEntry)
    mp = _meta_path(e)
    isfile(mp) || return Dict{String, Any}()
    return TOML.parsefile(mp)
end

function _write_meta(e::DatasetEntry, path::AbstractString, digest::AbstractString)
    meta = Dict{String, Any}(
        "id" => e.id,
        "url" => e.url,
        "sha256" => digest,
        "size_bytes" => filesize(path),
        "downloaded_at" => string(round(Int, time())),
    )
    open(_meta_path(e), "w") do io
        TOML.print(io, meta)
    end
    return meta
end

"""
    clear_cache(; source = nothing)

Delete cached files. With `source = nothing` (default) clears every source;
otherwise clears only that source's subdirectory.
"""
function clear_cache(; source::Union{AbstractSource, Nothing} = nothing)
    isempty(CACHE_DIR[]) && return nothing
    if source === nothing
        for s in list_sources()
            dir = joinpath(CACHE_DIR[], source_name(s))
            isdir(dir) && rm(dir; recursive = true)
        end
    else
        dir = joinpath(CACHE_DIR[], source_name(source))
        isdir(dir) && rm(dir; recursive = true)
    end
    return nothing
end
