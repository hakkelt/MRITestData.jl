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

include(joinpath(@__DIR__, "fastmri_common.jl"))
include(joinpath(_PKG_DIR, "src", "util", "xz.jl"))
include(joinpath(_PKG_DIR, "src", "util", "tario.jl"))
using .XzIO: XzIO
using .TarIO: TarIO

# ── Local range read ──────────────────────────────────────────────────────────

function read_range(path::AbstractString, first_byte::Int, last_byte::Int)::Vector{UInt8}
    return open(path) do f
        seek(f, first_byte)
        read(f, last_byte - first_byte + 1)
    end
end

# ── xz block list ─────────────────────────────────────────────────────────────

# Read the xz stream index of a local archive. Same walk the runtime does over HTTP range
# requests (src/download/fastmri_fetch.jl), so both agree on block boundaries.
function parse_xz_blocks(path::AbstractString)::Vector{XzIO.BlockRecord}
    sz = filesize(path)
    idx_first, idx_last = XzIO.index_range(sz, read_range(path, sz - 12, sz - 1))
    blocks = XzIO.parse_index(read_range(path, idx_first, idx_last))
    @info "xz stream: $(length(blocks)) block(s)"
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

function walk_tar_members(path::AbstractString, blocks::Vector{XzIO.BlockRecord})::Vector{MemberInfo}
    stream_hdr = read_range(path, 0, 11)
    members = MemberInfo[]
    next_hdr_pos = 0  # expected next tar header position in the tar stream

    for (bi, blk) in enumerate(blocks)
        block_end = blk.stream_offset + blk.uncompressed_size

        # Skip blocks that lie entirely before the next expected header.
        next_hdr_pos >= block_end && continue

        @info "Block $bi/$(length(blocks)): decompressing (tar_start=$(blk.stream_offset))"
        raw = read_range(path, blk.archive_offset, blk.archive_offset + blk.archive_size - 1)
        d = XzIO.decompress_block(stream_hdr, raw, blk.unpadded_size, blk.uncompressed_size)

        # Walk headers within this block.
        while next_hdr_pos < block_end
            local_pos = next_hdr_pos - blk.stream_offset  # 0-indexed within d

            # Guard against header straddling a block boundary (extremely rare).
            local_pos + TarIO.BLOCK > blk.uncompressed_size && break

            hdr = TarIO._parse_header(@view d[(local_pos + 1):(local_pos + TarIO.BLOCK)])
            hdr === nothing && (@info "End-of-archive marker"; return members)
            name, file_sz, typeflag = hdr

            # typeflag '0' or '\0' = regular file; '5' = directory; 'L'/'x' = ext header
            if endswith(lowercase(name), ".h5") && (typeflag == '0' || typeflag == '\0')
                tar_data_off = next_hdr_pos + TarIO.BLOCK
                push!(members, MemberInfo(name, tar_data_off, file_sz))
                @info "  .h5: $name tar_data_offset=$tar_data_off size=$file_sz"
            end

            next_hdr_pos += TarIO.BLOCK + TarIO._pad(file_sz)
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

run_indexer(
    ARGS;
    usage = "Usage: julia scripts/index_fastmri.jl [--fresh] [--download-dir DIR] [--output PATH] archive_key_or_path ...",
    index_one! = index_archive!,
)
