# On-disk cache layout and metadata sidecars.
#
# Files live under the package scratchspace (CACHE_DIR):
#   <cache>/<source_name>/<id>.h5         the dataset
#   <cache>/<source_name>/<id>.meta.toml  sidecar: id, url, size, sha256, mtime, downloaded_at
#
# The sidecar stores enough information to verify the file without re-downloading:
#   - sha256: authoritative integrity check when the entry pins a checksum.
#   - mtime:  fast-path check (file modification time at download time). When no
#             sha256 is pinned, an unchanged mtime is sufficient to trust the cache.
#
# Tests may override CACHE_DIR[] to point at a temporary directory.

"""Return the cache directory for `source`, creating it if necessary."""
function _source_dir(source::AbstractSource)
    isempty(CACHE_DIR[]) && error("cache directory not initialised; is MRITestData loaded?")
    dir = joinpath(CACHE_DIR[], source_name(source))
    isdir(dir) || mkpath(dir)
    return dir
end

# OCMR ids may contain no extension; mridata ids are bare UUIDs. We store these
# with a .h5 extension since both sources serve ISMRMRD HDF5. Sources whose ids are
# already full filenames (e.g. CMRxRecon2024 paths ending in .mat) override this.
_cache_basename(e::DatasetEntry) = _cache_basename(e.source, e)
_cache_basename(::AbstractSource, e::DatasetEntry) = string(e.id, ".h5")

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

Whether the dataset for `x` is already present in the cache and unmodified.

Validation strategy (in order):
1. File must exist.
2. If the entry pins a `sha256`, the recorded checksum in the sidecar must match.
3. Otherwise the recorded `mtime` must match the file's current modification time
   (fast check; skipped when there is no sidecar yet).
"""
function is_cached(e::DatasetEntry)
    path = cache_path(e)
    isfile(path) || return false
    meta = _read_meta(e)
    if e.sha256 !== nothing
        return get(meta, "sha256", nothing) == e.sha256
    end
    # No pinned checksum: trust the cache if mtime hasn't changed.
    recorded_mtime = get(meta, "mtime", nothing)
    recorded_mtime === nothing && return true   # old sidecar without mtime — assume ok
    return recorded_mtime == string(mtime(path))
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
        "mtime" => string(mtime(path)),
        "size_bytes" => filesize(path),
        "downloaded_at" => string(round(Int, time())),
    )
    open(_meta_path(e), "w") do io
        TOML.print(io, meta)
    end
    return meta
end

"""
    copy_dataset(x, dest; force=false, verify=true, progress=true, max_bytes=nothing) -> String

Ensure the dataset for `x` is available at `dest`, downloading only if necessary.

1. If the Scratch cache already holds the file and it is unmodified (checked via
   the stored `sha256` or `mtime`), the file is **copied** to `dest` — no HTTP
   request is made.
2. If the cache is missing or stale, the file is **downloaded** first (into the
   Scratch cache) and then copied.

Returns `dest`. Keyword arguments are the same as [`download_dataset`](@ref).
"""
function copy_dataset(
        x::Union{DatasetEntry, DatasetHandle};
        dest::AbstractString,
        force::Bool = false,
        verify::Bool = true,
        progress::Bool = true,
        max_bytes::Union{Integer, Nothing} = nothing,
    )
    cached = download_dataset(x; force = force, verify = verify, progress = progress, max_bytes = max_bytes)
    dest = String(dest)
    if cached != dest
        mkpath(dirname(dest))
        cp(cached, dest; force = true)
    end
    return dest
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
