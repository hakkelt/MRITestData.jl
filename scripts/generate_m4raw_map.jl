#!/usr/bin/env julia
#
# Maintainer tool — generate data/m4raw_map.csv.
#
# Parses the ZIP central directory of each indexed M4Raw Zenodo archive over HTTP range
# requests and, for every fastMRI-layout `.h5` member, records its byte span inside the
# archive, the ZIP local-file-header length, the compressed/uncompressed sizes and the
# compression method, plus the study/contrast/repetition parsed from the file name and the
# `set` derived from the archive. The runtime (src/download/m4raw_fetch.jl) uses this to
# pull and (if Deflated) inflate a single `.h5` with an HTTP range request instead of
# downloading the whole archive.
#
# The corpus (Zenodo record 8056074, CC-BY-4.0) ships as several multi-GB ZIPs. By default
# this indexes the four data archives (multicoil train/val/test + GRE); the motion archive
# is metrics-only and skipped. Pass --archive NAME (repeatable) to index a subset.
#
# Usage:
#   julia scripts/generate_m4raw_map.jl [--archive NAME]... [--out data/m4raw_map.csv]
#
# Notes:
#   * No authentication is needed (public CC-BY); Zenodo serves the file from /content and
#     may redirect to a backing store, which this script resolves and re-resolves on expiry.
#   * The archives are >4 GB, so ZIP64 central-directory handling is mandatory.

import Downloads

const ZENODO_BASE = "https://zenodo.org/api/records/8056074/files/"

# Archive ZIP name => set label written into every row of that archive.
const ARCHIVE_SETS = [
    "M4RawV1.5_multicoil_train.zip" => "multicoil_train",
    "M4RawV1.5_multicoil_val.zip" => "multicoil_val",
    "M4Raw_multicoil_test.zip" => "multicoil_test",
    "M4RawV1.5_gre_data.zip" => "gre",
]

content_url(archive::AbstractString) = string(ZENODO_BASE, archive, "/content")

# ── HTTP-range-backed random access over one Zenodo archive ─────────────────────
#
# Zenodo serves the file directly from /content (no redirect) and honours byte-range
# requests, but rate-limits to ~133 requests/minute (sending `Retry-After: 60` on a 429).
# Since indexing reads one local-file-header per member, we pace requests under that limit
# and back off on a 429.

const REQUEST_GAP = 0.55          # seconds between requests (≈109/min, safely < 133/min)

mutable struct RangeReader
    archive::String
    total::Int           # archive size in bytes
end

# Issue a ranged GET against /content, returning the Response (with headers) and writing
# the body into `buf`. Retries on a 429 (rate limit), honouring Retry-After.
function _ranged_request(archive::AbstractString, off::Integer, n::Integer, buf::IO)
    headers = ["Range" => "bytes=$(Int(off))-$(Int(off) + Int(n) - 1)"]
    while true
        sleep(REQUEST_GAP)
        try
            return Downloads.request(content_url(archive); method = "GET", output = buf, headers = headers, throw = true)
        catch err
            err isa Downloads.RequestError && err.response.status == 429 || rethrow(err)
            wait_s = 60.0
            for (k, v) in err.response.headers
                lowercase(k) == "retry-after" || continue
                p = tryparse(Float64, strip(v))
                p === nothing || (wait_s = p)
            end
            @warn "rate-limited by Zenodo; backing off" archive wait_s
            sleep(wait_s + 1)
        end
    end
    return
end

function RangeReader(archive::AbstractString)
    buf = IOBuffer()
    resp = _ranged_request(archive, 0, 1, buf)
    total = 0
    for (k, v) in resp.headers
        if lowercase(k) == "content-range"           # "bytes 0-0/<total>"
            m = match(r"/(\d+)\s*$", v)
            m === nothing || (total = parse(Int, m.captures[1]))
        end
    end
    total > 0 || error("could not determine size of Zenodo archive $archive")
    return RangeReader(String(archive), total)
end

# Read `n` bytes at offset `off`.
function read_global(rr::RangeReader, off::Integer, n::Integer)
    buf = IOBuffer()
    _ranged_request(rr.archive, off, n, buf)
    return take!(buf)
end

_u16(b, i) = Int(b[i]) | (Int(b[i + 1]) << 8)
_u32(b, i) = Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16) | (Int(b[i + 3]) << 24)
_u64(b, i) = _u32(b, i) | (_u32(b, i + 4) << 32)

