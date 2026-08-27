#!/usr/bin/env julia
# Maintainer script: build the tar member offset map for fastMRI .tar.xz archives.
#
# USAGE:
#   julia scripts/index_fastmri.jl [--fresh] [--download-dir DIR] archive_key_or_path ...
#
# Each positional argument is one of:
#   a) A local file path to a fastMRI .tar.xz archive  →  indexed in-place
#   b) An archive key (filename, e.g. knee_singlecoil_test_v2.tar.xz) whose
#      signed URL is stored via MRITestData.set_fastmri_urls!  →  downloaded to
#      --download-dir, indexed, then deleted
#   c) A signed S3 URL  →  treated like (b), archive key = URL basename
#
# Archives must be .tar.xz with multiple xz blocks (one per compressed chunk).
# If an archive has only 1 block (monolithic), it is skipped with a warning.
#
# OUTPUT: appends rows to data/fastmri_map.csv (--fresh truncates first).
#
# PREREQUISITES:
#   julia --project=. -e 'using Pkg; Pkg.instantiate()'
#   MRITestData.set_fastmri_urls!(email_text)   # store signed URLs

using Downloads: Downloads
using TOML: TOML

script_dir = @__DIR__
pkg_dir = dirname(script_dir)
include(joinpath(pkg_dir, "src", "util", "xz.jl"))
using .XzIO: XzIO

const MAP_PATH = joinpath(pkg_dir, "data", "fastmri_map.csv")
const CSV_HEADER = "path,archive,tar_data_offset,file_size,anatomy,coils,split,patient_id"

# ── Argument parsing ──────────────────────────────────────────────────────────

function parse_args(raw::Vector{String})
    fresh = false
    download_dir = "/scratch/c_mrrecon/fastmri_dl"
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
        elseif startswith(a, "--")
            error("Unknown option: $a")
        else
            push!(sources, a)
        end
        i += 1
    end
    return fresh, download_dir, sources
end

# ── Signed URL lookup from LocalPreferences.toml ─────────────────────────────

function _read_stored_urls()::Dict{String, String}
    prefs_path = joinpath(pkg_dir, "LocalPreferences.toml")
    isfile(prefs_path) || return Dict{String, String}()
    t = TOML.parsefile(prefs_path)
    raw = get(get(t, "MRITestData", Dict{String, Any}()), "fastmri_urls", Dict{String, Any}())
    return Dict{String, String}(string(k) => string(v) for (k, v) in raw)
end

# Given an argument (URL, local path, or archive key), return:
# (archive_key, url_or_nothing, local_dest_path)
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
    # curl -C - resumes, -L follows redirects, --fail errors on HTTP failures
    run(`curl -C - -L --fail --progress-bar -o $dest $url`)
    return @info "$(basename(dest)) ready ($(round(filesize(dest) / 1.0e9; digits = 2)) GB)"
end

# ── Local range read ──────────────────────────────────────────────────────────

function read_range(path::AbstractString, first_byte::Int, last_byte::Int)::Vector{UInt8}
    return open(path) do f
        seek(f, first_byte)
        read(f, last_byte - first_byte + 1)
    end
end

# ── xz block list ─────────────────────────────────────────────────────────────

struct BlockInfo
    archive_offset::Int    # byte offset of block in the .tar.xz file
    archive_size::Int      # padded compressed size (= range to fetch)
    unpadded_size::Int     # as recorded in xz stream index
    uncompressed_size::Int # bytes produced by decompressing this block
    tar_start::Int         # byte in the concatenated tar stream where this block begins
end

function parse_xz_blocks(path::AbstractString)::Vector{BlockInfo}
    sz = filesize(path)
    footer = read_range(path, sz - 12, sz - 1)
    bwd = XzIO.parse_stream_footer(footer)
    idx_size = (bwd + 1) * 4
    idx_start = sz - 12 - idx_size
    idx = read_range(path, idx_start, idx_start + idx_size - 1)

    idx[1] == 0x00 ||
        error("xz index: expected 0x00 indicator, got 0x$(string(idx[1], base = 16))")
    pos = 2
    nrec, pos = XzIO._varint_decode(idx, pos)
    @info "xz stream: $nrec block(s)"

    blocks = BlockInfo[]
    arch_off = 12      # blocks start after 12-byte stream header
    tar_start = 0
    for _ in 1:nrec
        upsz, pos = XzIO._varint_decode(idx, pos)
        uncsz, pos = XzIO._varint_decode(idx, pos)
        padded = (upsz + 3) ÷ 4 * 4
        push!(blocks, BlockInfo(arch_off, padded, upsz, uncsz, tar_start))
        arch_off += padded
        tar_start += uncsz
    end
    return blocks
end

# ── Tar stream walker ─────────────────────────────────────────────────────────
#
# Walk the xz-compressed tar stream block by block.  For each block:
#   - If the expected next tar header falls entirely within a later block,
#     skip decompressing (optimisation: data-only blocks are not decompressed).
#   - Otherwise, decompress and read the header at the known local byte offset.
#   - From the header, record the member name, absolute tar data offset, and
#     file size; then advance to the next expected header position.
#
# Tar headers that straddle an xz block boundary are not handled (they would
# require carrying bytes across blocks).  In practice this is extremely rare
# because xz --block-size is always a multiple of the 512-byte tar record size.

