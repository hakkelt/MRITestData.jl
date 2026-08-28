# liblzma-backed xz block decompressor.
#
# fastMRI archives are `.tar.xz` files. Individual `.h5` members are extracted via HTTP
# range requests at the xz-block level: one block is fetched, decompressed, and the tar
# member is sliced out of the result. Unlike the gzip case (CMRxRecon-300 / zran.jl), the
# xz format has an explicit block index in the stream footer, so block boundaries are known
# without a forward scan; a pre-built offset map (data/fastmri_map.csv) records each
# member's block position.
#
# Decompression uses `lzma_stream_buffer_decode` (liblzma), which accepts a complete xz
# stream. Because we have only one block, we synthesise a minimal but valid xz stream
# around it: the original stream header (fetched once from the first 12 bytes of the
# archive), our block bytes, and a synthesised index + footer. CRC32 computations use
# libz (Zlib_jll, already a package dependency).
#
# This module is self-contained so the maintainer indexing script can `include` it
# standalone, and exposes these entry points:
#   `decompress_block(stream_header, block_data, unpadded_size, uncompressed_size)`
#   `parse_stream_footer(footer_bytes) -> backward_size::Int`
#   `index_range(archive_size, footer_bytes) -> (first_byte, last_byte)`
#   `parse_index(index_bytes) -> Vector{BlockRecord}`

module XzIO

import XZ_jll
using Zlib_jll: libz

# lzma_ret values we care about.
const LZMA_OK = Cuint(0)
const LZMA_STREAM_END = Cuint(1)

# xz stream header magic (6 bytes: \xfd 7 z X Z \x00).
const _XZ_MAGIC = UInt8[0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]

# ── CRC32 via libz ────────────────────────────────────────────────────────────────

function _crc32(data::AbstractVector{UInt8})::UInt32
    isempty(data) && return UInt32(0)
    GC.@preserve data begin
        c = ccall((:crc32, libz), Culong, (Culong, Ptr{UInt8}, Cuint), 0, pointer(data), Cuint(length(data)))
    end
    return UInt32(c & 0xffffffff)
end

# ── xz variable-length integer (VLI) ─────────────────────────────────────────────
# Each byte: bits 6-0 are data; bit 7 = 1 means more bytes follow (little-endian groups).

function _varint_encode(n::Int)::Vector{UInt8}
    n >= 0 || error("_varint_encode: negative value $n")
    out = UInt8[]
    while n > 0x7f
        push!(out, UInt8((n & 0x7f) | 0x80))
        n >>= 7
    end
    push!(out, UInt8(n))
    return out
end

function _varint_decode(data::AbstractVector{UInt8}, offset::Int)::Tuple{Int, Int}
    val = 0
    shift = 0
    while true
        offset > length(data) && error("_varint_decode: truncated varint at offset $offset")
        b = Int(data[offset])
        offset += 1
        if (b & 0x80) == 0
            val |= b << shift
            break
        else
            val |= (b & 0x7f) << shift
            shift += 7
        end
    end
    return val, offset
end

# ── Stream header parsing ─────────────────────────────────────────────────────────

"""
    parse_stream_header(hdr) -> (sf0::UInt8, sf1::UInt8)

Validate the 12-byte xz stream header and return the two Stream Flags bytes.
"""
function parse_stream_header(hdr::AbstractVector{UInt8})::Tuple{UInt8, UInt8}
    length(hdr) >= 12 || error("xz stream header too short ($(length(hdr)) bytes)")
    view(hdr, 1:6) == _XZ_MAGIC || error("not an xz stream: bad magic bytes")
    return hdr[7], hdr[8]
end

