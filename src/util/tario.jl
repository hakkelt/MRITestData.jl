# Incremental (push-style) POSIX tar reader.
#
# The CMRxRecon-300 indexer decompresses a multi-hundred-GiB `.tar.gz` in one streaming
# pass and must record, for every member, the uncompressed offset of its payload and its
# size — without ever holding the whole archive in memory. This parser consumes the
# decompressed byte stream in arbitrary chunks (`feed!`) and invokes a callback for each
# regular file. Only payload offset + size are needed downstream, so directories and
# metadata members are skipped; GNU (`L`) and PAX (`x`) long-name records are resolved so
# members with paths longer than 100 bytes are reported with their full path.
#
# Pure (no external dependencies); included in the package so it can be unit-tested and
# reused by scripts/index_cmrxrecon300.jl.

module TarIO

# Internal module — names are referenced qualified (e.g. `TarIO.feed!`), so nothing is
# exported (keeps these out of the package's documented public API).

const BLOCK = 512

"""
    TarMember(path, data_offset, size)

A regular-file entry: `data_offset` is the member payload's offset in the uncompressed
tar stream (i.e. the byte just past its 512-byte header) and `size` is its byte length.
"""
struct TarMember
    path::String
    data_offset::Int
    size::Int
end

@enum _State NEED_HEADER COLLECT_META SKIP_DATA

"""
    TarScanner(on_member)

Push-style tar reader. Feed decompressed bytes with [`feed!`](@ref); `on_member` is
called with a [`TarMember`](@ref) for each regular file, in archive order.
"""
mutable struct TarScanner
    buf::Vector{UInt8}     # unconsumed bytes
    base::Int              # uncompressed offset of buf[1] (0-based)
    state::_State
    meta_kind::Symbol      # :longname (GNU L) or :pax (x) while in COLLECT_META
    meta_need::Int         # padded bytes of the metadata member still to collect
    meta_raw::Vector{UInt8}
    skip_need::Int         # padded file-data bytes still to skip
    pending_path::Union{Nothing, String}   # name override from a preceding L/x record
    on_member::Function
end

TarScanner(on_member::Function) =
    TarScanner(UInt8[], 0, NEED_HEADER, :none, 0, UInt8[], 0, nothing, on_member)

_pad(n::Integer) = cld(Int(n), BLOCK) * BLOCK

# Trim leading consumed bytes from buf, advancing base. Called after each consume so buf
# never grows unbounded (it holds at most one header/metadata member plus a feed chunk).
function _drop!(ts::TarScanner, n::Int)
    n <= 0 && return
    deleteat!(ts.buf, 1:n)
    ts.base += n
    return
end

# Extract a NUL-terminated string from a fixed-width header field.
function _cstr(b::AbstractVector{UInt8})
    z = findfirst(==(0x00), b)
    return String(b[1:(z === nothing ? length(b) : z - 1)])
end

# Parse a tar numeric field: octal ASCII, or GNU base-256 when the high bit is set.
function _tarnum(b::AbstractVector{UInt8})
    isempty(b) && return 0
    if (b[1] & 0x80) != 0
        v = Int(b[1] & 0x7f)
        for i in 2:length(b)
            v = (v << 8) | Int(b[i])
        end
        return v
    end
    s = strip(_cstr(b), [' ', '\0'])
    isempty(s) && return 0
    return parse(Int, s; base = 8)
end

# Parse a 512-byte header. Returns (path, size, typeflag) or nothing for a zero block.
function _parse_header(h::AbstractVector{UInt8})
    all(==(0x00), h) && return nothing
    name = _cstr(@view h[1:100])
    size = _tarnum(@view h[125:136])
    typeflag = Char(h[157])
    prefix = _cstr(@view h[346:500])
    path = isempty(prefix) ? name : string(prefix, "/", name)
    return path, size, typeflag
end

# Pull "path=" from a PAX extended-header payload (records: "<len> key=value\n").
function _pax_path(raw::AbstractVector{UInt8})
    s = String(copy(raw))
    for m in eachmatch(r"\d+ ([^=]+)=([^\n]*)\n", s)
        key = m.captures[1]
        (key === nothing || String(key) != "path") && continue
        val = m.captures[2]
        return val === nothing ? "" : String(val)
    end
    return nothing
end

"""
    feed!(ts::TarScanner, bytes, n)

Push the first `n` bytes of `bytes` (decompressed tar data) into the scanner.
"""
function feed!(ts::TarScanner, bytes::AbstractVector{UInt8}, n::Integer = length(bytes))
    n > 0 && append!(ts.buf, view(bytes, 1:Int(n)))
    while true
        if ts.state == SKIP_DATA
            drop = min(ts.skip_need, length(ts.buf))
            _drop!(ts, drop)
            ts.skip_need -= drop
            ts.skip_need == 0 && (ts.state = NEED_HEADER)
            ts.skip_need == 0 || return
        elseif ts.state == COLLECT_META
            take = min(ts.meta_need, length(ts.buf))
            # keep only the real (unpadded) metadata content we still want
            append!(ts.meta_raw, view(ts.buf, 1:take))
            _drop!(ts, take)
            ts.meta_need -= take
            ts.meta_need == 0 || return
            if ts.meta_kind == :longname
                ts.pending_path = _cstr(ts.meta_raw)
            else
                p = _pax_path(ts.meta_raw)
                p === nothing || (ts.pending_path = p)
            end
            ts.meta_raw = UInt8[]
            ts.state = NEED_HEADER
        else # NEED_HEADER
            length(ts.buf) < BLOCK && return
            hdr = _parse_header(@view ts.buf[1:BLOCK])
            header_off = ts.base
            _drop!(ts, BLOCK)
            if hdr === nothing
                continue   # zero block (end-of-archive padding); keep draining
            end
            path, size, typeflag = hdr
            if typeflag == 'L'
                # GNU long name: collect the padded data block; _cstr trims the padding.
                ts.state = COLLECT_META; ts.meta_kind = :longname
                ts.meta_need = _pad(size); ts.meta_raw = UInt8[]
            elseif typeflag == 'x' || typeflag == 'g'
                ts.state = COLLECT_META; ts.meta_kind = :pax
                ts.meta_need = _pad(size); ts.meta_raw = UInt8[]
            elseif typeflag == '0' || typeflag == '\0'
                pend = ts.pending_path
                full = pend === nothing ? path : pend
                ts.pending_path = nothing
                ts.on_member(TarMember(full, header_off + BLOCK, size))
                ts.skip_need = _pad(size)
                ts.state = SKIP_DATA
                ts.skip_need == 0 && (ts.state = NEED_HEADER)
            else
                # directory / symlink / other: no payload of interest, skip its data
                ts.pending_path = nothing
                ts.skip_need = _pad(size)
                ts.state = ts.skip_need == 0 ? NEED_HEADER : SKIP_DATA
            end
        end
    end
    return
end

end # module TarIO
