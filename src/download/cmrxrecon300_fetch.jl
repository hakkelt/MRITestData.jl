# CMRxRecon-300 random-access fetch engine.
#
# Each archive (TrainingSet / ValidationSet / TestSet) is a `.tar.gz` split into raw
# 16 GiB byte fragments hosted as separate Synapse file entities. A `.tar.gz` is one
# continuous DEFLATE stream and cannot be range-extracted per member directly; instead a
# pre-built zran checkpoint index (scripts/index_cmrxrecon300.jl) lets us resume
# inflation mid-stream. To pull one `.mat` we:
#   1. read its uncompressed payload offset + size from the catalog (extra["data_offset"],
#      extra["size"]) and the archive tag (extra["set"]),
#   2. pick the nearest preceding checkpoint (largest unc_off ≤ data_offset),
#   3. map the checkpoint's compressed offset to a fragment + in-fragment offset and
#      issue HTTP Range requests, streaming compressed bytes forward across fragments,
#   4. seed a raw-inflate decoder from the checkpoint (dictionary + bit prime), discard
#      bytes up to data_offset, and collect `size` bytes of payload.
#
# A typical single-file fetch streams ≈ one checkpoint interval of compressed data
# (default 512 MiB) rather than the whole multi-hundred-GiB archive. Access needs a
# Synapse Personal Access Token (see set_synapse_token!) and outbound HTTPS.

# Per-archive configuration: the committed parts/index artifacts.
struct _Archive300
    parts_path::String
    index_path::String
end

const _CMRX300_DATA = normpath(joinpath(@__DIR__, "..", "..", "data"))
_archive300_spec(set) = _Archive300(
    joinpath(_CMRX300_DATA, "cmrxrecon300_$(set)_parts.toml"),
    joinpath(_CMRX300_DATA, "cmrxrecon300_$(set)_index.bin.gz"),
)
const _ARCHIVES300 = Dict{String, _Archive300}(
    set => _archive300_spec(set) for set in ("demo", "training", "validation", "test")
)

# Memoised per-archive (ordered fragment entity IDs, chunk size) and (interval, checkpoints).
const _CMRX300_PARTS = Dict{String, Tuple{Vector{String}, Int}}()
const _CMRX300_INDEX = Dict{String, Tuple{Int, Vector{Zran.Checkpoint}}}()

# Compressed bytes pulled per HTTP Range request while streaming toward a member.
const _CMRX300_BLOCK = 4 * 1024 * 1024

# CMRxRecon-300 ids are the in-archive path with the .mat extension stripped; the cached
# raw file restores it (its slashes become a directory tree under the cache).
_cache_basename(::CMRxRecon300, e::DatasetEntry) = string(e.id, ".mat")

function _archive300(set::AbstractString)
    spec = get(_ARCHIVES300, set, nothing)
    spec === nothing && error("unknown CMRxRecon-300 archive tag $(repr(set))")
    return spec
end

# Trailing integer of a fragment name ("…-part-07" → 7); 0 when there is no suffix
# (single-file archives such as DemoData).
function _frag_index(name::AbstractString)
    m = match(r"(\d+)$", name)
    return m === nothing ? 0 : parse(Int, m.captures[1])
end

function _load_parts300!(set::AbstractString)
    haskey(_CMRX300_PARTS, set) && return _CMRX300_PARTS[set]
    spec = _archive300(set)
    isfile(spec.parts_path) || error(
        "missing Synapse entity-ID map $(spec.parts_path); generate it with " *
            "scripts/index_cmrxrecon300.jl (see scripts/README.md)",
    )
    raw = TOML.parsefile(spec.parts_path)
    pairs = collect(get(raw, "parts", Dict{String, Any}()))
    sort!(pairs; by = p -> _frag_index(first(p)))
    ordered = String[String(last(p)) for p in pairs]
    chunk = Int(get(raw, "chunk_size", 16 * 1024^3))
    _CMRX300_PARTS[set] = (ordered, chunk)
    return ordered, chunk
end

