# fastMRI range-extraction engine.
#
# Supports two archive formats:
#
# .tar.xz (knee, brain): Each member's absolute byte position in the decompressed tar
#   stream is recorded in the offset map (tar_data_offset, file_size). At download time
#   the xz block structure is read on-the-fly via two small range requests (stream footer
#   + index, < 20 KB total), overlapping blocks are fetched and decompressed, and the
#   member bytes are spliced out.
#
# .tar.gz (prostate, breast): A gzip stream is not randomly seekable. A per-archive
#   zran checkpoint index (data/fastmri_zran/<stem>.bin.gz, built by
#   scripts/index_fastmri_gz.jl) records a DEFLATE-block-boundary checkpoint just before
#   each member. At download time the nearest checkpoint is selected, a raw-inflate
#   decoder is seeded from it, and compressed bytes are streamed from the checkpoint
#   position in the S3 archive until the member payload is collected.
#

# Per-session cache: archive key → (stream_header_bytes, block_index).
const _FASTMRI_BLOCK_CACHE = Dict{String, Tuple{Vector{UInt8}, Vector{XzIO.BlockRecord}}}()

function _fastmri_block_list(archive::AbstractString, url::AbstractString)
    haskey(_FASTMRI_BLOCK_CACHE, archive) && return _FASTMRI_BLOCK_CACHE[archive]

    # Fetch the stream footer (last 12 bytes); the same response's Content-Range reports
    # the total archive size. A HEAD would not do: the pre-signed URL's signature covers
    # GET only, and this request also returns bytes we need.
    buf = IOBuffer()
    r = Downloads.request(url; output = buf, headers = Dict("Range" => "bytes=-12"))
    footer_bytes = take!(buf)
    cidx = findfirst(p -> lowercase(p.first) == "content-range", r.headers)
    cidx === nothing &&
        error("S3 did not return Content-Range for $archive — cannot determine archive size")
    cm = match(r"/(\d+)$", r.headers[cidx].second)
    cm === nothing && error("Cannot parse Content-Range header for $archive")
    c1 = cm.captures[1]
    c1 === nothing && error("Cannot parse Content-Range header for $archive")
    ar_size = parse(Int, c1)

    idx_first, idx_last = XzIO.index_range(ar_size, footer_bytes)
    blocks = XzIO.parse_index(_download_range(url, idx_first, idx_last))
    stream_hdr = _download_range(url, 0, 11)

    _FASTMRI_BLOCK_CACHE[archive] = (stream_hdr, blocks)
    return stream_hdr, blocks
end

# ── .tar.gz extraction via zran checkpoints ──────────────────────────────────

const _FASTMRI_ZRAN_DIR = normpath(joinpath(@__DIR__, "..", "..", "data", "fastmri_zran"))
const _FASTMRI_GZ_INDEX = Dict{String, Vector{Zran.Checkpoint}}()

function _fastmri_gz_index_path(archive::AbstractString)
    stem = replace(basename(archive), r"\.(tar\.gz|tgz)$"i => "")
    return joinpath(_FASTMRI_ZRAN_DIR, stem * ".bin.gz")
end

function _load_fastmri_gz_index!(archive::AbstractString)
    haskey(_FASTMRI_GZ_INDEX, archive) && return _FASTMRI_GZ_INDEX[archive]
    path = _fastmri_gz_index_path(archive)
    isfile(path) || error(
        "missing zran checkpoint index for $(repr(archive)) at $(path); " *
            "generate it with scripts/index_fastmri_gz.jl",
    )
    raw = CodecZlib.transcode(CodecZlib.GzipDecompressor, read(path))
    _, cps = Zran.read_index(IOBuffer(raw))
    _FASTMRI_GZ_INDEX[archive] = cps
    return cps
end

function _fetch_gz(
        e::DatasetEntry, archive::AbstractString,
        tar_data_offset::Int, file_size::Int,
        dest::AbstractString; progress::Bool,
    )
    url = get_fastmri_url(archive)
    cps = _load_fastmri_gz_index!(archive)
    isempty(cps) && error("empty checkpoint index for $archive; re-run scripts/index_fastmri_gz.jl")

    ck = Zran.nearest_checkpoint(cps, tar_data_offset)
    bytes = _zran_extract(
        e, ck, tar_data_offset - ck.unc_off, file_size,
        pos -> _download_range(url, pos, pos + _RANGE_BLOCK_BYTES - 1);
        progress = progress,
    )
    return _finalize_download(e, dest, bytes)
end

# ── Entry point ───────────────────────────────────────────────────────────────

_cache_basename(::FastMRI, e::DatasetEntry) = string(e.id, ".h5")

function _fetch_dataset(::FastMRI, e::DatasetEntry, dest::AbstractString; progress::Bool, verify::Bool)
    ex = e.locator
    archive = String(ex["archive"]::AbstractString)
    tar_data_offset = Int(ex["tar_data_offset"]::Integer)
    file_size = Int(ex["file_size"]::Integer)

    # Dispatch on archive format.
    if endswith(lowercase(archive), ".tar.gz") || endswith(lowercase(archive), ".tgz")
        return _fetch_gz(e, archive, tar_data_offset, file_size, dest; progress = progress)
    end

    url = get_fastmri_url(archive)
    stream_hdr, blocks = _fastmri_block_list(archive, url)

    # Blocks overlapping [tar_data_offset, tar_data_offset + file_size).
    tar_end = tar_data_offset + file_size
    overlapping = filter(
        b -> tar_data_offset < b.stream_offset + b.uncompressed_size && tar_end > b.stream_offset,
        blocks,
    )
    isempty(overlapping) &&
        error("No xz blocks overlap tar_data_offset=$tar_data_offset for $(e.id) — rebuild map")

    mkpath(dirname(dest))
    tmp = dest * ".part"
    try
        _with_progress(file_size, _download_desc(e); progress = progress) do update
            fetched = Ref(0)
            open(tmp, "w") do out
                for b in overlapping
                    raw = _download_range(
                        url, b.archive_offset, b.archive_offset + b.archive_size - 1;
                        on_progress = (_total, now) -> update(fetched[] + Int(now)),
                    )
                    fetched[] += length(raw)
                    d = XzIO.decompress_block(stream_hdr, raw, b.unpadded_size, b.uncompressed_size)

                    lo = max(0, tar_data_offset - b.stream_offset)
                    hi = min(b.uncompressed_size, tar_end - b.stream_offset)
                    write(out, @view d[(lo + 1):hi])
                end
            end
        end

        actual = filesize(tmp)
        actual == file_size ||
            error("expected $file_size bytes for $(e.id), assembled $actual — map may be stale")
    catch err
        isfile(tmp) && rm(tmp; force = true)
        rethrow(err)
    end

    return _finalize_part(e, dest, tmp)
end