struct MemberInfo
    path::String
    tar_data_offset::Int  # absolute byte of file data in the concatenated tar stream
    file_size::Int
end

function walk_tar_members(path::AbstractString, blocks::Vector{BlockInfo})::Vector{MemberInfo}
    stream_hdr = read_range(path, 0, 11)
    members = MemberInfo[]
    next_hdr_pos = 0  # expected next tar header position in the tar stream

    for (bi, blk) in enumerate(blocks)
        block_end = blk.tar_start + blk.uncompressed_size

        # Skip blocks that lie entirely before the next expected header.
        next_hdr_pos >= block_end && continue

        @info "Block $bi/$(length(blocks)): decompressing (tar_start=$(blk.tar_start))"
        raw = read_range(path, blk.archive_offset, blk.archive_offset + blk.archive_size - 1)
        d = XzIO.decompress_block(stream_hdr, raw, blk.unpadded_size, blk.uncompressed_size)

        # Walk headers within this block.
        while next_hdr_pos < block_end
            local_pos = next_hdr_pos - blk.tar_start  # 0-indexed within d

            # Guard against header straddling a block boundary (extremely rare).
            local_pos + 512 > blk.uncompressed_size && break

            hdr = @view d[(local_pos + 1):(local_pos + 512)]
            all(==(0x00), hdr) && (@info "End-of-archive marker"; return members)

            name_raw = @view hdr[1:100]
            name = rstrip(String(UInt8[b for b in name_raw if b != 0x00]))
            typeflag = Char(hdr[157])
            sz_raw = @view hdr[125:136]
            sz_str = rstrip(String(UInt8[b for b in sz_raw if b != 0x00]))
            file_sz = isempty(sz_str) ? 0 : parse(Int, sz_str; base = 8)

            # typeflag '0' or '\0' = regular file; '5' = directory; 'L'/'x' = ext header
            if endswith(lowercase(name), ".h5") && (typeflag == '0' || typeflag == '\0')
                tar_data_off = next_hdr_pos + 512
                push!(members, MemberInfo(name, tar_data_off, file_sz))
                @info "  .h5: $name tar_data_offset=$tar_data_off size=$file_sz"
            end

            padded = (file_sz + 511) ÷ 512 * 512
            next_hdr_pos += 512 + padded
        end
    end

    return members
end

# ── Metadata helpers ──────────────────────────────────────────────────────────

function _parse_archive_meta(archive_key::AbstractString)
    base = replace(basename(archive_key), r"\.(tar\.xz|tar\.gz|tgz)$"i => "")
    base = replace(base, r"_v\d+$" => "")
    parts = split(base, "_")
    anatomy = length(parts) >= 1 ? lowercase(parts[1]) : "unknown"
    coiltype = length(parts) >= 2 ? parts[2] : "unknown"
    splitname = length(parts) >= 3 ? parts[3] : "unknown"
    return anatomy, coiltype, splitname
end

function _patient_id(member_path::AbstractString)::String
    base = first(splitext(basename(member_path)))
    m = match(r"^file(\d+)$", base)
    m !== nothing && return m.captures[1]
    return base
end

# ── Per-archive indexing ──────────────────────────────────────────────────────

function index_archive!(
        archive_key::AbstractString, local_path::AbstractString,
        rows::Vector{Vector{Any}}
    )
    @info "Indexing $archive_key"
    anatomy, coiltype, splitname = _parse_archive_meta(archive_key)

    blocks = parse_xz_blocks(local_path)

    if length(blocks) == 1
        @warn """
        $archive_key has only 1 xz block (monolithic compression).  Individual
        member range-extraction requires multiple blocks.  Re-compress with e.g.:
            xz --block-size=256MiB -T0 $archive_key
        Skipping this archive.
        """
        return
    end

    members = walk_tar_members(local_path, blocks)
    @info "Found $(length(members)) .h5 member(s)"

    for m in members
        push!(
            rows, [
                m.path, archive_key, m.tar_data_offset, m.file_size,
                anatomy, coiltype, splitname, _patient_id(m.path),
            ]
        )
    end
    return
end

# ── Main ──────────────────────────────────────────────────────────────────────

function _append_rows(rows::Vector{Vector{Any}})
    isempty(rows) && return
    return open(MAP_PATH, "a") do f
        for r in rows
            println(f, join(string.(r), ","))
        end
    end
end

function main(raw_args::Vector{String})
    fresh, download_dir, sources = parse_args(raw_args)
    isempty(sources) &&
        error("Usage: julia scripts/index_fastmri.jl [--fresh] [--download-dir DIR] archive_key_or_path ...")

    if fresh || !isfile(MAP_PATH)
        open(MAP_PATH, "w") do f
            println(f, CSV_HEADER)
        end
    end

    mkpath(download_dir)
    total = 0
    failed = String[]

    for arg in sources
        archive_key, url, local_path = _resolve(arg, download_dir)
        downloaded = false
        rows = Vector{Any}[]
        try
            if url !== nothing && !isfile(local_path)
                download_archive!(url, local_path)
                downloaded = true
            end
            index_archive!(archive_key, local_path, rows)
            _append_rows(rows)
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
