#!/usr/bin/env julia
#
# Phase 1 maintainer tool — generate data/cmrxrecon2024_map.csv.
#
# Parses the ZIP central directory of the CMRxRecon2024 ChallengeData archive and,
# for every `.mat` file, records which 4 GB fragment(s) hold it and at what byte
# offsets, plus the ZIP local-file-header length and compressed size. The runtime
# (src/download/cmrxrecon2024_fetch.jl) uses this to pull and inflate single files
# with HTTP range requests instead of downloading the full ~835 GB.
#
# Usage:
#   julia scripts/generate_cmrxrecon2024_map.jl <fragments_dir> [out.csv]
#
# <fragments_dir> must contain the raw fragments
#   ChallengeData.zip-part-000 … ChallengeData.zip-part-209
# (the script reads across them; it never needs the reassembled archive). A standard
# fragment's size (CHUNK_SIZE) is taken from part-000.
#
# Withdrawn/abnormal files are dropped (see the blacklist below + Abnormal_TrainValSet.txt
# if it can be located inside the archive).

import CodecZlib

# ── Fragment-backed random access over the split archive ────────────────────────

struct FragmentReader
    paths::Vector{String}      # fragment files in order (000, 001, …)
    sizes::Vector{Int}         # byte size of each fragment
    chunk_size::Int            # size of a standard (non-final) fragment
    total::Int                 # total archive size
end

function FragmentReader(dir::AbstractString)
    paths = String[]
    i = 0
    while true
        p = joinpath(dir, "ChallengeData.zip-part-" * lpad(i, 3, '0'))
        isfile(p) || break
        push!(paths, p)
        i += 1
    end
    isempty(paths) && error("no ChallengeData.zip-part-NNN fragments found in $dir")
    sizes = filesize.(paths)
    return FragmentReader(paths, sizes, sizes[1], sum(sizes))
end

# Read `n` bytes starting at global offset `off`, crossing fragment boundaries.
function read_global(fr::FragmentReader, off::Integer, n::Integer)
    out = Vector{UInt8}(undef, n)
    pos = 0
    remaining = n
    g = Int(off)
    while remaining > 0
        frag = div(g, fr.chunk_size)
        local_off = g % fr.chunk_size
        frag < length(fr.paths) || error("offset $g beyond archive end")
        avail = fr.sizes[frag + 1] - local_off
        take = min(remaining, avail)
        open(fr.paths[frag + 1], "r") do io
            seek(io, local_off)
            readbytes!(io, view(out, (pos + 1):(pos + take)), take)
        end
        pos += take
        remaining -= take
        g += take
    end
    return out
end

_u16(b, i) = Int(b[i]) | (Int(b[i + 1]) << 8)
_u32(b, i) = Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16) | (Int(b[i + 3]) << 24)
_u64(b, i) = _u32(b, i) | (_u32(b, i + 4) << 32)

# ── Locate the central directory (Zip64-aware) ──────────────────────────────────

const EOCD_SIG = 0x06054b50
const Z64_EOCD_LOCATOR_SIG = 0x07064b50
const Z64_EOCD_SIG = 0x06064b50
const CDH_SIG = 0x02014b50

function find_central_directory(fr::FragmentReader)
    # Scan the tail for the End Of Central Directory record.
    tail_len = min(fr.total, (1 << 16) + 256)
    tail = read_global(fr, fr.total - tail_len, tail_len)
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

    # Zip64: when fields are saturated, read the Zip64 EOCD via its locator.
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
        z64 = read_global(fr, z64_off, 56)
        _u32(z64, 1) == Z64_EOCD_SIG || error("bad Zip64 EOCD signature")
        n_entries = _u64(z64, 33)
        cd_size = _u64(z64, 41)
        cd_off = _u64(z64, 49)
    end
    return cd_off, cd_size, n_entries
end

# ── Parse central directory entries ─────────────────────────────────────────────

