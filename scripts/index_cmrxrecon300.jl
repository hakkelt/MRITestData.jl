#!/usr/bin/env julia
#
# Maintainer tool — build the CMRxRecon-300 random-access artifacts for one archive
# (TrainingSet / ValidationSet / TestSet).
#
# Each archive is a `.tar.gz` split into raw 16 GiB byte fragments hosted as individual
# Synapse file entities under the CMRxRecon-300 **Dataset** (syn52965326). A `.tar.gz`
# is one continuous DEFLATE stream, so individual members cannot be range-extracted
# directly. This script streams the concatenated gzip **once** and, in a single pass:
#
#   1. parses the tar to record every `.mat` member's uncompressed payload offset + size;
#   2. captures one zran checkpoint (32 KiB dictionary + bit offset) at the block boundary
#      just before each `.mat` member, so the runtime resumes inflation a fraction of a
#      block before the file and streams almost nothing beyond the file itself.
#
# It writes three artifacts to data/ (set = demo|training|validation|test):
#   * cmrxrecon300_<set>_parts.toml  — fragment-name → Synapse entity-ID map + chunk size
#   * cmrxrecon300_<set>_map.csv     — path,set,subject,modality,matfile,data_offset,size
#   * cmrxrecon300_<set>_index.bin.gz — gzip-compressed zran checkpoint index (one per file)
#
# Usage:
#   julia --project=. scripts/index_cmrxrecon300.jl TrainingSet
#   julia --project=. scripts/index_cmrxrecon300.jl ValidationSet
#
# Options:
#   --dataset <synID>  CMRxRecon-300 Dataset entity (default: syn52965326).
#   --chunk-size <n>   Fragment size in bytes (default: 16 GiB).
#   --token <PAT>      Synapse PAT; else $SYNAPSE_AUTH_TOKEN, else stored preference.
#
# Requires outbound HTTPS to repo-prod.prod.sagebase.org. The full pass downloads the
# entire archive (≈120–260 GiB) once; only the small artifacts are kept.

include(joinpath(@__DIR__, "synapse_common.jl"))
include(joinpath(@__DIR__, "..", "src", "util", "zran.jl"))
include(joinpath(@__DIR__, "..", "src", "util", "tario.jl"))
using .Zran
using .TarIO
import CodecZlib
using ProgressMeter

# An IO sink that pushes downloaded compressed bytes straight into the zran scanner,
# so a fragment is streamed (not buffered) through decompression + tar parsing.
mutable struct ScanSink <: IO
    scan::Zran.ScanState
    bar::ProgressMeter.Progress
    seen::Int
    buf::Vector{UInt8}   # reused scratch: `scan_feed!` wants a vector, not a raw pointer
end
ScanSink(scan, bar) = ScanSink(scan, bar, 0, UInt8[])
function Base.unsafe_write(s::ScanSink, p::Ptr{UInt8}, n::UInt)
    len = Int(n)
    length(s.buf) < len && resize!(s.buf, len)
    GC.@preserve s unsafe_copyto!(pointer(s.buf), p, n)
    Zran.scan_feed!(s.scan, len == length(s.buf) ? s.buf : view(s.buf, 1:len))
    s.seen += len
    ProgressMeter.update!(s.bar, s.seen)
    return len
end
Base.write(s::ScanSink, b::UInt8) = (Zran.scan_feed!(s.scan, UInt8[b]); s.seen += 1; 1)

# TrainingSet/P001/cine_lax_ks.mat → (set, subject, modality, matfile)
function _describe(path::AbstractString)
    parts = split(path, '/')
    subject = ""
    for p in parts
        occursin(r"^P\d+$", p) && (subject = String(p))
    end
    fname = String(last(parts))
    base = lowercase(fname)
    modality =
        startswith(base, "cine_lax") ? "Cine LAX" :
        startswith(base, "cine_sax") ? "Cine SAX" :
        startswith(base, "t1map") ? "T1map" :
        startswith(base, "t2map") ? "T2map" : ""
    return subject, modality, fname
end

