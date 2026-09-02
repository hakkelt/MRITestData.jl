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

# Download a single byte range [start_byte, end_byte] and return the data. An optional
# `on_progress(total, now)` callback (the Downloads progress signature) drives a bar.
function _download_range(
        url::AbstractString, start_byte::Int, end_byte::Int;
        on_progress::Union{Nothing, Function} = nothing,
    )::Vector{UInt8}
    buf = IOBuffer()
    headers = ["Range" => "bytes=$start_byte-$end_byte"]
    if on_progress === nothing
        Downloads.download(String(url), buf; headers = headers)
    else
        Downloads.download(String(url), buf; headers = headers, progress = on_progress)
    end
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

# Compressed bytes pulled per HTTP Range request while streaming toward a member inside a
# gzip archive (CMRxRecon-300, fastMRI `.tar.gz`).
const _RANGE_BLOCK_BYTES = 4 * 1024 * 1024

# Run `f(update)` against a ProgressMeter bar covering `total` units, finishing the bar
# afterwards. `update(n)` reports absolute progress and clamps to `total`; when `progress`
# is false it is a no-op, so the range-extraction fetchers never branch on a nullable bar.
function _with_progress(f, total::Integer, desc::AbstractString; progress::Bool)
    progress || return f(_ -> nothing)
    cap = Int(total)
    bar = ProgressMeter.Progress(cap; desc = String(desc), dt = 0.2)
    try
        return f(n -> ProgressMeter.update!(bar, min(Int(n), cap)))
    finally
        ProgressMeter.finish!(bar)
    end
end

# Progress description shared by every source-specific fetcher.
_download_desc(e::DatasetEntry) = "Downloading $(e.name) "

# Move an already-written `<dest>.part` into place and record the sidecar meta.
function _finalize_part(e::DatasetEntry, dest::AbstractString, tmp::AbstractString)
    mv(tmp, dest; force = true)
    _write_meta(e, dest, _sha256_hex(dest))
    return dest
end

# Write an in-memory member to `dest` atomically (via `<dest>.part`) and record the sidecar
# meta. Shared by the range-extraction fetchers, which assemble the member in memory.
function _finalize_download(e::DatasetEntry, dest::AbstractString, bytes::AbstractVector{UInt8})
    mkpath(dirname(dest))
    tmp = dest * ".part"
    try
        write(tmp, bytes)
    catch err
        isfile(tmp) && rm(tmp; force = true)
        rethrow(err)
    end
    return _finalize_part(e, dest, tmp)
end

# Fetch the byte range [so, eo] from a URL that must be resolved just in time and may
# expire mid-flight (figshare / Zenodo redirect to a short-lived pre-signed URL).
# `resolve()` returns a fresh URL; `is_expiry(err)` recognises the expiry response.
function _download_range_resolving(
        resolve, is_expiry, so::Int, eo::Int;
        on_progress::Union{Nothing, Function} = nothing,
    )::Vector{UInt8}
    url = resolve()
    return try
        _download_range(url, so, eo; on_progress = on_progress)
    catch err
        is_expiry(err) || rethrow(err)
        _download_range(resolve(), so, eo; on_progress = on_progress)
    end
end

# Recover the member's ZIP coordinates from a catalog entry's `locator`.
function _zip_span(e::DatasetEntry)
    ex = e.locator
    return ZipSpan(
        Int(ex["start_off"]::Integer),
        Int(ex["end_off"]::Integer),
        Int(ex["lfh_size"]::Integer),
        Int(ex["compressed_size"]::Integer),
        nothing,
        Int(ex["compression"]::Integer),
    )
end

# Strip the ZIP local file header from a range-fetched member and inflate it when the entry
# is Deflated. `id` only names the entry in error messages.
function _zip_member_payload(
        bytes::Vector{UInt8}, lfh_size::Int, compression::Int, id::AbstractString,
    )::Vector{UInt8}
    length(bytes) > lfh_size ||
        error("fetched $(length(bytes)) bytes for $(id), fewer than the $(lfh_size)-byte local header")
    payload = bytes[(lfh_size + 1):end]
    compression == 0 && return payload
    compression == 8 && return CodecZlib.transcode(CodecZlib.DeflateDecompressor, payload)
    return error("unsupported ZIP compression method $(compression) for $(id)")
end