struct CDEntry
    path::String
    lfh_offset::Int        # global offset of the local file header
    compressed_size::Int
    uncompressed_size::Int
    compression::Int
end

function parse_central_directory(fr::FragmentReader)
    cd_off, cd_size, n_entries = find_central_directory(fr)
    cd = read_global(fr, cd_off, cd_size)
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

        # Zip64 extended information extra field (0x0001) replaces saturated values.
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

        # Skip directory entries (names ending in '/').
        if !endswith(name, "/")
            push!(entries, CDEntry(name, lfh_off, comp_size, uncomp_size, compression))
        end
        p += 46 + fn_len + extra_len + comment_len
    end
    return entries
end

# Read the actual local file header length (30 + fn_len + extra_len) at `lfh_offset`.
function local_header_size(fr::FragmentReader, lfh_offset::Int)
    h = read_global(fr, lfh_offset, 30)
    _u32(h, 1) == 0x04034b50 || error("bad local file header signature at $lfh_offset")
    fn_len = _u16(h, 27)
    extra_len = _u16(h, 29)
    return 30 + fn_len + extra_len
end

# ── Blacklist of withdrawn / abnormal files ─────────────────────────────────────

# Withdrawn fully-sampled files (organizers removed these as abnormal). Filenames use
# underscores in the real archive (cine_sax.mat, aorta_sag.mat, …).
const HARDCODED_BLACKLIST = Set(
    [
        ("Cine", "P100", "cine_sax.mat"), ("Cine", "P109", "cine_sax.mat"),
        ("Aorta", "P065", "aorta_sag.mat"), ("Aorta", "P077", "aorta_sag.mat"),
        ("Aorta", "P105", "aorta_tra.mat"), ("Aorta", "P117", "aorta_tra.mat"),
        ("Tagging", "P087", "tagging.mat"), ("Tagging", "P105", "tagging.mat"),
    ]
)

function is_blacklisted(path::AbstractString, dynamic::AbstractSet)
    path in dynamic && return true
    # The hardcoded withdrawals are fully-sampled ground-truth files only.
    occursin("FullSample", path) || return false
    parts = split(path, '/')
    file = String(last(parts))
    modality = nothing
    subject = nothing
    for p in parts
        p in ("Cine", "Aorta", "Mapping", "Tagging", "Flow2d", "BlackBlood") && (modality = String(p))
        match(r"^P\d+$", p) !== nothing && (subject = String(p))
    end
    return (modality, subject, file) in HARDCODED_BLACKLIST
end

# Strip any leading directory components up to and including "ChallengeData/" so the
# recorded path matches the official challenge tree (MultiCoil/<modality>/…).
function canonical_path(p::AbstractString)
    m = findlast("ChallengeData/", p)
    return m === nothing ? String(p) : String(p[(last(m) + 1):end])
end

# Load the abnormal-file list, canonicalized to challenge-tree paths. Looks inside the
# archive (if an Abnormal_TrainValSet.txt entry exists) and, optionally, from an
# external file passed on the command line (the list is not always shipped in-archive).
function load_abnormal_set(fr::FragmentReader, entries::Vector{CDEntry}, external::Union{Nothing, String})
    out = Set{String}()
    idx = findfirst(e -> endswith(e.path, "Abnormal_TrainValSet.txt"), entries)
    if idx !== nothing
        for l in split(entry_text(fr, entries[idx]), '\n')
            isempty(strip(l)) || push!(out, canonical_path(strip(l)))
        end
    end
    if external !== nothing
        for l in eachline(external)
            isempty(strip(l)) || push!(out, canonical_path(strip(l)))
        end
    end
    return out
end

# Read one entry's raw bytes and return them as a String, decompressing if needed.
function entry_text(fr::FragmentReader, e::CDEntry)
    lfh = local_header_size(fr, e.lfh_offset)
    raw = read_global(fr, e.lfh_offset + lfh, e.compressed_size)
    e.compression == 0 && return String(raw)
    return String(CodecZlib.transcode(CodecZlib.DeflateDecompressor, raw))
