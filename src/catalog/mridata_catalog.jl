# mridata.org catalog. Entries come from the self-updating index (scraped from
# mridata.org/list, cached in the Scratch space) overlaid with the committed
# curated index, which carries richer hand-filled metadata (name, field strength,
# coils, size). See index_cache.jl for the refresh mechanism.

"""Base URL pattern for mridata.org downloads (ISMRMRD `.h5` by UUID)."""
mridata_url(uuid::AbstractString) = "https://mridata.org/download/$(uuid)"

# Committed fallback / curated overlay shipped with the package.
const _BUNDLED_MRIDATA_INDEX = normpath(joinpath(@__DIR__, "..", "..", "data", "mridata_index.toml"))
_bundled_index_path(::MridataOrg) = _BUNDLED_MRIDATA_INDEX

# Parse the symbol-valued fields defensively (TOML stores them as strings).
_sym_or_nothing(d, k) = haskey(d, k) ? Symbol(d[k]) : nothing
_sym(d, k, default) = haskey(d, k) ? Symbol(d[k]) : default

function _mridata_entry(d::AbstractDict)
    uuid = String(d["id"])
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
    )
end

_mridata_raw(path) = isfile(path) ? get(TOML.parsefile(path), "dataset", Any[]) : Any[]

# When a fresh scrape is available we use it verbatim — the curated TOML is the
# *offline fallback only*, not an overlay. So the curated entries are used exactly
# when `ensure_index` had to fall back to the bundled path.
function _catalog_entries(s::MridataOrg; offline::Bool = false)
    path = ensure_index(s; offline = offline)
    return DatasetEntry[_mridata_entry(d) for d in _mridata_raw(path)]
end

# mridata accepts any UUID directly, even if not in the curated index.
function _synthesize_entry(::MridataOrg, uuid::String)
    return DatasetEntry(; source = MRIDATA, id = uuid, name = uuid, url = mridata_url(uuid))
end
