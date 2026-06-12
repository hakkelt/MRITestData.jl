# CMRxRecon2024 range-extraction engine.
#
# The dataset is a single ~835 GB ZIP (`ChallengeData.zip`) split into 210 raw 4 GB
# fragments hosted as separate Synapse file entities. To pull one `.mat` file we:
#   1. look up its byte coordinates in the offset map (catalog/cmrxrecon2024_catalog.jl),
#   2. resolve a pre-signed S3 URL for each fragment it spans (Synapse REST API),
#   3. issue HTTP Range requests against S3 (no Synapse auth on the S3 leg),
#   4. concatenate, strip the ZIP local file header, and inflate the Deflate payload.
#
# Access needs a Synapse Personal Access Token (see set_synapse_token!). Outbound
# HTTPS is required, so this path cannot run on networks where port 443 is blocked.

# Synapse entity-ID map for the 210 fragments + the fragment chunk size, generated
# once by scripts/list_cmrxrecon2024_parts.jl.
const _CMRXRECON_PARTS_PATH = normpath(joinpath(@__DIR__, "..", "..", "data", "cmrxrecon2024_parts.toml"))

# Memoised parts map and chunk size (populated on first download).
const _CMRXRECON_PARTS = Ref{Union{Nothing, Dict{String, String}}}(nothing)
const _CMRXRECON_CHUNK = Ref{Int}(0)

const _SYNAPSE_REPO = "https://repo-prod.prod.sagebase.org/repo/v1"
const _DEFAULT_CHUNK_BYTES = 4 * 1024^3   # 4 GiB; overridden by the parts TOML if present

# CMRxRecon2024 ids are the full in-archive path (already ending in .mat), so the
# cache filename is the id verbatim — joinpath turns its slashes into a directory tree.
_cache_basename(::CMRxRecon2024, e::DatasetEntry) = e.id

function _load_cmrxrecon_parts!()
    p = _CMRXRECON_PARTS[]
    p === nothing || return p
    isfile(_CMRXRECON_PARTS_PATH) ||
        error("missing Synapse entity-ID map $(_CMRXRECON_PARTS_PATH); generate it with scripts/list_cmrxrecon2024_parts.jl")
    raw = TOML.parsefile(_CMRXRECON_PARTS_PATH)
    parts = Dict{String, String}(String(k) => String(v) for (k, v) in get(raw, "parts", Dict{String, Any}()))
    _CMRXRECON_CHUNK[] = Int(get(raw, "chunk_size", _DEFAULT_CHUNK_BYTES))
    _CMRXRECON_PARTS[] = parts
    return parts
end

# Synapse entity ID for fragment index `frag` (0-based), e.g. 0 -> "...-part-000".
function _cmrxrecon_entity_id(parts::Dict{String, String}, frag::Integer)
    name = "ChallengeData.zip-part-" * lpad(frag, 3, '0')
    id = get(parts, name, nothing)
    id === nothing &&
        error("no Synapse entity ID known for fragment $name; regenerate $(_CMRXRECON_PARTS_PATH)")
    return id
end

# Resolve the temporary pre-signed S3 URL for a Synapse file entity. With
# `redirect=false`, Synapse returns the URL as the plain-text response body instead
# of issuing a 307 redirect, which lets us then range-request S3 directly without
# carrying the Synapse Authorization header onto the S3 leg.
function _synapse_presigned_url(entity_id::AbstractString, token::AbstractString)::String
    url = "$(_SYNAPSE_REPO)/entity/$(entity_id)/file?redirect=false"
    io = IOBuffer()
    Downloads.download(url, io; headers = ["Authorization" => "Bearer $(token)"])
    return strip(String(take!(io)))
end

# Fetch the raw bytes (ZIP local header + compressed payload) for a file that spans
# fragments `sf`..`ef`, taking [so..eo] within the single-fragment case or stitching
# the tail of the first fragment, whole middle fragments, and the head of the last.
function _fetch_cmrxrecon_bytes(
        parts::Dict{String, String}, chunk_size::Int, token::AbstractString,
        sf::Int, so::Int, ef::Int, eo::Int,
    )::Vector{UInt8}
    if sf == ef
        url = _synapse_presigned_url(_cmrxrecon_entity_id(parts, sf), token)
        return _download_range(url, so, eo)
    end
    buf = UInt8[]
    for frag in sf:ef
        url = _synapse_presigned_url(_cmrxrecon_entity_id(parts, frag), token)
        rstart = frag == sf ? so : 0
        rend = frag == ef ? eo : chunk_size - 1
        append!(buf, _download_range(url, rstart, rend))
    end
    return buf
end

function _fetch_dataset(::CMRxRecon2024, e::DatasetEntry, dest::AbstractString; progress::Bool, verify::Bool)
    token = get_synapse_token()
    isempty(token) && error(
        "no Synapse token set; call MRITestData.set_synapse_token!(token) or set " *
            "ENV[\"SYNAPSE_AUTH_TOKEN\"]. Note the dataset also requires completing the " *
            "CMRxRecon2024 challenge registration before the token has download permission " *
            "(see the package README).",
    )
    parts = _load_cmrxrecon_parts!()
    chunk_size = _CMRXRECON_CHUNK[]

    ex = e.extra
    sf = Int(ex["start_frag"]::Integer)
    so = Int(ex["start_off"]::Integer)
    ef = Int(ex["end_frag"]::Integer)
    eo = Int(ex["end_off"]::Integer)
    lfh = Int(ex["lfh_size"]::Integer)
    comp = Int(ex["compression"]::Integer)

    progress && @info "Extracting $(e.name) from Synapse archive (fragments $(sf)–$(ef))"
    bytes = _fetch_cmrxrecon_bytes(parts, chunk_size, token, sf, so, ef, eo)

    # Strip the ZIP local file header to isolate the compressed payload.
    length(bytes) > lfh ||
        error("fetched $(length(bytes)) bytes for $(e.id), fewer than the $(lfh)-byte local header")
    payload = bytes[(lfh + 1):end]

    raw = if comp == 8
        CodecZlib.transcode(CodecZlib.DeflateDecompressor, payload)
    elseif comp == 0
        payload
    else
        error("unsupported ZIP compression method $(comp) for $(e.id)")
    end

    mkpath(dirname(dest))
    tmp = dest * ".part"
    try
        write(tmp, raw)
    catch err
        isfile(tmp) && rm(tmp; force = true)
        rethrow(err)
    end
    mv(tmp, dest; force = true)
    _write_meta(e, dest, _sha256_hex(dest))
    return dest
end