function _load_index300!(set::AbstractString)
    haskey(_CMRX300_INDEX, set) && return _CMRX300_INDEX[set]
    spec = _archive300(set)
    isfile(spec.index_path) || error(
        "missing zran checkpoint index $(spec.index_path); generate it with " *
            "scripts/index_cmrxrecon300.jl (see scripts/README.md)",
    )
    raw = CodecZlib.transcode(CodecZlib.GzipDecompressor, read(spec.index_path))
    interval, cps = Zran.read_index(IOBuffer(raw))
    _CMRX300_INDEX[set] = (interval, cps)
    return interval, cps
end

# Synapse entity ID for fragment index `frag` (0-based) of one archive.
function _cmrx300_entity_id(ordered::Vector{String}, frag::Integer)
    0 <= frag < length(ordered) ||
        error("fragment index $frag out of range (archive has $(length(ordered)) fragments)")
    return ordered[frag + 1]
end

# Largest checkpoint with unc_off ≤ target (checkpoints are sorted by comp_off, which is
# monotonic in unc_off). Falls back to the first checkpoint.
function _nearest_checkpoint(cps::Vector{Zran.Checkpoint}, target::Int)
    lo, hi, ans = 1, length(cps), 1
    while lo <= hi
        mid = (lo + hi) ÷ 2
        if cps[mid].unc_off <= target
            ans = mid; lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return cps[ans]
end

function _fetch_dataset(::CMRxRecon300, e::DatasetEntry, dest::AbstractString; progress::Bool, verify::Bool)
    set = lowercase(get(e.extra, "set", "training"))
    set = set == "trainingset" ? "training" :
        set == "validationset" ? "validation" :
        set == "testset" ? "test" :
        set == "demodata" ? "demo" : set
    spec = _archive300(set)

    token = get_synapse_token()
    isempty(token) && error(
        "no Synapse token set; call MRITestData.set_synapse_token!(token) or set " *
            "ENV[\"SYNAPSE_AUTH_TOKEN\"]. A free Synapse account is required to download " *
            "CMRxRecon-300 (CC-BY; no challenge registration needed).",
    )

    haskey(e.extra, "data_offset") && haskey(e.extra, "size") ||
        error("CMRxRecon-300 entry $(e.id) lacks data_offset/size; regenerate the map")
    data_offset = Int(e.extra["data_offset"]::Integer)
    size = Int(e.extra["size"]::Integer)

    ordered, chunk = _load_parts300!(set)
    _, cps = _load_index300!(set)
    isempty(cps) && error("empty checkpoint index for $(set); regenerate $(spec.index_path)")
    ck = _nearest_checkpoint(cps, data_offset)

    ex = Zran.ExtractState(ck; skip = data_offset - ck.unc_off, nbytes = size)
    bar = progress ? ProgressMeter.Progress(size; desc = "Downloading $(e.name) ", dt = 0.2) : nothing

    # Presigned S3 URLs are per-fragment and valid for a while, so re-presign only when
    # the stream crosses into a new fragment rather than on every range request.
    pos = ck.comp_off
    cur_frag = -1
    url = ""
    while !Zran.extract_done(ex)
        frag = div(pos, chunk)
        within = pos - frag * chunk
        rend = min(within + _CMRX300_BLOCK - 1, chunk - 1)
        if frag != cur_frag
            url = _synapse_presigned_url(_cmrx300_entity_id(ordered, frag), token)
            cur_frag = frag
        end
        bytes = _download_range(url, within, rend)
        isempty(bytes) && error("unexpected end of stream fetching $(e.id) at offset $pos")
        Zran.extract_feed!(ex, bytes)
        pos += length(bytes)
        bar === nothing || ProgressMeter.update!(bar, min(length(ex.out), size))
    end
    bar === nothing || ProgressMeter.finish!(bar)

    length(ex.out) == size ||
        error("extracted $(length(ex.out)) bytes for $(e.id), expected $size")

    mkpath(dirname(dest))
    tmp = dest * ".part"
    try
        write(tmp, ex.out)
    catch err
        isfile(tmp) && rm(tmp; force = true)
        rethrow(err)
    end
    mv(tmp, dest; force = true)
    _write_meta(e, dest, _sha256_hex(dest))
    return dest
end
