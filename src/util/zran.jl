# zlib random access (zran) for gzip streams.
#
# A `.tar.gz` is a single continuous DEFLATE stream, so an individual member cannot be
# inflated in isolation the way a ZIP entry can. The zran technique (Mark Adler's
# zran.c) works around this: a one-time pass over the stream records periodic
# *checkpoints* — at each, the exact (compressed, uncompressed) byte offsets plus the
# 32 KiB sliding-window dictionary needed to resume inflation from that point. Given a
# checkpoint, a raw-DEFLATE decoder can be primed (`inflateSetDictionary`, plus
# `inflatePrime` for the sub-byte bit offset) and fed compressed bytes starting at the
# checkpoint, so a single member is recovered by an HTTP range request rather than a
# full download.
#
# This module is self-contained (depends only on Zlib_jll) so the maintainer indexer
# script can `include` it standalone, and provides two push-style drivers:
#   * `ScanState`    — full forward pass that captures checkpoints (offline indexer).
#   * `ExtractState` — random-access decode seeded from one checkpoint (runtime).
# Neither package internals nor a seekable input are required; both consume compressed
# bytes pushed in arbitrary chunks, which suits a network stream spanning fragments.
#
# The CMRxRecon-300 PoC verified the libz bindings and the bit-aligned-checkpoint
# round-trip against zlib 1.3.1 on this platform.

module Zran

using Zlib_jll: libz

# Internal module — all names are referenced qualified (e.g. `Zran.ScanState`), so nothing
# is exported (keeps these out of the package's documented public API).

# zlib return codes / flush modes we use.
const Z_OK = Cint(0)
const Z_STREAM_END = Cint(1)
const Z_NEED_DICT = Cint(2)
const Z_BUF_ERROR = Cint(-5)
const Z_NO_FLUSH = Cint(0)
const Z_BLOCK = Cint(5)

# windowBits arguments: 47 = 32 + 15 auto-detects a gzip/zlib header; -15 selects a
# raw DEFLATE stream with no header (used when resuming mid-stream from a checkpoint).
const WBITS_AUTO = Cint(47)
const WBITS_RAW = Cint(-15)

const WINDOW_SIZE = 32768   # DEFLATE's maximum back-reference distance.

# ── z_stream and libz ccall wrappers ────────────────────────────────────────────
# Field order/types mirror zlib.h's z_stream on an LP64 platform; sizeof must equal
# the C struct (verified 112 bytes against zlib 1.3.1) or inflateInit2_ rejects it.
mutable struct ZStream
    next_in::Ptr{UInt8}
    avail_in::Cuint
    total_in::Culong
    next_out::Ptr{UInt8}
    avail_out::Cuint
    total_out::Culong
    msg::Ptr{UInt8}
    state::Ptr{Cvoid}
    zalloc::Ptr{Cvoid}
    zfree::Ptr{Cvoid}
    opaque::Ptr{Cvoid}
    data_type::Cint
    adler::Culong
    reserved::Culong
end
ZStream() = ZStream(C_NULL, 0, 0, C_NULL, 0, 0, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, 0, 0, 0)

_zlib_version() = unsafe_string(ccall((:zlibVersion, libz), Cstring, ()))

function _inflate_init!(s::ZStream, windowbits::Integer)
    ret = ccall(
        (:inflateInit2_, libz), Cint, (Ref{ZStream}, Cint, Cstring, Cint),
        s, Cint(windowbits), _zlib_version(), Cint(sizeof(ZStream)),
    )
    ret == Z_OK || error("inflateInit2_ failed (code $ret)")
    return s
end

_inflate!(s::ZStream, flush::Cint) = ccall((:inflate, libz), Cint, (Ref{ZStream}, Cint), s, flush)
_inflate_end!(s::ZStream) = ccall((:inflateEnd, libz), Cint, (Ref{ZStream},), s)

