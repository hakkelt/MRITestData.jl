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

using Downloads: Downloads
using TOML: TOML
import CodecZlib

script_dir = @__DIR__
pkg_dir = dirname(script_dir)
include(joinpath(pkg_dir, "src", "util", "zran.jl"))
include(joinpath(pkg_dir, "src", "util", "tario.jl"))
using .Zran: Zran
using .TarIO: TarIO

const MAP_PATH = joinpath(pkg_dir, "data", "fastmri_map.csv")
const ZRAN_DIR = joinpath(pkg_dir, "data", "fastmri_zran")
const CSV_HEADER = "path,archive,tar_data_offset,file_size,anatomy,coils,split,patient_id"

# ── Argument parsing ──────────────────────────────────────────────────────────

function parse_args(raw::Vector{String})
    fresh = false
    download_dir = "/scratch/c_mrrecon/fastmri_dl"
    output_path = MAP_PATH   # default: append directly to data/fastmri_map.csv
    sources = String[]
    i = 1
    while i <= length(raw)
        a = raw[i]
        if a == "--fresh"
            fresh = true
        elseif a == "--download-dir"
            i += 1
            i <= length(raw) || error("--download-dir requires an argument")
            download_dir = raw[i]
        elseif a == "--output"
            i += 1
            i <= length(raw) || error("--output requires an argument")
            output_path = raw[i]
        elseif startswith(a, "--")
            error("Unknown option: $a")
        else
            push!(sources, a)
        end
        i += 1
    end
    return fresh, download_dir, output_path, sources
end

# ── Signed URL lookup from LocalPreferences.toml ─────────────────────────────

function _read_stored_urls()::Dict{String, String}
    prefs_path = joinpath(pkg_dir, "LocalPreferences.toml")
    isfile(prefs_path) || return Dict{String, String}()
    t = TOML.parsefile(prefs_path)
    raw = get(get(t, "MRITestData", Dict{String, Any}()), "fastmri_urls", Dict{String, Any}())
    return Dict{String, String}(string(k) => string(v) for (k, v) in raw)
end

function _resolve(arg::AbstractString, download_dir::AbstractString)
    if startswith(arg, "http://") || startswith(arg, "https://")
        key = basename(split(arg, "?")[1])
        return key, arg, joinpath(download_dir, key)
    elseif isfile(arg)
        return basename(arg), nothing, arg
    else
        key = basename(arg)
        urls = _read_stored_urls()
        haskey(urls, key) ||
            error("No stored URL for $(repr(key)). Call MRITestData.set_fastmri_urls! first.")
        return key, urls[key], joinpath(download_dir, key)
    end
end

# ── Resumable download via system curl ───────────────────────────────────────

function download_archive!(url::AbstractString, dest::AbstractString)
    mkpath(dirname(dest))
    isfile(dest) && @info "$(basename(dest)): resuming partial download"
    @info "Downloading $(basename(dest))…"
    run(`curl -C - -L --fail --progress-bar -o $dest $url`)
    return @info "$(basename(dest)) ready ($(round(filesize(dest) / 1.0e9; digits = 2)) GB)"
end

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

# Derive patient_id from an archive member path. Common fastMRI patterns:
#   knee_singlecoil_train/file1000000.h5 → "1000000"
#   <dir>/file0001.h5                    → "0001"
#   <dir>/<patient_dir>/<file>.h5        → inner directory name or filename number
function _patient_id(member_path::AbstractString)::String
    base = first(splitext(basename(member_path)))
    m = match(r"^file(\d+)$", base)
    m !== nothing && return m.captures[1]
    m = match(r"(\d+)$", base)
    m !== nothing && return m.captures[1]
    return base
end

# ── Streaming sink for the download → scan pipeline ──────────────────────────

mutable struct ScanSink <: IO
    scan::Zran.ScanState
    seen::Int
    total::Int
end

function Base.unsafe_write(s::ScanSink, p::Ptr{UInt8}, n::UInt)
    buf = Vector{UInt8}(undef, Int(n))
    GC.@preserve buf unsafe_copyto!(pointer(buf), p, n)
    Zran.scan_feed!(s.scan, buf)
    s.seen += Int(n)
    if s.total > 0
        pct = round(s.seen / s.total * 100; digits = 1)
        print("\r  scan: $pct%  ($(round(s.seen / 1.0e9; digits = 2)) / $(round(s.total / 1.0e9; digits = 2)) GB)")
    end
    return Int(n)
end
Base.write(s::ScanSink, b::UInt8) = (Zran.scan_feed!(s.scan, UInt8[b]); s.seen += 1; 1)

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
    sink = ScanSink(scan, 0, total_bytes)

    # Stream the file through the scanner.
    open(local_path, "r") do f
        buf = Vector{UInt8}(undef, 1 << 20)   # 1 MiB read chunks
        while !eof(f)
            n = readbytes!(f, buf)
            Base.unsafe_write(sink, pointer(buf), UInt(n))
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

function _append_rows(rows::Vector{Vector{Any}}, output_path::AbstractString)
    isempty(rows) && return
    return open(output_path, "a") do f
        for r in rows
            println(f, join(string.(r), ","))
        end
    end
end

function main(raw_args::Vector{String})
    fresh, download_dir, output_path, sources = parse_args(raw_args)
    isempty(sources) &&
        error("Usage: julia scripts/index_fastmri_gz.jl [--fresh] [--download-dir DIR] [--output PATH] archive_key ...")

    if fresh || !isfile(output_path)
        open(output_path, "w") do f
            println(f, CSV_HEADER)
        end
    end

    mkpath(download_dir)
    total = 0
    failed = String[]

    for arg in sources
        archive_key, url, local_path = _resolve(arg, download_dir)
        endswith(lowercase(archive_key), ".tar.gz") ||
            (@warn "$archive_key is not a .tar.gz — use scripts/index_fastmri.jl for .tar.xz"; continue)
        downloaded = false
        rows = Vector{Any}[]
        try
            if url !== nothing && !isfile(local_path)
                download_archive!(url, local_path)
                downloaded = true
            end
            index_archive_gz!(archive_key, local_path, rows)
            _append_rows(rows, output_path)
            total += length(rows)
            @info "$(archive_key): wrote $(length(rows)) rows (running total: $total)"
        catch err
            @error "$(archive_key) FAILED — skipping" exception = err
            push!(failed, archive_key)
        finally
            if downloaded && isfile(local_path)
                @info "Deleting $(basename(local_path))"
                rm(local_path)
            end
        end
    end

    @info "Done. Total rows written: $total"
    isempty(failed) || @warn "Failed archives (re-run manually): $(join(failed, ", "))"
    return
end

main(ARGS)