"""
    parse_stream_footer(ftr) -> backward_size::Int

Parse the 12-byte xz stream footer and return `backward_size`
(the index size in 4-byte units, minus 1; multiply by 4 and add 4 to get index bytes).
"""
function parse_stream_footer(ftr::AbstractVector{UInt8})::Int
    length(ftr) >= 12 || error("xz stream footer too short ($(length(ftr)) bytes)")
    ftr[11] == UInt8('Y') && ftr[12] == UInt8('Z') ||
        error("not an xz stream footer: bad magic (got $(ftr[11:12]))")
    # Footer layout: CRC32(4) | backward_size_le32(4) | stream_flags(2) | "YZ"(2)
    bs = Int(ftr[5]) | (Int(ftr[6]) << 8) | (Int(ftr[7]) << 16) | (Int(ftr[8]) << 24)
    return bs
end

# ── Stream index ──────────────────────────────────────────────────────────────────

"""
    BlockRecord

One entry of the xz stream Index, expanded into absolute positions.

- `archive_offset` — byte offset of the block in the `.xz` file.
- `archive_size` — padded compressed size, i.e. exactly the byte range to fetch.
- `unpadded_size` — compressed size excluding alignment padding (as recorded in the index).
- `uncompressed_size` — bytes produced by decompressing this block.
- `stream_offset` — byte offset in the concatenated decompressed stream where the block
  starts.
"""
struct BlockRecord
    archive_offset::Int
    archive_size::Int
    unpadded_size::Int
    uncompressed_size::Int
    stream_offset::Int
end

"""
    index_range(archive_size, footer) -> (first_byte, last_byte)

Byte range of the xz stream Index inside an archive of `archive_size` bytes, given its
12-byte stream `footer`. Both bounds are inclusive and 0-based.
"""
function index_range(archive_size::Int, footer::AbstractVector{UInt8})::Tuple{Int, Int}
    index_size = (parse_stream_footer(footer) + 1) * 4
    first_byte = archive_size - 12 - index_size
    return first_byte, first_byte + index_size - 1
end

"""
    parse_index(index_bytes) -> Vector{BlockRecord}

Walk the xz stream Index and return one [`BlockRecord`](@ref) per block, in stream order.
"""
function parse_index(idx::AbstractVector{UInt8})::Vector{BlockRecord}
    isempty(idx) && error("xz index: empty")
    idx[1] == 0x00 ||
        error("xz index: expected 0x00 indicator, got 0x$(string(idx[1], base = 16))")
    nrec, pos = _varint_decode(idx, 2)
    blocks = Vector{BlockRecord}(undef, nrec)
    archive_offset = 12   # blocks start just after the 12-byte stream header
    stream_offset = 0
    for i in 1:nrec
        unpadded, pos = _varint_decode(idx, pos)
        uncompressed, pos = _varint_decode(idx, pos)
        padded = (unpadded + 3) ÷ 4 * 4
        blocks[i] = BlockRecord(archive_offset, padded, unpadded, uncompressed, stream_offset)
        archive_offset += padded
        stream_offset += uncompressed
    end
    return blocks
end

# ── Synthetic xz stream assembly ──────────────────────────────────────────────────

# Build the xz Index for a single block. Returns the index bytes (always a multiple of
# 4 bytes, including the 4-byte CRC32 at the end).
function _build_index(unpadded_size::Int, uncompressed_size::Int)::Vector{UInt8}
    body = UInt8[0x00]  # Index Indicator
    append!(body, _varint_encode(1))                # Number of Records = 1
    append!(body, _varint_encode(unpadded_size))    # Unpadded Size of the block
    append!(body, _varint_encode(uncompressed_size)) # Uncompressed Size
    # Index Padding: 0–3 null bytes so the pre-CRC32 length is a multiple of 4.
    pad = (4 - (length(body) % 4)) % 4
    append!(body, zeros(UInt8, pad))
    # CRC32 of the entire padded body above.
    c = _crc32(body)
    push!(body, UInt8(c & 0xff))
    push!(body, UInt8((c >> 8) & 0xff))
    push!(body, UInt8((c >> 16) & 0xff))
    push!(body, UInt8((c >> 24) & 0xff))
    return body