function _set_dictionary!(s::ZStream, dict::Vector{UInt8})
    ret = GC.@preserve dict ccall(
        (:inflateSetDictionary, libz), Cint, (Ref{ZStream}, Ptr{UInt8}, Cuint),
        s, pointer(dict), Cuint(length(dict)),
    )
    ret == Z_OK || error("inflateSetDictionary failed (code $ret)")
    return nothing
end

function _prime!(s::ZStream, bits::Integer, value::Integer)
    ret = ccall((:inflatePrime, libz), Cint, (Ref{ZStream}, Cint, Cint), s, Cint(bits), Cint(value))
    ret == Z_OK || error("inflatePrime failed (code $ret)")
    return nothing
end

# ── Checkpoint ──────────────────────────────────────────────────────────────────
"""
    Checkpoint

A resumable position in a gzip stream. `comp_off`/`unc_off` are the compressed and
uncompressed byte offsets at a DEFLATE block boundary. DEFLATE blocks are not
byte-aligned, so `bits` (0–7) carries the sub-byte remainder of the previous byte and
`prev_byte` is that byte; when `bits > 0` the decoder is seeded with
`inflatePrime(bits, prev_byte >> (8 - bits))`. `window` is the 32 KiB of uncompressed
data preceding `unc_off`, injected via `inflateSetDictionary`.
"""
struct Checkpoint
    comp_off::Int
    unc_off::Int
    bits::Int
    prev_byte::UInt8
    window::Vector{UInt8}
end

# ── Forward-scan driver (indexer) ────────────────────────────────────────────────
"""
    ScanState(interval; on_output)

Push-style driver for a single forward pass over a gzip stream. Feed compressed bytes
with [`scan_feed!`](@ref); every decompressed chunk is handed to `on_output(buf, n)`
(for tar parsing), and a [`Checkpoint`](@ref) is captured at the first DEFLATE block
boundary at or after each `interval` compressed bytes. Finish with [`scan_finish!`](@ref).
"""
mutable struct ScanState
    s::ZStream
    win::Vector{UInt8}     # rolling 32 KiB of decompressed output (ends at the chunk start
    winlen::Int            #   while `on_output` runs, since the roll happens after it)
    consumed_before::Int   # total_in when the current input buffer was installed
    prev_tail::UInt8       # last byte of the previously fed chunk
    have_tail::Bool
    # Descriptor of the block boundary at the start of the chunk currently being handed to
    # `on_output` — i.e. the nearest boundary at or before any byte in that chunk. A
    # `scan_capture!` from inside `on_output` snapshots a checkpoint here.
    cb_comp_off::Int
    cb_unc_off::Int
    cb_bits::Int
    cb_prev_byte::UInt8
    checkpoints::Vector{Checkpoint}
    on_output::Function
    outbuf::Vector{UInt8}
end

function ScanState(; on_output::Function = (buf, n) -> nothing)
    s = _inflate_init!(ZStream(), WBITS_AUTO)
    # The initial chunk-start boundary is the stream start: comp_off 0, unc_off 0, no
    # window. A capture here yields a "gzip-start" checkpoint (see ExtractState).
    return ScanState(
        s, zeros(UInt8, WINDOW_SIZE), 0, 0, 0x00, false,
        0, 0, 0, 0x00, Checkpoint[], on_output, Vector{UInt8}(undef, 1 << 18),
    )
end

"""
    scan_capture!(st::ScanState)

Record a [`Checkpoint`](@ref) at the block boundary starting the chunk currently being
processed (call only from within `on_output`). Used to place a checkpoint just before a
file of interest; repeated calls at the same boundary are coalesced.
"""
function scan_capture!(st::ScanState)
    isempty(st.checkpoints) || st.checkpoints[end].comp_off != st.cb_comp_off || return
    window = st.cb_unc_off == 0 ? UInt8[] : copy(view(st.win, 1:st.winlen))
    push!(st.checkpoints, Checkpoint(st.cb_comp_off, st.cb_unc_off, st.cb_bits, st.cb_prev_byte, window))
    return
end

