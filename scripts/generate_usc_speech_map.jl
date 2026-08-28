#!/usr/bin/env julia
#
# Maintainer tool — generate data/usc_speech_map.csv.
#
# Parses the ZIP central directory of a USC SPAN 75-speaker figshare archive over HTTP
# range requests and, for every 2drt raw spiral k-space member
# (`<subject>/2drt/raw/<subject>_2drt_<stem>_raw.h5`), records its byte span inside the
# archive, the ZIP local-file-header length, the compressed/uncompressed sizes and the
# compression method, plus the subject/stimulus/repetition parsed from the path. The
# runtime (src/download/usc_speech_fetch.jl) uses this to pull and (if Deflated) inflate
# a single `.h5` with an HTTP range request instead of downloading the whole archive.
#
# The whole corpus is the single ~570 GB `dataset.zip` (figshare file id 26378810). The
# per-subject `example_for_sub001.zip` (file id 26375235) holds the full sub001 tree and
# is far cheaper to index — useful for producing a small, real, end-to-end-working sample
# map. Pass --file-id to choose; the chosen id is written verbatim into every row so the
# runtime fetches from the same archive.
#
# Usage:
#   julia scripts/generate_usc_speech_map.jl [--file-id 26378810] [--out data/usc_speech_map.csv] [--append]
#
# Notes:
#   * No authentication is needed (public CC-BY); figshare 302-redirects ndownloader to a
#     short-lived pre-signed S3 URL, which this script resolves and re-resolves on expiry.
#   * dataset.zip is >4 GB, so ZIP64 central-directory handling is mandatory.

import Downloads
import CodecZlib

include(joinpath(@__DIR__, "zipdir_common.jl"))

const NDOWNLOADER = "https://ndownloader.figshare.com/files/"
const DEFAULT_FILE_ID = "26378810"   # dataset.zip (full 570 GB corpus)

# ── HTTP-range-backed random access over one figshare archive ───────────────────

mutable struct RangeReader
    file_id::String
    url::String          # current pre-signed S3 URL (re-resolved on expiry)
    total::Int           # archive size in bytes
end

# Resolve a fresh pre-signed S3 URL by following figshare's 302 with a 1-byte ranged
# GET; `resp.url` is the final (pre-signed) URL and `resp` carries the total size via
# the Content-Range header of the 206 response.
function _resolve(file_id::AbstractString)
    url = string(NDOWNLOADER, file_id)
    resp = Downloads.request(url; method = "GET", output = devnull, headers = ["Range" => "bytes=0-0"])
    return resp.url, content_range_total(resp.headers)
end

function RangeReader(file_id::AbstractString)
    url, total = _resolve(file_id)
    total > 0 || error("could not determine size of figshare file $file_id")
    return RangeReader(String(file_id), url, total)
end

# Read `n` bytes at offset `off`, re-resolving the pre-signed URL once on a 403 (expiry).
function read_global(rr::RangeReader, off::Integer, n::Integer)
    headers = ["Range" => "bytes=$(Int(off))-$(Int(off) + Int(n) - 1)"]
    buf = IOBuffer()
    try
        Downloads.download(rr.url, buf; headers = headers)
    catch err
        (err isa Downloads.RequestError && err.response.status == 403) || rethrow(err)
        rr.url, _ = _resolve(rr.file_id)
        buf = IOBuffer()
        Downloads.download(rr.url, buf; headers = headers)
    end
    return take!(buf)
end

# ── Member selection + metadata ─────────────────────────────────────────────────

# Match a 2drt raw spiral k-space member and return its canonical path starting at the
# subject folder (drops any archive-internal prefix), or nothing.
const _RAW_RE = r"(sub\d+/2drt/raw/[^/]+_raw\.h5)$"i
function canonical_2drt_raw(path::AbstractString)
    m = match(_RAW_RE, replace(String(path), '\\' => '/'))
    return m === nothing ? nothing : String(m.captures[1])
end

# Parse "sub001/2drt/raw/sub001_2drt_01_vcv1_r1_raw.h5" → (subject, stimulus, repetition).
function parse_meta(path::AbstractString)
    parts = split(path, '/')
    subject = String(first(parts))
    stem = replace(String(last(parts)), r"_raw\.h5$"i => "")
    stem = replace(stem, Regex("^" * subject * "_2drt_") => "")
    rep = ""
    m = match(r"_r(\d+)$", stem)
    if m !== nothing
        rep = String(m.captures[1])
        stem = stem[1:(m.offset - 1)]
    end
    return subject, stem, rep   # stem is the stimulus (index_name), rep the repetition
end

# ── Main ────────────────────────────────────────────────────────────────────────

function main(args)
    file_id = DEFAULT_FILE_ID
    out = normpath(joinpath(@__DIR__, "..", "data", "usc_speech_map.csv"))
    append = false
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--file-id"
            file_id = args[i + 1]; i += 2
        elseif a == "--out"
            out = args[i + 1]; i += 2
        elseif a == "--append"
            append = true; i += 1
        else
            error("unknown argument $(repr(a))")
        end
    end

    rr = RangeReader(file_id)
    @info "archive" file_id total = rr.total
    entries = parse_central_directory(rr)
    @info "central directory parsed" files = length(entries)

    kept = 0
    open(out, append ? "a" : "w") do io
        append ||
            println(io, "path,start_off,end_off,lfh_size,compressed_size,uncompressed_size,compression,file_id,subject,modality,stimulus,repetition")
        for e in entries
            cpath = canonical_2drt_raw(e.path)
            cpath === nothing && continue
            start_off, end_off, lfh = member_span(rr, e)
            subject, stimulus, rep = parse_meta(cpath)
            println(
                io, join(
                    (
                        cpath, start_off, end_off, lfh, e.compressed_size, e.uncompressed_size,
                        e.compression, file_id, subject, "2drt", stimulus, rep,
                    ), ","
                )
            )
            kept += 1
        end
    end
    @info "wrote map" out kept
    return out
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main(ARGS)
