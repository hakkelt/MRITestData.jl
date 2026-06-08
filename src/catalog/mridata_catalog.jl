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
        "trajectory", "coils", "fully_sampled", "is3D",
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
        coils = haskey(d, "coils") ? Int(d["coils"]) : nothing,
        fully_sampled = get(d, "fully_sampled", nothing),
        is3D = get(d, "is3D", nothing),
        approx_size_bytes = haskey(d, "approx_size_bytes") ? Int(d["approx_size_bytes"]) : nothing,
        sha256 = get(d, "sha256", nothing),
        url = mridata_url(uuid),
        extra = extra,
    )
end

_mridata_raw(path) = isfile(path) ? get(TOML.parsefile(path), "dataset", Any[]) : Any[]

# The live-scraped index (from ensure_index) covers every UUID and now carries
# rich per-card metadata (vendor, field strength, coils, matrix size/is3D,
# trajectory, plus many extras). The curated bundled TOML adds a few hand-filled
# fields the page does not expose — notably `approx_size_bytes`, which the network
# test uses to pick the smallest dataset. We merge them: curated entries (keyed by
# UUID) take precedence over scraped entries for the same UUID, so a curated
# `approx_size_bytes`/`is3D` overrides the scrape. The bundled TOML is used
# verbatim only when the live scrape fails entirely.
function _catalog_entries(s::MridataOrg; offline::Bool = false)
    path = ensure_index(s; offline = offline)
    # Merge at the raw-dict level so curated keys win per *field* while scraped
    # fields fill the gaps (e.g. curated `approx_size_bytes` over a scrape that has
    # vendor/coils/matrix the curated entry omits).
    raw = Dict{String, Dict{String, Any}}()
    for d in _mridata_raw(path)
        raw[String(d["id"])] = Dict{String, Any}(String(k) => v for (k, v) in d)
    end
    for d in _mridata_raw(_bundled_index_path(s))
        id = String(d["id"])
        base = get(raw, id, Dict{String, Any}())
        for (k, v) in d
            base[String(k)] = v   # curated field wins
        end
        raw[id] = base
    end
    entries = [_mridata_entry(d) for d in values(raw)]
    return merge_sizes(entries, s)
end

# mridata accepts any UUID directly, even if not in the curated index.
function _synthesize_entry(::MridataOrg, uuid::String)
    return DatasetEntry(; source = MRIDATA, id = uuid, name = uuid, url = mridata_url(uuid))
end