function main(args)
    dataset = "syn52965326"
    chunk_size = 16 * 1024^3
    token_arg = nothing
    positional = String[]
    i = 1
    while i <= length(args)
        if args[i] == "--dataset" && i < length(args)
            dataset = args[i + 1]; i += 2
        elseif args[i] == "--chunk-size" && i < length(args)
            chunk_size = parse(Int, args[i + 1]); i += 2
        elseif args[i] == "--token" && i < length(args)
            token_arg = args[i + 1]; i += 2
        else
            push!(positional, args[i]); i += 1
        end
    end
    isempty(positional) && error(
        "usage: julia index_cmrxrecon300.jl <DemoData|TrainingSet|ValidationSet|TestSet> " *
            "[--dataset <synID>] [--chunk-size <n>] [--token <PAT>]",
    )
    setname = positional[1]
    setname in ("DemoData", "TrainingSet", "ValidationSet", "TestSet") ||
        error("set must be DemoData, TrainingSet, ValidationSet or TestSet (got $(repr(setname)))")
    # DemoData is a single (unsplit) archive; the rest are split into <Set>.tar.gz-part-NN.
    setlow = setname == "DemoData" ? "demo" : lowercase(replace(setname, "Set" => ""))
    prefix = setname == "DemoData" ? "DemoData.tar.gz" : "$(setname).tar.gz-part-"
    datadir = normpath(joinpath(@__DIR__, "..", "data"))
    parts_out = joinpath(datadir, "cmrxrecon300_$(setlow)_parts.toml")
    map_out = joinpath(datadir, "cmrxrecon300_$(setlow)_map.csv")
    index_out = joinpath(datadir, "cmrxrecon300_$(setlow)_index.bin.gz")

    token = resolve_synapse_token(token_arg)

    frags = list_dataset_items(dataset, token, prefix)
    isempty(frags) && error("no $(prefix)* fragments found under Dataset $dataset")
    @info "found fragments" set = setname count = length(frags)

    # Fragment entity-ID map (consumed by the runtime fetch engine).
    open(parts_out, "w") do io
        println(io, "# Synapse entity IDs for the $(prefix)* fragments.")
        println(io, "# Generated by scripts/index_cmrxrecon300.jl from Dataset $(dataset).")
        println(io)
        println(io, "chunk_size = ", chunk_size)
        println(io)
        println(io, "[parts]")
        for (name, id) in frags
            println(io, "\"", name, "\" = \"", id, "\"")
        end
    end
    @info "wrote parts map" parts_out

    # Total compressed size for the progress bar.
    total = sum(synapse_file_size(id, token) for (_, id) in frags)

    # One checkpoint per `.mat` member, placed at the block boundary just before the
    # member's payload: the runtime then streams only ~one DEFLATE block past the
    # checkpoint to reach the file. `scan_capture!` runs from inside the tar parser (which
    # runs from inside the scanner's `on_output`), so it snapshots the chunk-start boundary.
    scan = Zran.ScanState()
    members = TarIO.TarMember[]
    scanner = TarIO.TarScanner() do m
        if endswith(m.path, ".mat")
            push!(members, m)
            Zran.scan_capture!(scan)
        end
    end
    scan.on_output = (buf, n) -> TarIO.feed!(scanner, buf, n)
    bar = ProgressMeter.Progress(max(total, 1); desc = "Indexing $(setname) ", dt = 0.5)
    sink = ScanSink(scan, bar)

    for (name, id) in frags
        url = synapse_presigned_url(id, token)
        Downloads.download(url, sink)
    end
    checkpoints = Zran.scan_finish!(scan)
    ProgressMeter.finish!(bar)
    @info "scan complete" mat_members = length(members) checkpoints = length(checkpoints)

    # Member map CSV.
    open(map_out, "w") do io
        println(io, "path,set,subject,modality,matfile,data_offset,size")
        for m in members
            subject, modality, fname = _describe(m.path)
            println(io, m.path, ",", setname, ",", subject, ",", modality, ",", fname, ",", m.data_offset, ",", m.size)
        end
    end
    @info "wrote member map" map_out members = length(members)

    # gzip-compressed zran index (checkpoints are per-file, so no fixed interval).
    blob = IOBuffer()
    Zran.write_index(blob, 0, checkpoints)
    open(index_out, "w") do io
        write(io, CodecZlib.transcode(CodecZlib.GzipCompressor, take!(blob)))
    end
    @info "wrote checkpoint index" index_out size_MB = round(filesize(index_out) / 2^20; digits = 2)
    return nothing
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main(ARGS)
