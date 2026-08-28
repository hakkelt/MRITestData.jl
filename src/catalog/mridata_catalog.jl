# mridata.org catalog. Entries come from the self-updating index (scraped from
# mridata.org/list, cached in the Scratch space) overlaid with the committed
# curated index, which carries richer hand-filled metadata (name, field strength,
# coils, size). See index_cache.jl for the refresh mechanism.

"""Base URL pattern for mridata.org downloads (ISMRMRD `.h5` by UUID)."""
mridata_url(uuid::AbstractString) = "http://mridata.org/download/$(uuid)"

# Committed fallback / curated overlay shipped with the package.
const _BUNDLED_MRIDATA_INDEX = normpath(joinpath(@__DIR__, "..", "..", "data", "mridata_index.toml"))
_bundled_index_path(::MridataOrg) = _BUNDLED_MRIDATA_INDEX

# Parse the symbol-valued fields defensively (TOML stores them as strings).
_sym_or_nothing(d, k) = haskey(d, k) ? Symbol(d[k]) : nothing
_sym(d, k, default) = haskey(d, k) ? Symbol(d[k]) : default

# Fields that map onto named `DatasetEntry` columns; everything else from the
# scraped/curated TOML is preserved under `extra` (matrix_size, model, protocol,
# TE/TR, downloads, institution, …) so callers can filter/inspect on it.
const _MRIDATA_NAMED_FIELDS = Set(
    [
        "id", "name", "anatomy", "vendor", "field_strength",
        "trajectory", "receiver_channels", "fully_sampled", "acquisition_dim",
        "approx_size_bytes", "sha256",
    ]
)

function _mridata_entry(d::AbstractDict)
    uuid = String(d["id"])
    extra = Dict{String, Any}()
    for (k, v) in d
        k in _MRIDATA_NAMED_FIELDS || (extra[String(k)] = v)
    end
    return DatasetEntry(;
        source = MRIDATA,
        id = uuid,
        name = get(d, "name", uuid),
        anatomy = _sym(d, "anatomy", :unknown),
        vendor = _sym_or_nothing(d, "vendor"),
        field_strength = haskey(d, "field_strength") ? Float64(d["field_strength"]) : nothing,
        trajectory = _sym(d, "trajectory", :unknown),
        receiver_channels = haskey(d, "receiver_channels") ? Int(d["receiver_channels"]) : nothing,
        fully_sampled = get(d, "fully_sampled", nothing),
        acquisition_dim = haskey(d, "acquisition_dim") ? Int(d["acquisition_dim"]) : 2,
        approx_size_bytes = haskey(d, "approx_size_bytes") ? Int(d["approx_size_bytes"]) : nothing,
        sha256 = get(d, "sha256", nothing),
        url = mridata_url(uuid),
        extra = extra,
    )
end

_mridata_raw(path) = isfile(path) ? get(TOML.parsefile(path), "dataset", Any[]) : Any[]

# Merge the scraped index at `path` with the curated bundled overlay into catalog entries.
#
# The live scrape covers every UUID and carries rich per-card metadata (vendor, field
# strength, receiver_channels, matrix size/acquisition_dim, trajectory, plus many extras). The curated TOML adds a
# few hand-filled fields the page does not expose — notably `approx_size_bytes`, which the
# network test uses to pick the smallest dataset. Merging happens at the raw-dict level so
# curated keys win per *field* while scraped fields fill the gaps; when `path` is itself the
# bundled file (the scrape failed entirely) the overlay is a no-op. Entries are sorted by id
# so the catalog order does not depend on Dict iteration order.
#
# The memo in `_cached_index_entries` keys on `path` alone, which is correct here: the
# overlay is a committed package file that cannot change while the session runs.
function _mridata_entries(path::AbstractString)
    raw = Dict{String, Dict{String, Any}}()
    for d in _mridata_raw(path)
        raw[String(d["id"])] = Dict{String, Any}(String(k) => v for (k, v) in d)
    end
    for d in _mridata_raw(_BUNDLED_MRIDATA_INDEX)
        id = String(d["id"])
        base = get!(raw, id, Dict{String, Any}())
        for (k, v) in d
            base[String(k)] = v   # curated field wins
        end
    end
    return [_mridata_entry(raw[id]) for id in sort!(collect(keys(raw)))]
end

function _catalog_entries(s::MridataOrg; offline::Bool = false)
    entries = _cached_index_entries(ensure_index(s; offline = offline), _mridata_entries)
    return merge_sizes(entries, s)
end

# mridata accepts any UUID directly, even if not in the curated index.
_can_synthesize(::MridataOrg) = true

function _synthesize_entry(::MridataOrg, uuid::String)
    return DatasetEntry(; source = MRIDATA, id = uuid, name = uuid, url = mridata_url(uuid))
end

# The scraped card carries per-dataset prose keys (matrix size, scanner model, protocol,
# TE/TR, download count, institution, ...) that vary per card, so this is a representative
# set rather than an exhaustive one — `query` only `@warn`s on an unlisted key.
extra_schema(::MridataOrg) = Dict(
    "matrix_size" => "acquisition matrix, as scraped from the mridata.org card",
    "protocol_name" => "Protocol Name (0018,1030), as scraped or curated",
    "institution" => "Institution Name (0008,0080), as scraped",
    "download count" => "provenance: how many times the file has been downloaded from mridata.org",
)