end

# Build the 12-byte xz Stream Footer given the index size (in bytes, must be a multiple
# of 4) and the two Stream Flags bytes from the stream header.
function _build_footer(index_size::Int, sf0::UInt8, sf1::UInt8)::Vector{UInt8}
    index_size % 4 == 0 || error("index_size $index_size is not a multiple of 4")
    backward_size = div(index_size, 4) - 1
    bs_bytes = UInt8[
        backward_size & 0xff,
        (backward_size >> 8) & 0xff,
        (backward_size >> 16) & 0xff,
        (backward_size >> 24) & 0xff,
    ]
    sf_bytes = UInt8[sf0, sf1]
    # Footer CRC32 covers [Backward Size (4) | Stream Flags (2)].
    c = _crc32(vcat(bs_bytes, sf_bytes))
    ftr = UInt8[
        c & 0xff, (c >> 8) & 0xff, (c >> 16) & 0xff, (c >> 24) & 0xff,
    ]
    append!(ftr, bs_bytes)
    append!(ftr, sf_bytes)
    push!(ftr, UInt8('Y'))
    push!(ftr, UInt8('Z'))
    return ftr
end

# ── Public API ────────────────────────────────────────────────────────────────────

"""
    decompress_block(stream_header, block_data, unpadded_size, uncompressed_size) -> Vector{UInt8}

Decompress one xz block into its raw bytes.

- `stream_header` — the 12-byte xz stream header fetched from the archive (carries the
  check type, which must match the block's embedded check bytes).
- `block_data` — the range-requested block bytes: block header + LZMA2 payload + check
  value + 0–3 alignment padding bytes. Length equals `ceil(unpadded_size / 4) * 4`.
- `unpadded_size` — block size excluding alignment padding (from the xz stream index).
- `uncompressed_size` — expected decompressed byte count (from the xz stream index).

The block is wrapped in a minimal valid xz stream and decoded with
`lzma_stream_buffer_decode` (liblzma).
"""
function decompress_block(
        stream_header::AbstractVector{UInt8},
        block_data::AbstractVector{UInt8},
        unpadded_size::Int,
        uncompressed_size::Int,
    )::Vector{UInt8}
    sf0, sf1 = parse_stream_header(stream_header)
    idx = _build_index(unpadded_size, uncompressed_size)
    ftr = _build_footer(length(idx), sf0, sf1)

    # Synthesise: stream_header | block_data | index | footer. `block_data` is the large
    # part (tens–hundreds of MB); `vcat` copies it once into `stream`, no pre-conversion.
    stream = vcat(stream_header, block_data, idx, ftr)

    out = Vector{UInt8}(undef, uncompressed_size)
    memlimit = Ref(typemax(UInt64))
    in_pos = Ref(Csize_t(0))
    out_pos = Ref(Csize_t(0))

    GC.@preserve stream out begin
        ret = ccall(
            (:lzma_stream_buffer_decode, XZ_jll.liblzma),
            Cuint,
            (Ptr{UInt64}, Cuint, Ptr{Cvoid}, Ptr{UInt8}, Ptr{Csize_t}, Csize_t, Ptr{UInt8}, Ptr{Csize_t}, Csize_t),
            memlimit,
            Cuint(0),   # flags = 0 (verify checks)
            C_NULL,     # default allocator
            pointer(stream),
            in_pos,
            Csize_t(length(stream)),
            pointer(out),
            out_pos,
            Csize_t(length(out)),
        )
        (ret == LZMA_OK || ret == LZMA_STREAM_END) || error(
            "lzma_stream_buffer_decode failed (ret=$ret); " *
                "in_pos=$(in_pos[]) of $(length(stream)), out_pos=$(out_pos[]) of $uncompressed_size",
        )
    end
    return resize!(out, Int(out_pos[]))
end

end # module XzIO
