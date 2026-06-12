#!/usr/bin/env julia
#
# Maintainer tool — download every fragment of a CMRxRecon2024 archive from Synapse
# and, optionally, concatenate them into one unified ZIP.
#
# Both archives are handled identically; only the parent container, fragment-name
# prefix, and (optionally) the concatenated filename differ.
#
# Usage (training archive — ~210 × 4 GiB fragments, ~840 GiB):
#   julia --project=. scripts/download_cmrxrecon2024_fragments.jl <PARENT_SYNAPSE_ID> \
#       --out /path/to/output/dir
#
# Usage (after-competition archive — 92 × ~4 GiB fragments, ~380 GiB):
#   julia --project=. scripts/download_cmrxrecon2024_fragments.jl <PARENT_SYNAPSE_ID> \
#       --prefix ChallengeData_AfterCompetition.zip-part- \
#       --out /path/to/output/dir
#
# None of the maintainer scripts require a reassembled archive — generate the offset
# map straight from the fragments. `--cat` is therefore only a convenience for users who
# want the official unified ZIP for other tooling.
#
# Options:
#   --out <dir>          Destination directory (default: current directory).
#   --prefix <str>       Fragment name prefix (default: "ChallengeData.zip-part-").
#   --cat <filename>     After downloading, concatenate all fragments (in order) into
#                        this file inside --out. Skipped by default.
#   --cat-remove         With --cat, delete each fragment right after it is appended, so
#                        peak disk use is ~(unified size + one fragment) instead of 2×.
#   --jobs <n>           Number of fragments to download concurrently (default: 4).
#   --limit <n>          Download only the first n fragments (default: all). Useful for
#                        smoke-testing or staged downloads.
#   --skip-existing      Skip fragments already present with the expected size.
#   --token <PAT>        Synapse Personal Access Token. If omitted, falls back to
#                        $SYNAPSE_AUTH_TOKEN, then the stored synapse_token preference.
#
# <PARENT_SYNAPSE_ID> is the Synapse folder holding the fragment file entities.
# Requires outbound HTTPS to repo-prod.prod.sagebase.org and to S3.

include(joinpath(@__DIR__, "synapse_common.jl"))

# Download one fragment to dest_path (atomic via .part), verifying the byte count.
# Returns :skipped or :downloaded.
function download_fragment(name, entity_id, dest_path, token; skip_existing)
    expected_size = synapse_file_size(entity_id, token)
    if skip_existing && isfile(dest_path) && (expected_size < 0 || filesize(dest_path) == expected_size)
        @info "skip (present)" name
        return :skipped
    end
    url = synapse_presigned_url(entity_id, token)
    tmp = dest_path * ".part"
    Downloads.download(url, tmp)
    actual = filesize(tmp)
    if expected_size > 0 && actual != expected_size
        rm(tmp; force = true)
        error("size mismatch for $name: expected $expected_size bytes, got $actual")
    end
    mv(tmp, dest_path; force = true)
    @info "downloaded" name gib = round(actual / 1024^3; digits = 2)
    return :downloaded
end

# Concatenate fragment files (already in order) into one archive at cat_path. Streams
# with a large buffer; with `remove`, each fragment is deleted right after it is
# appended so peak disk use stays near (unified size + one fragment).
function concatenate_fragments(fragment_paths, cat_path; remove::Bool = false)
    @info "concatenating fragments → $cat_path" count = length(fragment_paths) remove
    expected = sum(filesize, fragment_paths)
    tmp = cat_path * ".part"
    buf = Vector{UInt8}(undef, 16 * 1024 * 1024)
    open(tmp, "w") do out
        for p in fragment_paths
            open(p, "r") do inp
                while true
                    n = readbytes!(inp, buf)
                    n == 0 && break
                    write(out, view(buf, 1:n))
                end
            end
            remove && rm(p; force = true)
        end
    end
    actual = filesize(tmp)
    if actual != expected
        rm(tmp; force = true)
        error("concatenated size $actual ≠ sum of fragments $expected")
    end
    mv(tmp, cat_path; force = true)
    return @info "concatenation complete" path = cat_path gib = round(actual / 1024^3; digits = 2)
end

function main(args)
    prefix = "ChallengeData.zip-part-"
    out_dir = "."
    cat_name = nothing
    cat_remove = false
    jobs = 4
    limit = nothing
    skip_existing = false
    token_arg = nothing
    positional = String[]
    i = 1
    while i <= length(args)
        if args[i] == "--prefix" && i < length(args)
            prefix = args[i + 1]; i += 2
        elseif args[i] == "--out" && i < length(args)
            out_dir = args[i + 1]; i += 2
        elseif args[i] == "--cat" && i < length(args)
            cat_name = args[i + 1]; i += 2
        elseif args[i] == "--cat-remove"
            cat_remove = true; i += 1
        elseif args[i] == "--jobs" && i < length(args)
            jobs = parse(Int, args[i + 1]); i += 2
        elseif args[i] == "--limit" && i < length(args)
            limit = parse(Int, args[i + 1]); i += 2
        elseif args[i] == "--skip-existing"
            skip_existing = true; i += 1
        elseif args[i] == "--token" && i < length(args)
            token_arg = args[i + 1]; i += 2
        else
            push!(positional, args[i]); i += 1
        end
    end
    isempty(positional) && error(
        "usage: julia download_cmrxrecon2024_fragments.jl <PARENT_SYNAPSE_ID> " *
            "[--prefix <str>] [--out <dir>] [--cat <filename>] [--cat-remove] [--jobs <n>] " *
            "[--limit <n>] [--skip-existing] [--token <PAT>]",
    )
    jobs >= 1 || error("--jobs must be >= 1")
    parent = positional[1]
    token = resolve_synapse_token(token_arg)

    mkpath(out_dir)
    @info "listing fragments" parent prefix
    fragments = list_fragments(parent, token, prefix)
    isempty(fragments) && error("no $(prefix)* entities found under $parent")
    if limit !== nothing && limit < length(fragments)
        fragments = fragments[1:limit]
        @info "limiting to first $(limit) fragments"
    end
    cat_name === nothing || limit === nothing ||
        @warn "--cat with --limit produces an incomplete archive"
    @info "found fragments" count = length(fragments) jobs

    dest_paths = [joinpath(out_dir, name) for (name, _) in fragments]

    # Download concurrently. Downloads.download is I/O-bound and yields, so asyncmap
    # with a bounded task count gives real parallelism over the network legs.
    done = Threads.Atomic{Int}(0)
    total = length(fragments)
    asyncmap(enumerate(fragments); ntasks = jobs) do (idx, (name, entity_id))
        download_fragment(name, entity_id, dest_paths[idx], token; skip_existing = skip_existing)
        n = Threads.atomic_add!(done, 1) + 1
        @info "progress" finished = "$n/$total"
        return nothing
    end

    if cat_name !== nothing
        concatenate_fragments(dest_paths, joinpath(out_dir, cat_name); remove = cat_remove)
    end
    return @info "all done" fragments = total
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main(ARGS)
