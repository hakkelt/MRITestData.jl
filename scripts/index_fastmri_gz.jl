#!/usr/bin/env julia
# Maintainer script: build the tar member offset map and zran checkpoint index for
# fastMRI .tar.gz archives (prostate and breast k-space).
#
# Unlike the xz-based archives (knee, brain), .tar.gz is a single continuous DEFLATE
# stream that does not support random access directly. This script does a one-time
# streaming pass over each archive to:
#   1. Parse the tar stream and record every .h5 member's uncompressed payload offset
#      and size (appended to data/fastmri_map.csv, same schema as the xz entries).
#   2. Capture one zran checkpoint (32 KiB dictionary + bit offset) at the DEFLATE block
#      boundary just before each .h5 member's payload. This lets the runtime resume
#      decompression just before the file and stream to the end.
#   3. Write a per-archive checkpoint index to data/fastmri_zran/<archive_stem>.bin.gz.
#
# USAGE:
#   julia --project=. scripts/index_fastmri_gz.jl [--fresh] [--download-dir DIR] archive_key ...
#
# Each positional argument is a .tar.gz archive key (filename, e.g.
# fastMRI_prostate_DIFF_IDS_001_011.tar.gz) whose signed URL is stored via
# MRITestData.set_fastmri_urls!. The archive is downloaded, indexed, then deleted.
#
# OUTPUT:
#   - Appends rows to data/fastmri_map.csv
#   - Writes data/fastmri_zran/<archive_stem>.bin.gz per archive
#
# PREREQUISITES:
#   julia --project=. -e 'using Pkg; Pkg.instantiate()'
#   MRITestData.set_fastmri_urls!(email_text)   # store signed URLs

import CodecZlib

include(joinpath(@__DIR__, "fastmri_common.jl"))
include(joinpath(_PKG_DIR, "src", "util", "zran.jl"))
include(joinpath(_PKG_DIR, "src", "util", "tario.jl"))
using .Zran: Zran
using .TarIO: TarIO

const ZRAN_DIR = joinpath(_PKG_DIR, "data", "fastmri_zran")

# ── Archive metadata ──────────────────────────────────────────────────────────

# Parse anatomy, coil/sequence-type, and split from a fastMRI .tar.gz archive key.
# Handled patterns:
#   fastMRI_prostate_DIFF_IDS_<range> → ("prostate", "DIFF",      "train")
#   fastMRI_prostate_T2_IDS_<range>   → ("prostate", "T2",        "train")
#   fastMRI_breast_IDS_<range>        → ("breast",   "multicoil", "train")
#   anything else                     → best-effort fallback
function _parse_gz_archive_meta(archive_key::AbstractString)
    base = replace(basename(archive_key), r"\.(tar\.gz|tgz)$"i => "")
    # fastMRI_<anatomy>_<sequence>_IDS_...
    m = match(r"^fastMRI_([a-zA-Z]+)_([A-Z0-9]+)_IDS_"i, base)
    if m !== nothing
        anatomy = lowercase(m.captures[1])
        seq = uppercase(m.captures[2])
        # Breast has an IDS prefix without a sequence type; this branch won't match it
        # because breast keys are fastMRI_breast_IDS_... (only two words before IDS).
        return anatomy, seq, "train"
    end
    # fastMRI_<anatomy>_IDS_...
    m = match(r"^fastMRI_([a-zA-Z]+)_IDS_"i, base)
    if m !== nothing
        anatomy = lowercase(m.captures[1])
        return anatomy, "multicoil", "train"
    end
    # fallback
    parts = split(base, "_")
    return get(parts, 2, "unknown"), get(parts, 3, "unknown"), "unknown"
end

# ── Per-archive indexing ──────────────────────────────────────────────────────

function index_archive_gz!(
        archive_key::AbstractString, local_path::AbstractString,
        rows::Vector{Vector{Any}}
    )
    @info "Indexing $archive_key (streaming pass)"
    anatomy, coiltype, splitname = _parse_gz_archive_meta(archive_key)

    members = TarIO.TarMember[]
    scan = Zran.ScanState()
    scanner = TarIO.TarScanner() do m
        if endswith(m.path, ".h5")
            push!(members, m)
            Zran.scan_capture!(scan)
            @info "  .h5: $(m.path)  data_offset=$(m.data_offset)  size=$(m.size)"
        end
    end
    scan.on_output = (buf, n) -> TarIO.feed!(scanner, buf, n)

    total_bytes = filesize(local_path)
    seen = 0

    # Stream the file through the scanner one 1 MiB chunk at a time.
    open(local_path, "r") do f
        buf = Vector{UInt8}(undef, 1 << 20)
        while !eof(f)
            n = readbytes!(f, buf)
            Zran.scan_feed!(scan, n == length(buf) ? buf : view(buf, 1:n))
            seen += n
            if total_bytes > 0
                pct = round(seen / total_bytes * 100; digits = 1)
                print("\r  scan: $pct%  ($(round(seen / 1.0e9; digits = 2)) / $(round(total_bytes / 1.0e9; digits = 2)) GB)")
            end
        end
    end
    println()   # newline after progress

    checkpoints = Zran.scan_finish!(scan)
    @info "Scan complete" h5_members = length(members) checkpoints = length(checkpoints)

    length(members) == length(checkpoints) ||
        @warn "Checkpoint / member count mismatch ($(length(checkpoints)) checkpoints, $(length(members)) members)"

    # Append member rows.
    for m in members
        push!(
            rows, [
                m.path, archive_key, m.data_offset, m.size,
                anatomy, coiltype, splitname, _patient_id(m.path),
            ]
        )
    end

    # Write per-archive zran index.
    mkpath(ZRAN_DIR)
    stem = replace(basename(archive_key), r"\.(tar\.gz|tgz)$"i => "")
    index_path = joinpath(ZRAN_DIR, stem * ".bin.gz")
    blob = IOBuffer()
    Zran.write_index(blob, 0, checkpoints)
    open(index_path, "w") do io
        write(io, CodecZlib.transcode(CodecZlib.GzipCompressor, take!(blob)))
    end
    @info "Wrote checkpoint index" index_path size_KB = round(filesize(index_path) / 1024; digits = 1)
    return
end

# ── Main ──────────────────────────────────────────────────────────────────────

run_indexer(
    ARGS;
    usage = "Usage: julia scripts/index_fastmri_gz.jl [--fresh] [--download-dir DIR] [--output PATH] archive_key ...",
    index_one! = index_archive_gz!,
    accept = k -> endswith(lowercase(k), ".tar.gz") ||
        (@warn "$k is not a .tar.gz — use scripts/index_fastmri.jl for .tar.xz"; false),
)