# Roll the trailing 32 KiB window forward with `n` freshly produced output bytes.
function _roll_window!(st::ScanState, n::Int)
    n <= 0 && return
    if n >= WINDOW_SIZE
        copyto!(st.win, 1, st.outbuf, n - WINDOW_SIZE + 1, WINDOW_SIZE)
        st.winlen = WINDOW_SIZE
    else
        keep = min(st.winlen, WINDOW_SIZE - n)
        keep > 0 && copyto!(st.win, 1, st.win, st.winlen - keep + 1, keep)
        copyto!(st.win, keep + 1, st.outbuf, 1, n)
        st.winlen = keep + n
    end
    return
end

"""
    scan_feed!(st::ScanState, bytes) -> Bool

Push compressed `bytes` into the scan. Returns `true` once the stream end is reached.
"""
function scan_feed!(st::ScanState, bytes::AbstractVector{UInt8})
    isempty(bytes) && return false
    buf = bytes isa Vector{UInt8} ? bytes : Vector{UInt8}(bytes)
    st.consumed_before = Int(st.s.total_in)
    finished = false
    GC.@preserve buf begin
        st.s.next_in = pointer(buf)
        st.s.avail_in = Cuint(length(buf))
        while st.s.avail_in > 0
            GC.@preserve st begin
                st.s.next_out = pointer(st.outbuf)
                st.s.avail_out = Cuint(length(st.outbuf))
                ret = _inflate!(st.s, Z_BLOCK)
                produced = length(st.outbuf) - Int(st.s.avail_out)
                # `on_output` sees this chunk while win/cb_* still describe the chunk-start
                # boundary; a `scan_capture!` from inside it therefore snapshots that
                # boundary. The window roll happens only afterwards.
                if produced > 0
                    st.on_output(st.outbuf, produced)
                    _roll_window!(st, produced)
                end
                if ret == Z_STREAM_END
                    finished = true
                    break
                end
                (ret == Z_OK || ret == Z_BUF_ERROR) ||
                    error("inflate failed during scan (code $ret)")
                # Now at a block boundary: make it the chunk-start boundary for the next
                # chunk (a non-final boundary; the final one carries bit 64).
                if (st.s.data_type & 128) != 0 && (st.s.data_type & 64) == 0
                    consumed_in_chunk = Int(st.s.total_in) - st.consumed_before
                    prev = consumed_in_chunk >= 1 ? buf[consumed_in_chunk] :
                        (st.have_tail ? st.prev_tail : 0x00)
                    st.cb_comp_off = Int(st.s.total_in)
                    st.cb_unc_off = Int(st.s.total_out)
                    st.cb_bits = Int(st.s.data_type & 7)
                    st.cb_prev_byte = prev
                end
                ret == Z_BUF_ERROR && st.s.avail_out == length(st.outbuf) && break
            end
        end
        if length(buf) > 0
            st.prev_tail = buf[end]
            st.have_tail = true
        end
    end
    return finished
end

"""
    scan_finish!(st::ScanState) -> Vector{Checkpoint}

Release the inflate state and return the captured checkpoints.
"""
function scan_finish!(st::ScanState)
    _inflate_end!(st.s)
    return st.checkpoints
end

# ── Random-access extractor (runtime) ────────────────────────────────────────────
"""
    ExtractState(ckpt; skip, nbytes)

Push-style random-access decoder seeded from `ckpt`. After construction, feed
compressed bytes (starting at `ckpt.comp_off`) with [`extract_feed!`](@ref); the first
`skip` decompressed bytes are discarded and the next `nbytes` are collected into
`.out`. Stop feeding once [`extract_done`](@ref) is true.
"""
mutable struct ExtractState
    s::ZStream
    skip_remaining::Int
    want::Int
    out::Vector{UInt8}
    outbuf::Vector{UInt8}
    done::Bool
end

