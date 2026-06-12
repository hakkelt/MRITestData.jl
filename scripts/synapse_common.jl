# Shared Synapse REST helpers for the CMRxRecon2024 maintainer scripts
# (list_cmrxrecon2024_parts.jl and download_cmrxrecon2024_fragments.jl).
#
# Both CMRxRecon2024 archives — the training `ChallengeData.zip` and the
# after-competition `ChallengeData_AfterCompetition.zip` — are split into raw ~4 GiB
# fragments hosted as individual Synapse file entities under a parent container. These
# helpers list those fragments, resolve pre-signed S3 URLs, and query file sizes.
#
# Requires outbound HTTPS to repo-prod.prod.sagebase.org.

using Downloads
using TOML

const SYNAPSE_REPO = "https://repo-prod.prod.sagebase.org/repo/v1"

# Resolve a Synapse Personal Access Token from, in order: the explicit value, the
# SYNAPSE_AUTH_TOKEN environment variable, or the `synapse_token` preference in the
# project's gitignored LocalPreferences.toml (written by MRITestData.set_synapse_token!).
# This lets maintainers store the PAT once and never pass it on the command line.
function resolve_synapse_token(explicit::Union{AbstractString, Nothing} = nothing)
    explicit !== nothing && !isempty(explicit) && return String(explicit)
    env = get(ENV, "SYNAPSE_AUTH_TOKEN", "")
    isempty(env) || return env
    lp = normpath(joinpath(@__DIR__, "..", "LocalPreferences.toml"))
    if isfile(lp)
        prefs = TOML.parsefile(lp)
        tok = get(get(prefs, "MRITestData", Dict{String, Any}()), "synapse_token", "")
        isempty(tok) || return String(tok)
    end
    return error(
        "no Synapse token found; pass --token <PAT>, set the SYNAPSE_AUTH_TOKEN " *
            "environment variable, or store one with MRITestData.set_synapse_token!(token)",
    )
end

# POST a JSON body to a Synapse REST endpoint and return the response as a String.
function synapse_post(path::AbstractString, body::AbstractString, token::AbstractString)
    out = IOBuffer()
    Downloads.request(
        SYNAPSE_REPO * path;
        method = "POST",
        input = IOBuffer(body),
        output = out,
        headers = [
            "Authorization" => "Bearer $(token)",
            "Content-Type" => "application/json",
            "Accept" => "application/json",
        ],
    )
    return String(take!(out))
end

# Extract (name, id) pairs from one `/entity/children` page response. Entity headers are
# flat JSON objects, so splitting the "page" array on object boundaries and pulling
# "id"/"name" from each is sufficient (no JSON dependency).
function extract_children(resp::AbstractString)
    pairs = Tuple{String, String}[]
    pstart = findfirst("\"page\":[", resp)
    pstart === nothing && return pairs, nothing
    rest = resp[(last(pstart) + 1):end]
    pend = findfirst(']', rest)
    page = pend === nothing ? rest : rest[1:(pend - 1)]
    for obj in split(page, "},{")
        idm = match(r"\"id\"\s*:\s*\"(syn\d+)\"", obj)
        nm = match(r"\"name\"\s*:\s*\"([^\"]+)\"", obj)
        (idm === nothing || nm === nothing) && continue
        push!(pairs, (String(nm.captures[1]), String(idm.captures[1])))
    end
    tokm = match(r"\"nextPageToken\"\s*:\s*\"([^\"]+)\"", resp)
    next = tokm === nothing ? nothing : String(tokm.captures[1])
    return pairs, next
end

# List the file children of `parent` whose name starts with `prefix`, as a
# name-sorted Vector{Tuple{name, entity_id}}.
function list_fragments(parent::AbstractString, token::AbstractString, prefix::AbstractString)
    frags = Tuple{String, String}[]
    next = nothing
    while true
        tokfield = next === nothing ? "" : ",\"nextPageToken\":\"$(next)\""
        body = "{\"parentId\":\"$(parent)\",\"includeTypes\":[\"file\"],\"sortBy\":\"NAME\"$(tokfield)}"
        resp = synapse_post("/entity/children", body, token)
        pairs, next = extract_children(resp)
        for (name, id) in pairs
            startswith(name, prefix) && push!(frags, (name, id))
        end
        next === nothing && break
    end
    sort!(frags; by = first)
    return frags
end

# Resolve the temporary pre-signed S3 URL for a Synapse file entity. With
# `redirect=false`, Synapse returns the URL as the plain-text body instead of a 307,
# letting us range-request S3 directly without carrying the Synapse auth header.
function synapse_presigned_url(entity_id::AbstractString, token::AbstractString)::String
    url = "$(SYNAPSE_REPO)/entity/$(entity_id)/file?redirect=false"
    io = IOBuffer()
    Downloads.download(url, io; headers = ["Authorization" => "Bearer $(token)"])
    return strip(String(take!(io)))
end

# Report the content size (bytes) of a Synapse file entity, or -1 if unknown.
function synapse_file_size(entity_id::AbstractString, token::AbstractString)::Int
    url = "$(SYNAPSE_REPO)/entity/$(entity_id)"
    io = IOBuffer()
    Downloads.download(
        url, io; headers = [
            "Authorization" => "Bearer $(token)",
            "Accept" => "application/json",
        ]
    )
    body = String(take!(io))
    m = match(r"\"contentSize\"\s*:\s*(\d+)", body)
    return m === nothing ? -1 : parse(Int, m.captures[1])
end