end

# Extract all _info.csv entries from the archive into `tmpdir`, preserving the canonical
# challenge-tree relative path. Returns the number of files written.
function extract_info_csvs(fr::FragmentReader, entries::Vector{CDEntry}, tmpdir::AbstractString)
    n = 0
    for e in entries
        endswith(e.path, "_info.csv") || continue
        dest = joinpath(tmpdir, canonical_path(e.path))
        mkpath(dirname(dest))
        write(dest, entry_text(fr, e))
        n += 1
    end
    return n
end

# ── Main ────────────────────────────────────────────────────────────────────────

function main(args)
    length(args) >= 1 || error("usage: julia generate_cmrxrecon2024_map.jl <fragments_dir> [out.csv] [abnormal_list.txt]")
    dir = args[1]
    out = length(args) >= 2 ? args[2] :
        normpath(joinpath(@__DIR__, "..", "data", "cmrxrecon2024_map.csv"))
    external_abnormal = length(args) >= 3 ? args[3] : nothing

    fr = FragmentReader(dir)
    @info "archive" fragments = length(fr.paths) chunk_size = fr.chunk_size total = fr.total

    entries = parse_central_directory(fr)
    @info "central directory parsed" files = length(entries)

    abnormal = load_abnormal_set(fr, entries, external_abnormal)
    @info "abnormal list" count = length(abnormal)

    kept = 0
    n_mat = 0
    open(out, "w") do io
        println(io, "path,start_frag,start_off,end_frag,end_off,lfh_size,compressed_size,uncompressed_size,compression")
        for e in entries
            endswith(e.path, ".mat") || continue
            n_mat += 1
            path = canonical_path(e.path)
            is_blacklisted(path, abnormal) && continue

            lfh = local_header_size(fr, e.lfh_offset)
            data_end = e.lfh_offset + lfh + e.compressed_size      # exclusive
            start_frag = div(e.lfh_offset, fr.chunk_size)
            start_off = e.lfh_offset % fr.chunk_size
            end_frag = div(data_end - 1, fr.chunk_size)
            end_off = (data_end - 1) % fr.chunk_size

            println(
                io, join(
                    (
                        path, start_frag, start_off, end_frag, end_off,
                        lfh, e.compressed_size, e.uncompressed_size, e.compression,
                    ), ","
                )
            )
            kept += 1
        end
    end
    @info "wrote map" out kept dropped = (n_mat - kept)
    return out
end

# Run annotation phase inline so the committed CSV always carries the full metadata.
# The standalone annotate_cmrxrecon2024_map.jl script can re-annotate an existing
# raw CSV without re-parsing the archive. We load it into an isolated module to avoid
# const-redefinition errors if this function is ever called more than once.
function main_with_annotation(args)
    # Parse fragments dir — first positional argument.
    fragments_dir = args[1]

    csvpath = main(args)

    # Extract acquisition-parameter info CSVs directly from the archive into a temp
    # directory so the annotation phase does not require a pre-extracted copy.
    fr = FragmentReader(fragments_dir)
    entries = parse_central_directory(fr)
    tmpdir = mktempdir()
    try
        n = extract_info_csvs(fr, entries, tmpdir)
        @info "extracted info CSVs from archive" count = n
        ann = Module(:CMRxReconAnnotate)
        Base.include(ann, joinpath(@__DIR__, "annotate_cmrxrecon2024_map.jl"))
        # Wrap in a closure so the ann.annotate access occurs inside the latest world,
        # avoiding the Julia 1.12 world-age binding warning.
        let _csvpath = csvpath, _tmpdir = tmpdir
            Base.invokelatest(() -> ann.annotate(_csvpath, _csvpath; info_dir = _tmpdir))
        end
    finally
        rm(tmpdir; recursive = true, force = true)
    end
    return csvpath
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main_with_annotation(ARGS)