function ExtractState(ckpt::Checkpoint; skip::Integer, nbytes::Integer)
    # Raw DEFLATE resumed at the checkpoint: prime the sub-byte bit remainder (when the
    # boundary is mid-byte) and seed the 32 KiB dictionary. The stream-start checkpoint
    # sits at the first block (comp_off just past the gzip header) with bits 0 and an empty
    # window — no prime or dictionary, since the first block has no back-references.
    s = _inflate_init!(ZStream(), WBITS_RAW)
    ckpt.bits != 0 && _prime!(s, ckpt.bits, ckpt.prev_byte >> (8 - ckpt.bits))
    isempty(ckpt.window) || _set_dictionary!(s, ckpt.window)
    out = Vector{UInt8}(undef, 0)
    sizehint!(out, Int(nbytes))
    return ExtractState(s, Int(skip), Int(nbytes), out, Vector{UInt8}(undef, 1 << 18), false)
end

extract_done(st::ExtractState) = st.done

"""
    extract_feed!(st::ExtractState, bytes) -> Bool

Push compressed `bytes` into the extractor. Returns `true` once the requested payload
has been fully collected (or the stream ended).
"""
function extract_feed!(st::ExtractState, bytes::AbstractVector{UInt8})
    (st.done || isempty(bytes)) && return st.done
    buf = bytes isa Vector{UInt8} ? bytes : Vector{UInt8}(bytes)
    GC.@preserve buf begin
        st.s.next_in = pointer(buf)
        st.s.avail_in = Cuint(length(buf))
        while st.s.avail_in > 0 && !st.done
            GC.@preserve st begin
                st.s.next_out = pointer(st.outbuf)
                st.s.avail_out = Cuint(length(st.outbuf))
                ret = _inflate!(st.s, Z_NO_FLUSH)
                produced = length(st.outbuf) - Int(st.s.avail_out)
                off = 1
                if st.skip_remaining > 0 && produced > 0
                    drop = min(st.skip_remaining, produced)
                    st.skip_remaining -= drop
                    off += drop
                end
                if off <= produced && length(st.out) < st.want
                    take = min(produced - off + 1, st.want - length(st.out))
                    append!(st.out, view(st.outbuf, off:(off + take - 1)))
                end
                length(st.out) >= st.want && (st.done = true)
                if ret == Z_STREAM_END
                    st.done = true
                    break
                end
                (ret == Z_OK || ret == Z_BUF_ERROR) ||
                    error("inflate failed during extract (code $ret)")
                ret == Z_BUF_ERROR && st.s.avail_out == length(st.outbuf) && break
            end
        end
    end
    st.done && _inflate_end!(st.s)
    return st.done
end

# ── Index (de)serialisation ──────────────────────────────────────────────────────
# Compact binary blob: magic, interval, count, then per checkpoint a fixed header and
# the raw 32 KiB window. Callers may gzip the whole blob when storing it on disk.
const _INDEX_MAGIC = b"ZRX1"

"""
    write_index(io, interval, checkpoints)

Serialise `checkpoints` (captured with `interval` compressed-byte spacing) to `io`.
"""
function write_index(io::IO, interval::Integer, checkpoints::AbstractVector{Checkpoint})
    write(io, _INDEX_MAGIC)
    write(io, Int64(interval))
    write(io, Int64(length(checkpoints)))
    for c in checkpoints
        write(io, Int64(c.comp_off), Int64(c.unc_off), Int32(c.bits), c.prev_byte)
        write(io, Int32(length(c.window)))
        write(io, c.window)
    end
    return nothing
end

"""
    read_index(io) -> (interval::Int, checkpoints::Vector{Checkpoint})

Inverse of [`write_index`](@ref). `checkpoints` are returned sorted by `comp_off`.
"""
function read_index(io::IO)
    magic = read(io, 4)
    magic == _INDEX_MAGIC || error("not a zran index (bad magic $(magic))")
    interval = Int(read(io, Int64))
    n = Int(read(io, Int64))
    cps = Vector{Checkpoint}(undef, n)
    for i in 1:n
        comp_off = Int(read(io, Int64))
        unc_off = Int(read(io, Int64))
        bits = Int(read(io, Int32))
        prev_byte = read(io, UInt8)
        wlen = Int(read(io, Int32))
        window = read(io, wlen)
        cps[i] = Checkpoint(comp_off, unc_off, bits, prev_byte, window)
    end
    return interval, cps
end

end # module Zran
