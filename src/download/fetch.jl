# Downloading with caching. Uses stdlib Downloads (libcurl) for HTTP with a
# progress callback; downloads to a ".part" file and renames atomically so an
# interrupted transfer never poisons the cache.

"""Stream the SHA-256 of a file as a lowercase hex string."""
function _sha256_hex(path::AbstractString)
    return open(path, "r") do io
        return bytes2hex(sha256(io))
    end
end

function _verify_sha256(path::AbstractString, expected::AbstractString)
    got = _sha256_hex(path)
    got == expected || error(
        "checksum mismatch for $(basename(path)):\n  expected $(expected)\n  got      $(got)",
    )
    return got
end

# Build a Downloads.download progress callback backed by a ProgressMeter bar.
# `Downloads` reports (total, now) in bytes; `total` is 0 until headers arrive, so
# the bar is created lazily on the first callback with a known total.
function _progress_callback(desc::AbstractString)
    bar = Ref{Union{Nothing, ProgressMeter.Progress}}(nothing)
    return (total, now) -> begin
        total == 0 && return
        p = bar[]
        if p === nothing
            p = ProgressMeter.Progress(total; desc = desc, dt = 0.2)
            bar[] = p
        end
        ProgressMeter.update!(p, min(now, total))
        return
    end
end

"""
    _download_with_progress(url, dest; progress=true, desc="Downloading") -> String

Download `url` to `dest` atomically: data goes to `<dest>.part` and is renamed on
success, so an interrupted transfer never leaves a partial file at `dest`. When
`progress` is true a `ProgressMeter` bar labelled `desc` is shown; set
`progress=false` to opt out. Shared by dataset and index downloads.
"""
function _download_with_progress(url::AbstractString, dest::AbstractString; progress::Bool = true, desc::AbstractString = "Downloading")
    url = String(url)
    dest = String(dest)
    mkpath(dirname(dest))
    tmp = string(dest, ".part")
    try
        if progress
            Downloads.download(url, tmp; progress = _progress_callback(String(desc)))
        else
            Downloads.download(url, tmp)
        end
    catch err
        isfile(tmp) && rm(tmp; force = true)
        rethrow(err)
    end
    mv(tmp, dest; force = true)
    return dest
end

"""
    download_dataset(x; force=false, verify=true, progress=true, max_bytes=nothing) -> String

Download the dataset for `x` (a [`DatasetEntry`](@ref) or [`DatasetHandle`](@ref))
into the cache and return its path. If already cached (see [`is_cached`](@ref)) the
cached path is returned without re-downloading unless `force=true`.

- `verify`: when the entry pins a `sha256`, verify the download against it.
- `progress`: show a `ProgressMeter` bar (set `false` to opt out).
- `max_bytes`: if the entry's `approx_size_bytes` exceeds this, error before
  downloading. Use this in tests/CI to avoid pulling large files by accident.

The download goes to `<path>.part` and is atomically renamed on success; a sidecar
`.meta.toml` records the url, size and computed checksum.
"""
function download_dataset(
        e::DatasetEntry;
        force::Bool = false,
        verify::Bool = true,
        progress::Bool = true,
        max_bytes::Union{Integer, Nothing} = nothing,
    )
    dest = cache_path(e)
    if !force && is_cached(e)
        return dest
    end

    if max_bytes !== nothing && e.approx_size_bytes !== nothing && e.approx_size_bytes > max_bytes
        error(
            "dataset $(e.id) is ~$(e.approx_size_bytes) bytes, exceeding max_bytes=$(max_bytes); " *
                "raise max_bytes or set it to `nothing` to download anyway.",
        )
    end

    _download_with_progress(e.url, dest; progress = progress, desc = "Downloading $(e.name) ")

    digest = _sha256_hex(dest)
    if verify && e.sha256 !== nothing && digest != e.sha256
        rm(dest; force = true)
        error("checksum mismatch for $(e.id):\n  expected $(e.sha256)\n  got      $(digest)")
    end

    _write_meta(e, dest, digest)
    return dest
end
download_dataset(h::DatasetHandle; kwargs...) = download_dataset(h.entry; kwargs...)