# ── Locate + parse the central directory (Zip64-aware) ──────────────────────────

const EOCD_SIG = 0x06054b50
const Z64_EOCD_LOCATOR_SIG = 0x07064b50
const Z64_EOCD_SIG = 0x06064b50
const CDH_SIG = 0x02014b50

function find_central_directory(rr::RangeReader)
    tail_len = min(rr.total, (1 << 16) + 256)
    tail = read_global(rr, rr.total - tail_len, tail_len)
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
        z64 = read_global(rr, z64_off, 56)
        _u32(z64, 1) == Z64_EOCD_SIG || error("bad Zip64 EOCD signature")
        n_entries = _u64(z64, 33)
        cd_size = _u64(z64, 41)
        cd_off = _u64(z64, 49)
    end
    return cd_off, cd_size, n_entries
end

struct CDEntry
    path::String
    lfh_offset::Int
    compressed_size::Int
    uncompressed_size::Int
    compression::Int
end

function parse_central_directory(rr::RangeReader)
    cd_off, cd_size, n_entries = find_central_directory(rr)
    cd = read_global(rr, cd_off, cd_size)
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

        endswith(name, "/") || push!(entries, CDEntry(name, lfh_off, comp_size, uncomp_size, compression))
        p += 46 + fn_len + extra_len + comment_len
    end
    return entries
end

# Read the actual local file header length (30 + fn_len + extra_len) at `lfh_offset`.
# The local extra field can differ from the central one, so this must be read directly.
function local_header_size(rr::RangeReader, lfh_offset::Int)
    h = read_global(rr, lfh_offset, 30)
    _u32(h, 1) == 0x04034b50 || error("bad local file header signature at $lfh_offset")
    fn_len = _u16(h, 27)
    extra_len = _u16(h, 29)
    return 30 + fn_len + extra_len
end

# ── Member selection + metadata ─────────────────────────────────────────────────

# Parse "<study>_<contrast><rep>.h5" → (study, contrast, repetition). The repetition is the
# trailing two digits; the contrast is the remaining token (e.g. "T1", "T2", "FLAIR").
# Returns ("", "", "") if the name does not match (kept verbatim by the caller).
function parse_meta(name::AbstractString)
    stem = replace(String(name), r"\.h5$"i => "")
    m = match(r"^(.+?)_([A-Za-z0-9]+?)(\d{2})$", stem)
    m === nothing && return "", "", ""
    return String(m.captures[1]), String(m.captures[2]), String(m.captures[3])
end

# ── Main ────────────────────────────────────────────────────────────────────────

function index_archive(io, archive::AbstractString, set::AbstractString)
    rr = RangeReader(archive)
    @info "archive" archive total = rr.total
    entries = parse_central_directory(rr)
    @info "central directory parsed" archive files = length(entries)

    kept = 0
    for e in entries
        endswith(lowercase(e.path), ".h5") || continue
        lfh = local_header_size(rr, e.lfh_offset)
        start_off = e.lfh_offset
        end_off = e.lfh_offset + lfh + e.compressed_size - 1     # inclusive
        study, contrast, rep = parse_meta(basename(e.path))
        println(
            io, join(
                (
                    e.path, start_off, end_off, lfh, e.compressed_size, e.uncompressed_size,
                    e.compression, archive, study, contrast, rep, set,
                ), ","
            )
        )
        kept += 1
    end
    @info "indexed archive" archive kept
    return kept
end

function main(args)
    out = normpath(joinpath(@__DIR__, "..", "data", "m4raw_map.csv"))
    wanted = String[]
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--archive"
            push!(wanted, args[i + 1]); i += 2
        elseif a == "--out"
            out = args[i + 1]; i += 2
        else
            error("unknown argument $(repr(a))")
        end
    end

    selected = isempty(wanted) ? ARCHIVE_SETS : [p for p in ARCHIVE_SETS if first(p) in wanted]
    isempty(selected) && error("no matching archives for $(wanted)")

    total_kept = 0
    open(out, "w") do io
        println(io, "path,start_off,end_off,lfh_size,compressed_size,uncompressed_size,compression,archive,study,contrast,repetition,set")
        for (archive, set) in selected
            total_kept += index_archive(io, archive, set)
        end
    end
    @info "wrote map" out total_kept
    return out
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main(ARGS)
