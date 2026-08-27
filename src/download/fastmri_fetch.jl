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
# Block list entry (xz): (archive_offset, padded_compressed_size, unpadded_size,
#                          uncompressed_size, tar_start_offset)

# Per-session cache: archive key → (stream_header_bytes, block_list).
const _FASTMRI_BLOCK_CACHE = Dict{String, Tuple{Vector{UInt8}, Vector{NTuple{5, Int}}}}()

function _fastmri_block_list(archive::AbstractString, url::AbstractString)
    haskey(_FASTMRI_BLOCK_CACHE, archive) && return _FASTMRI_BLOCK_CACHE[archive]

    # Fetch stream footer (last 12 bytes) + total archive size via Content-Range.
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

    backward_size = XzIO.parse_stream_footer(footer_bytes)
    index_size = (backward_size + 1) * 4
    idx_start = ar_size - 12 - index_size

    buf2 = IOBuffer()
    Downloads.request(
        url; output = buf2,
        headers = Dict("Range" => "bytes=$idx_start-$(ar_size - 13)")
    )
    idx_bytes = take!(buf2)

    idx_bytes[1] == 0x00 || error("xz index: expected 0x00 indicator for $archive")
    pos = 2
    nrec, pos = XzIO._varint_decode(idx_bytes, pos)

    stream_hdr = _download_range(url, 0, 11)
    blocks = NTuple{5, Int}[]
    arch_off = 12
    tar_start = 0
    for _ in 1:nrec
        upsz, pos = XzIO._varint_decode(idx_bytes, pos)
        uncsz, pos = XzIO._varint_decode(idx_bytes, pos)
        padded = (upsz + 3) ÷ 4 * 4
        push!(blocks, (arch_off, padded, upsz, uncsz, tar_start))
        arch_off += padded
        tar_start += uncsz
    end

    _FASTMRI_BLOCK_CACHE[archive] = (stream_hdr, blocks)
    return stream_hdr, blocks
end

# ── .tar.gz extraction via zran checkpoints ──────────────────────────────────

const _FASTMRI_ZRAN_DIR = normpath(joinpath(@__DIR__, "..", "..", "data", "fastmri_zran"))
const _FASTMRI_GZ_INDEX = Dict{String, Vector{Zran.Checkpoint}}()
const _FASTMRI_GZ_BLOCK = 4 * 1024 * 1024  # compressed bytes per range request

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

    # Nearest checkpoint with unc_off ≤ tar_data_offset.
    ck = _nearest_checkpoint(cps, tar_data_offset)
    ex = Zran.ExtractState(ck; skip = tar_data_offset - ck.unc_off, nbytes = file_size)
    bar = progress ? ProgressMeter.Progress(file_size; desc = "Downloading $(e.name) ", dt = 0.2) : nothing

    pos = ck.comp_off
    while !Zran.extract_done(ex)
        rend = pos + _FASTMRI_GZ_BLOCK - 1
        bytes = _download_range(url, pos, rend)
        isempty(bytes) && break
        Zran.extract_feed!(ex, bytes)
        pos += length(bytes)
        bar === nothing || ProgressMeter.update!(bar, min(length(ex.out), file_size))
    end
    bar === nothing || ProgressMeter.finish!(bar)

    length(ex.out) == file_size ||
        error("extracted $(length(ex.out)) bytes for $(e.id), expected $file_size — map may be stale")

    mkpath(dirname(dest))
    tmp = dest * ".part"
    try
        write(tmp, ex.out)
    catch err
        isfile(tmp) && rm(tmp; force = true)
        rethrow(err)
    end
    mv(tmp, dest; force = true)
    _write_meta(e, dest, _sha256_hex(dest))
    return dest
end

# ── Entry point ───────────────────────────────────────────────────────────────

_cache_basename(::FastMRI, e::DatasetEntry) = string(e.id, ".h5")

function _fetch_dataset(::FastMRI, e::DatasetEntry, dest::AbstractString; progress::Bool, verify::Bool)
    ex = e.extra
    archive = String(ex["archive"]::AbstractString)
    tar_data_offset = Int(ex["tar_data_offset"]::Integer)
    file_size = Int(ex["file_size"]::Integer)

    # Dispatch on archive format.
    if endswith(lowercase(archive), ".tar.gz") || endswith(lowercase(archive), ".tgz")
        return _fetch_gz(e, archive, tar_data_offset, file_size, dest; progress = progress)
    end

    url = get_fastmri_url(archive)
    stream_hdr, blocks = _fastmri_block_list(archive, url)

    # Find blocks overlapping [tar_data_offset, tar_data_offset + file_size).
    tar_end = tar_data_offset + file_size
    overlap_indices = Int[]
    for (i, (_, _, _, uncsz, tar_start)) in enumerate(blocks)
        tar_data_offset < tar_start + uncsz && tar_end > tar_start &&
            push!(overlap_indices, i)
    end
    isempty(overlap_indices) &&
        error("No xz blocks overlap tar_data_offset=$tar_data_offset for $(e.id) — rebuild map")

    bar = progress ?
        ProgressMeter.Progress(file_size; desc = "Downloading $(e.name) ", dt = 0.2) : nothing
    bytes_fetched = Ref(0)

    mkpath(dirname(dest))
    tmp = dest * ".part"
    try
        open(tmp, "w") do out
            for i in overlap_indices
                arch_off, arch_sz, upsz, uncsz, tar_start = blocks[i]

                cb = if bar !== nothing
                    (_total, now) -> begin
                        bytes_fetched[] += Int(now)
                        ProgressMeter.update!(bar, min(bytes_fetched[], file_size))
                    end
                else
                    nothing
                end

                raw = _download_range(url, arch_off, arch_off + arch_sz - 1; on_progress = cb)
                d = XzIO.decompress_block(stream_hdr, raw, upsz, uncsz)

                lo = max(0, tar_data_offset - tar_start)
                hi = min(uncsz, tar_end - tar_start)
                write(out, @view d[(lo + 1):hi])
            end
        end

        actual = filesize(tmp)
        actual == file_size ||
            error("expected $file_size bytes for $(e.id), assembled $actual — map may be stale")
    catch err
        isfile(tmp) && rm(tmp; force = true)
        rethrow(err)
    end
    bar === nothing || ProgressMeter.finish!(bar)

    mv(tmp, dest; force = true)
    _write_meta(e, dest, _sha256_hex(dest))
    return dest
end
