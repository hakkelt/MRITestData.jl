# M4Raw low-field brain range-extraction engine.
#
# The corpus ships as several multi-GB ZIPs on Zenodo (record 8056074). To pull one
# fastMRI-layout `.h5` member we:
#   1. look up its byte span + ZIP local-header length in the offset map
#      (catalog/m4raw_catalog.jl),
#   2. resolve the archive download URL (Zenodo serves /content, which may redirect to a
#      backing store),
#   3. issue an HTTP Range request for the member's byte span,
#   4. strip the ZIP local file header and, if the member is Deflated, inflate it.
#
# The data is public CC-BY, so unlike the CMRxRecon sources there is no token. The
# extracted file is fastMRI-layout (`kspace`/`reconstruction_rss`/`ismrmrd_header`), not a
# complete ISMRMRD file, so it is converted on first load (src/load/m4raw_ismrmrd.jl).

# Zenodo content endpoint for record 8056074; `<archive>` is the ZIP file name.
const _M4RAW_ZENODO_BASE = "https://zenodo.org/api/records/8056074/files/"

# M4Raw ids map to the in-archive `.h5` member; the cached file restores the extension
# (joinpath turns the id's slashes into a directory tree).
_cache_basename(::M4Raw, e::DatasetEntry) = string(e.id, ".h5")

_m4raw_content_url(archive::AbstractString) = string(_M4RAW_ZENODO_BASE, archive, "/content")

# Resolve the final download URL for a Zenodo archive. A 1-byte ranged GET follows any
# redirect to the backing store; `resp.url` is the final URL, valid for a subsequent
# range request.
function _m4raw_resolve_url(archive::AbstractString)::String
    url = _m4raw_content_url(archive)
    resp = Downloads.request(
        url; method = "GET", output = devnull,
        headers = ["Range" => "bytes=0-0"], throw = true,
    )
    return resp.url
end

# True for a 403/410 from the backing store (a redirect URL that expired between
# resolution and use).
_m4raw_is_expiry(err) = err isa Downloads.RequestError && (err.response.status == 403 || err.response.status == 410)

function _fetch_dataset(::M4Raw, e::DatasetEntry, dest::AbstractString; progress::Bool, verify::Bool)
    ex = e.extra
    archive = String(ex["archive"]::AbstractString)
    so = Int(ex["start_off"]::Integer)
    eo = Int(ex["end_off"]::Integer)
    lfh = Int(ex["lfh_size"]::Integer)
    comp = Int(ex["compression"]::Integer)

    total = eo - so + 1
    bar = progress ? ProgressMeter.Progress(total; desc = "Downloading $(e.name) ", dt = 0.2) : nothing
    cb = bar === nothing ? nothing : (_total, now) -> ProgressMeter.update!(bar, min(Int(now), total))

    url = _m4raw_resolve_url(archive)
    bytes = try
        _download_range(url, so, eo; on_progress = cb)
    catch err
        # The resolved URL may have expired mid-flight; resolve a fresh one and retry once.
        _m4raw_is_expiry(err) || rethrow(err)
        url = _m4raw_resolve_url(archive)
        _download_range(url, so, eo; on_progress = cb)
    end
    bar === nothing || ProgressMeter.finish!(bar)

    # Strip the ZIP local file header to isolate the (possibly compressed) payload.
    length(bytes) > lfh ||
        error("fetched $(length(bytes)) bytes for $(e.id), fewer than the $(lfh)-byte local header")
    payload = bytes[(lfh + 1):end]

    raw = if comp == 8
        CodecZlib.transcode(CodecZlib.DeflateDecompressor, payload)
    elseif comp == 0
        payload
    else
        error("unsupported ZIP compression method $(comp) for $(e.id)")
    end

    mkpath(dirname(dest))
    tmp = dest * ".part"
    try
        write(tmp, raw)
    catch err
        isfile(tmp) && rm(tmp; force = true)
        rethrow(err)
    end
    mv(tmp, dest; force = true)
    _write_meta(e, dest, _sha256_hex(dest))
    return dest
end