# Range-fetch one ZIP member, strip its local file header, inflate it if Deflated, and
# write it to `dest`. Shared by the two public-archive sources (M4Raw on Zenodo, USC Speech
# on figshare); they differ only in how the download URL is resolved and which HTTP status
# signals that the resolved URL expired.
function _fetch_zip_member(
        e::DatasetEntry, dest::AbstractString, resolve, is_expiry; progress::Bool,
    )
    span = _zip_span(e)
    total = span.end_off - span.start_off + 1
    bytes = _with_progress(total, _download_desc(e); progress = progress) do update
        _download_range_resolving(
            resolve, is_expiry, span.start_off, span.end_off;
            on_progress = (_total, now) -> update(now),
        )
    end
    payload = _zip_member_payload(bytes, span.lfh_size, span.compression, e.id)
    return _finalize_download(e, dest, payload)
end

# Drive a zran extraction to completion and return the member bytes. `read_block(pos)`
# returns the next slice of the compressed stream starting at absolute offset `pos`, or an
# empty vector at end of stream. Errors if the stream ends before `nbytes` are produced.
function _zran_extract(
        e::DatasetEntry, ck::Zran.Checkpoint, skip::Int, nbytes::Int, read_block;
        progress::Bool,
    )::Vector{UInt8}
    out = _with_progress(nbytes, _download_desc(e); progress = progress) do update
        ex = Zran.ExtractState(ck; skip = skip, nbytes = nbytes)
        pos = ck.comp_off
        while !Zran.extract_done(ex)
            bytes = read_block(pos)
            isempty(bytes) && break
            Zran.extract_feed!(ex, bytes)
            pos += length(bytes)
            update(length(ex.out))
        end
        return ex.out
    end

    length(out) == nbytes ||
        error("extracted $(length(out)) bytes for $(e.id), expected $nbytes — the index may be stale")
    return out
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
    download_dataset(x; path=nothing, force=false, verify=true, progress=true, max_bytes=nothing) -> String

Download the dataset for `x` (a [`DatasetEntry`](@ref) or [`DatasetHandle`](@ref))
into the cache and return its path. If already cached (see [`is_cached`](@ref)) the
cached path is returned without re-downloading unless `force=true`.

A download destination must be configured with [`set_download_path!`](@ref) first;
until then this throws. Passing `path` is the exception — see below.

- `path`: download into this directory instead of the configured cache and return the
  file path there. Works even when no default download path has been set. The file is
  reused on a later call if it is already present (unless `force=true`); no `.meta.toml`
  freshness tracking is done for an explicit `path`.
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
        path::Union{AbstractString, Nothing} = nothing,
        force::Bool = false,
        verify::Bool = true,
        progress::Bool = true,
        max_bytes::Union{Integer, Nothing} = nothing,
    )
    if path === nothing
        _require_download_path()
        dest = cache_path(e)
        already = !force && is_cached(e)
    else
        dir = abspath(String(path))
        mkpath(dir)
        dest = joinpath(dir, _cache_basename(e))
        already = !force && isfile(dest)
    end
    if already
        return dest
    end

    if max_bytes !== nothing && e.approx_size_bytes !== nothing && e.approx_size_bytes > max_bytes
        error(
            "dataset $(e.id) is ~$(e.approx_size_bytes) bytes, exceeding max_bytes=$(max_bytes); " *
                "raise max_bytes or set it to `nothing` to download anyway.",
        )
    end

    _fetch_dataset(e.source, e, dest; progress = progress, verify = verify)
    return dest
end
download_dataset(h::DatasetHandle; kwargs...) = download_dataset(h.entry; kwargs...)

# Source-dispatched fetch primitive. The default (OCMR / mridata.org) downloads the
# entry's `url` directly; sources that need bespoke retrieval (e.g. CMRxRecon2024's
# range-extraction from a split Synapse archive) add their own method.
function _fetch_dataset(::AbstractSource, e::DatasetEntry, dest::AbstractString; progress::Bool, verify::Bool)
    _download_with_progress(e.url, dest; progress = progress, desc = "Downloading $(e.name) ")
    digest = _sha256_hex(dest)
    if verify && e.sha256 !== nothing && digest != e.sha256
        rm(dest; force = true)
        error("checksum mismatch for $(e.id):\n  expected $(e.sha256)\n  got      $(digest)")
    end
    _write_meta(e, dest, digest)
    return dest
end

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
                result[i] = sz > 0 ? _with_size(e, sz) : e
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
