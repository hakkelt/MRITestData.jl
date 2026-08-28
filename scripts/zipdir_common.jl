# Zip64-aware ZIP central-directory reader, shared by the offset-map generators
# (`generate_m4raw_map.jl`, `generate_usc_speech_map.jl`, `generate_cmrxrecon2024_map.jl`).
#
# Each generator supplies its own *reader* — an object with a `total` field (archive size in
# bytes) and a `read_global(reader, offset, n)` method returning `n` bytes at a global byte
# offset. The three readers differ in how they reach the archive (Zenodo range requests with
# rate-limit backoff, a figshare pre-signed S3 URL re-resolved on expiry, local 4 GiB
# fragments stitched together), but the directory walk on top of them is identical, so it
# lives here and is duck-typed on `read_global`.
#
# All three corpora exceed 4 GB, so Zip64 handling is mandatory: when the 32-bit fields in
# the End Of Central Directory record are saturated, the real values come from the Zip64
# EOCD record (located via its locator), and per-entry sizes/offsets come from the Zip64
# extended information extra field (header id 0x0001).

# Little-endian integer reads from a byte buffer (`i` is a 1-based index).
_u16(b, i) = Int(b[i]) | (Int(b[i + 1]) << 8)
_u32(b, i) = Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16) | (Int(b[i + 3]) << 24)
_u64(b, i) = _u32(b, i) | (_u32(b, i + 4) << 32)

const EOCD_SIG = 0x06054b50
const Z64_EOCD_LOCATOR_SIG = 0x07064b50
const Z64_EOCD_SIG = 0x06064b50
const CDH_SIG = 0x02014b50
const LFH_SIG = 0x04034b50

# Total archive size from a 206 response's Content-Range header ("bytes 0-0/<total>"),
# or 0 when the server does not report one. Used by the HTTP-backed readers, whose
# archives have no local file to `filesize`.
function content_range_total(headers)
    for (k, v) in headers
        lowercase(k) == "content-range" || continue
        m = match(r"/(\d+)\s*$", v)
        m === nothing || return parse(Int, m.captures[1])
    end
    return 0
end

"""
    find_central_directory(reader) -> (cd_off, cd_size, n_entries)

Locate the central directory by scanning the archive tail for the End Of Central Directory
record, following the Zip64 locator when the 32-bit fields are saturated.
"""
function find_central_directory(reader)
    tail_len = min(reader.total, (1 << 16) + 256)
    tail = read_global(reader, reader.total - tail_len, tail_len)
    eocd = nothing
    for i in (length(tail) - 21):-1:1
        if _u32(tail, i) == EOCD_SIG
            eocd = i
            break
        end
    end
    eocd === nothing && error("EOCD record not found")

    cd_size = _u32(tail, eocd + 12)
    cd_off = _u32(tail, eocd + 16)
    n_entries = _u16(tail, eocd + 10)

    if cd_off == 0xFFFFFFFF || cd_size == 0xFFFFFFFF || n_entries == 0xFFFF
        loc = nothing
        for i in (eocd - 20):-1:1
            if _u32(tail, i) == Z64_EOCD_LOCATOR_SIG
                loc = i
                break
            end
        end
        loc === nothing && error("Zip64 EOCD locator not found")
        z64_off = _u64(tail, loc + 8)
        z64 = read_global(reader, z64_off, 56)
        _u32(z64, 1) == Z64_EOCD_SIG || error("bad Zip64 EOCD signature")
        n_entries = _u64(z64, 33)
        cd_size = _u64(z64, 41)
        cd_off = _u64(z64, 49)
    end
    return cd_off, cd_size, n_entries
end

"""
    CDEntry(path, lfh_offset, compressed_size, uncompressed_size, compression)

One central-directory record: `lfh_offset` is the global offset of the member's local file
header and `compression` is the ZIP method (0 = stored, 8 = Deflate).
"""
struct CDEntry
    path::String
    lfh_offset::Int
    compressed_size::Int
    uncompressed_size::Int
    compression::Int
end

"""
    parse_central_directory(reader) -> Vector{CDEntry}

Read every central-directory record, resolving Zip64 extended information where the 32-bit
fields are saturated. Directory entries (names ending in `/`) are skipped.
"""
function parse_central_directory(reader)
    cd_off, cd_size, n_entries = find_central_directory(reader)
    cd = read_global(reader, cd_off, cd_size)
    entries = CDEntry[]
    p = 1
    for _ in 1:n_entries
        _u32(cd, p) == CDH_SIG || error("bad central directory header at $p")
        compression = _u16(cd, p + 10)
        comp_size = _u32(cd, p + 20)
        uncomp_size = _u32(cd, p + 24)
        fn_len = _u16(cd, p + 28)
        extra_len = _u16(cd, p + 30)
        comment_len = _u16(cd, p + 32)
        lfh_off = _u32(cd, p + 42)
        name = String(cd[(p + 46):(p + 46 + fn_len - 1)])

        # Zip64 extended information extra field (0x0001) replaces saturated values, in
        # this fixed order and only for the fields that are actually saturated.
        ep = p + 46 + fn_len
        eend = ep + extra_len
        while ep < eend
            hid = _u16(cd, ep)
            hsz = _u16(cd, ep + 2)
            dp = ep + 4
            if hid == 0x0001
                if uncomp_size == 0xFFFFFFFF
                    uncomp_size = _u64(cd, dp); dp += 8
                end
                if comp_size == 0xFFFFFFFF
                    comp_size = _u64(cd, dp); dp += 8
                end
                if lfh_off == 0xFFFFFFFF
                    lfh_off = _u64(cd, dp); dp += 8
                end
            end
            ep += 4 + hsz
        end

        endswith(name, "/") ||
            push!(entries, CDEntry(name, lfh_off, comp_size, uncomp_size, compression))
        p += 46 + fn_len + extra_len + comment_len
    end
    return entries
end

"""
    local_header_size(reader, lfh_offset) -> Int

Length of the local file header at `lfh_offset` (30 + name + extra). The local extra field
can differ in length from the central one, so it must be read from the archive rather than
inferred from the central-directory record.
"""
function local_header_size(reader, lfh_offset::Int)
    h = read_global(reader, lfh_offset, 30)
    _u32(h, 1) == LFH_SIG || error("bad local file header signature at $lfh_offset")
    return 30 + _u16(h, 27) + _u16(h, 29)
end

"""
    member_span(reader, e::CDEntry) -> (start_off, end_off, lfh_size)

Inclusive byte span of one member (local file header plus payload) inside the archive —
exactly what the runtime range-requests — along with the header length needed to strip it.
"""
function member_span(reader, e::CDEntry)
    lfh = local_header_size(reader, e.lfh_offset)
    return e.lfh_offset, e.lfh_offset + lfh + e.compressed_size - 1, lfh
end
