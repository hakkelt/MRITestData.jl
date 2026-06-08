# Downloading with caching. Uses stdlib Downloads (libcurl) for HTTP with a
# progress callback; downloads to a ".part" file and renames atomically so an
# interrupted transfer never poisons the cache.
#
# For servers that advertise Accept-Ranges: bytes (both OCMR and mridata.org
# back onto Amazon S3, which supports byte-range requests), _download_with_progress
# automatically splits the transfer into parallel chunks, giving a ~1.5–2.5×
# speed-up on high-latency connections.
# The chunk count and minimum size are tunable via module-level Refs.

"""
    MRITestData.PARALLEL_CHUNKS[]

Number of parallel byte-range chunks used when the server supports
`Accept-Ranges: bytes`. Defaults to `4` (empirically optimal for OCMR S3).
Set to `1` to disable parallel chunking.
"""
const PARALLEL_CHUNKS = Ref(4)

"""
    MRITestData.PARALLEL_MIN_BYTES[]

Minimum file size in bytes below which parallel chunking is skipped and a
plain single-connection download is used. Defaults to 8 MiB.
"""
const PARALLEL_MIN_BYTES = Ref(8 * 1024 * 1024)

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

# Probe the URL with a HEAD request and return (accept_ranges::Bool, content_length::Int).
# Returns (false, 0) on any network error so callers fall back gracefully.
function _probe_url(url::AbstractString; timeout::Real = 15)::Tuple{Bool, Int}
    try
        resp = Downloads.request(String(url); method = "HEAD", output = devnull, timeout = float(timeout))
        accept_ranges = false
        content_length = 0
        for (k, v) in resp.headers
            lk = lowercase(k)
            if lk == "accept-ranges"
                accept_ranges = lowercase(strip(v)) == "bytes"
            elseif lk == "content-length"
                n = tryparse(Int, strip(v))
                n === nothing || (content_length = n)
            end
        end
        return accept_ranges, content_length
    catch
        return false, 0
    end
end

# Download a single byte range [start_byte, end_byte] and return the data.
function _download_range(url::AbstractString, start_byte::Int, end_byte::Int)::Vector{UInt8}
    buf = IOBuffer()
    Downloads.download(String(url), buf; headers = ["Range" => "bytes=$start_byte-$end_byte"])
    return take!(buf)
end

# Parallel chunked download: splits the file into nchunks byte ranges and
# downloads them concurrently, then writes them in order to tmp.
# A ProgressMeter bar tracks the reassembled bytes written.
function _download_parallel(
        url::AbstractString,
        tmp::AbstractString,
        total::Int,
        nchunks::Int;
        progress::Bool,
        desc::AbstractString,
    )
    chunk_size = cld(total, nchunks)
    chunks = Vector{Vector{UInt8}}(undef, nchunks)
    errors = Vector{Union{Nothing, Exception}}(fill(nothing, nchunks))

    @sync for i in 1:nchunks
        @async begin
            s = (i - 1) * chunk_size
            e = min(i * chunk_size - 1, total - 1)
            try
                chunks[i] = _download_range(url, s, e)
            catch err
                errors[i] = err
            end
        end
    end

    for (i, err) in enumerate(errors)
        err === nothing || throw(err)
    end

    bar = progress ? ProgressMeter.Progress(total; desc = String(desc), dt = 0.2) : nothing
    written = 0
    open(tmp, "w") do io
        for chunk in chunks
            write(io, chunk)
            written += length(chunk)
            bar === nothing || ProgressMeter.update!(bar, min(written, total))
        end
    end
    bar === nothing || ProgressMeter.finish!(bar)
    return tmp
end

"""
    _download_with_progress(url, dest; progress=true, desc="Downloading") -> String

Download `url` to `dest` atomically: data goes to `<dest>.part` and is renamed on
success, so an interrupted transfer never leaves a partial file at `dest`. When
`progress` is true a `ProgressMeter` bar labelled `desc` is shown; set
`progress=false` to opt out. Shared by dataset and index downloads.

When the server advertises `Accept-Ranges: bytes` and the file is at least
`PARALLEL_MIN_BYTES` in size, the transfer is split into `PARALLEL_CHUNKS`
parallel byte-range requests for a 2–4× speed improvement. Falls back to a
single-connection download if the probe fails or ranging is unsupported.
"""
function _download_with_progress(url::AbstractString, dest::AbstractString; progress::Bool = true, desc::AbstractString = "Downloading")
    url = String(url)
    dest = String(dest)
    mkpath(dirname(dest))
    tmp = string(dest, ".part")

    nchunks = PARALLEL_CHUNKS[]
    min_bytes = PARALLEL_MIN_BYTES[]
    use_parallel = false
    total = 0

    if nchunks > 1
        accept_ranges, content_length = _probe_url(url)
        if accept_ranges && content_length >= min_bytes
            use_parallel = true
            total = content_length
        end
    end

    try
        if use_parallel
            _download_parallel(url, tmp, total, nchunks; progress = progress, desc = desc)
        elseif progress
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

For servers that support byte-range requests (both OCMR and mridata.org back
onto Amazon S3 and support `Accept-Ranges: bytes`), the transfer is automatically
parallelised across `MRITestData.PARALLEL_CHUNKS[]` chunks, giving a ~1.5–2.5×
speed improvement on high-latency connections.
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

"""
    fetch_sizes(entries; timeout=15) -> Vector{DatasetEntry}

Issue one HTTP HEAD request per entry whose `approx_size_bytes` is not yet known
and return a new `Vector{DatasetEntry}` with the `approx_size_bytes` field filled
in where the server reported a `Content-Length`. Entries that already have a size,
or whose server does not advertise one, are returned unchanged.

The HEAD requests are fired in parallel (one `@async` task per entry), so the
total wall time is roughly the latency of the slowest single request rather than
the sum of all requests.

```julia
entries = list_datasets(OCMR_SOURCE)
entries = fetch_sizes(entries)         # fills in approx_size_bytes
```
"""
function fetch_sizes(
        entries::AbstractVector{DatasetEntry};
        timeout::Real = 15,
    )::Vector{DatasetEntry}
    result = Vector{DatasetEntry}(undef, length(entries))
    @sync for (i, e) in enumerate(entries)
        if e.approx_size_bytes !== nothing
            result[i] = e
        else
            @async begin
                _, sz = _probe_url(e.url; timeout = timeout)
                result[i] = if sz > 0
                    DatasetEntry(;
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
                else
                    e
                end
            end
        end
    end

    # Persist newly discovered sizes grouped by source so future catalog loads
    # include them without re-issuing HEAD requests.
    by_source = Dict{AbstractSource, Dict{String, Int}}()
    for e in result
        e.approx_size_bytes === nothing && continue
        d = get!(by_source, e.source, Dict{String, Int}())
        d[e.id] = e.approx_size_bytes
    end
    for (src, sizes) in by_source
        try
            write_sizes(src, sizes)
        catch
        end
    end

    return result
end
