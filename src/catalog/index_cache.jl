# Self-updating dataset index.
#
# Each source's catalog is backed by an *index* file (OCMR: a CSV; mridata: a TOML
# scraped from the website). On first use the index is fetched into the Scratch
# cache; it is refreshed after `INDEX_TTL_DAYS` or on an explicit `refresh_index`.
# On any network failure we fall back to the committed bundled index that ships
# with the package, so discovery always works offline.
#
# Layout under CACHE_DIR[]:
#   <cache>/index/<source>.<ext>            the cached index
#   <cache>/index/<source>.index_meta.toml  sidecar: fetched_at, url, ok

# File extension of a source's index (CSV for OCMR, TOML for mridata).
index_ext(::OCMR) = "csv"
index_ext(::MridataOrg) = "toml"

# Bundled fallback index shipped with the package (defined per source in the
# catalog reader files as `_BUNDLED_INDEX_PATH(source)`).
function _bundled_index_path end

function _index_dir()
    isempty(CACHE_DIR[]) && error("cache directory not initialised; is MRITestData loaded?")
    dir = joinpath(CACHE_DIR[], "index")
    isdir(dir) || mkpath(dir)
    return dir
end

"""
    index_path(source) -> String

Path to the cached index file for `source` (may not exist yet).
"""
index_path(s::AbstractSource) = joinpath(_index_dir(), string(source_name(s), ".", index_ext(s)))

_index_meta_path(s::AbstractSource) = joinpath(_index_dir(), string(source_name(s), ".index_meta.toml"))

function _read_index_meta(s::AbstractSource)
    mp = _index_meta_path(s)
    isfile(mp) || return Dict{String,Any}()
    return TOML.parsefile(mp)
end

function _write_index_meta(s::AbstractSource, url::AbstractString, ok::Bool)
    meta = Dict{String,Any}("fetched_at" => round(Int, time()), "url" => url, "ok" => ok)
    open(_index_meta_path(s), "w") do io
        TOML.print(io, meta)
    end
    return meta
end

"""
    index_age_days(source) -> Union{Float64,Nothing}

Age (in days) of the cached index for `source`, or `nothing` if it has never been
fetched (in which case the bundled fallback is in use).
"""
function index_age_days(s::AbstractSource)
    meta = _read_index_meta(s)
    haskey(meta, "fetched_at") || return nothing
    return (time() - Float64(meta["fetched_at"])) / 86400
end

# Source-specific fetchers write the index to `dest`. Implemented below.
function _fetch_index end

"""
    ensure_index(source; force=false, ttl_days=INDEX_TTL_DAYS[], offline=false) -> String

Return the path to a usable index file for `source`, refreshing it from upstream
when needed:

- a fresh cached index (age < `ttl_days`) is reused as-is;
- otherwise the index is refetched; on success the cache is updated;
- on **any** fetch failure (or when `offline=true`) the most recent usable index
  is returned — a stale cache if present, else the bundled fallback — with a
  `@warn`. This function does not throw on network errors.
"""
function ensure_index(s::AbstractSource; force::Bool = false, ttl_days::Real = INDEX_TTL_DAYS[], offline::Bool = false, progress::Bool = false)
    cached = index_path(s)
    age = index_age_days(s)
    fresh = isfile(cached) && age !== nothing && age < ttl_days

    if offline || (!force && fresh)
        isfile(cached) && return cached
        offline && return _bundled_index_path(s)
    end

    url = _index_source_url(s)
    try
        _fetch_index(s, cached; progress = progress)
        _write_index_meta(s, url, true)
        return cached
    catch err
        if isfile(cached)
            @warn "Failed to refresh $(source_name(s)) index; using stale cached copy" exception = err age_days = age
            return cached
        end
        @warn "Failed to fetch $(source_name(s)) index; using bundled fallback" exception = err
        return _bundled_index_path(s)
    end
end

"""
    refresh_index(source; progress=true)
    refresh_index(; progress=true)

Force-refresh the cached dataset index from upstream — the manual trigger. With no
argument, refreshes every source. Returns the index path(s).
"""
refresh_index(s::AbstractSource; progress::Bool = true) = ensure_index(s; force = true, progress = progress)
refresh_index(; progress::Bool = true) = [refresh_index(s; progress = progress) for s in list_sources()]

# ---- OCMR: authoritative CSV ------------------------------------------------

_index_source_url(::OCMR) = "https://ocmr.s3.amazonaws.com/ocmr_data_attributes.csv"

function _fetch_index(s::OCMR, dest::AbstractString; progress::Bool = false)
    _download_with_progress(_index_source_url(s), dest; progress = progress, desc = "Fetching OCMR index ")
    return dest
end

# ---- mridata.org: scrape the HTML list page ---------------------------------

_index_source_url(::MridataOrg) = "https://mridata.org/list"

# mridata has no JSON API; the /list page renders one card per dataset, with the
# UUID embedded in element ids (e.g. `collapse<uuid>`) and download links
# (`/download/<uuid>`). We fetch pages until no new UUID appears (or a cap), parse
# what metadata we can, and write a TOML in the same shape as the bundled index.
const _UUID_RE = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
const _MRIDATA_PAGE_CAP = 50

function _fetch_index(s::MridataOrg, dest::AbstractString; progress::Bool = false)
    base = _index_source_url(s)
    seen = String[]
    entries = Dict{String,Dict{String,Any}}()
    for page in 1:_MRIDATA_PAGE_CAP
        url = page == 1 ? base : string(base, "?page=", page)
        html = try
            _http_get_string(url)
        catch
            break
        end
        page_uuids = unique(lowercase.([m.match for m in eachmatch(_UUID_RE, html)]))
        new_uuids = filter(u -> !(u in seen), page_uuids)
        isempty(new_uuids) && break
        for u in new_uuids
            push!(seen, u)
            entries[u] = _scrape_mridata_card(html, u)
        end
    end

    isempty(entries) && error("mridata.org list page yielded no datasets")
    _write_mridata_index_toml(dest, entries)
    return dest
end

# Best-effort per-card metadata. The card text near the UUID may mention the
# anatomy and a "fully sampled" flag; we extract conservatively and leave unknowns
# blank so the bundled/default values apply.
function _scrape_mridata_card(html::AbstractString, uuid::AbstractString)
    d = Dict{String,Any}("id" => uuid)
    # window of text around the uuid occurrence
    idx = findfirst(uuid, lowercase(html))
    if idx !== nothing
        lo = max(firstindex(html), first(idx) - 600)
        hi = min(lastindex(html), last(idx) + 600)
        window = lowercase(html[lo:hi])
        for a in ("knee", "brain", "abdomen", "cardiac", "ankle", "prostate", "chest", "phantom")
            if occursin(a, window)
                d["anatomy"] = a
                break
            end
        end
        occursin("fully sampled", window) && (d["fully_sampled"] = true)
        for v in ("siemens", "ge", "philips")
            if occursin(v, window)
                d["vendor"] = v
                break
            end
        end
    end
    return d
end

function _write_mridata_index_toml(dest::AbstractString, entries::AbstractDict)
    tmp = dest * ".part"
    open(tmp, "w") do io
        println(io, "# mridata.org dataset index (auto-generated by refresh_index).")
        for (_, d) in sort(collect(entries); by = first)
            println(io, "\n[[dataset]]")
            println(io, "id = ", repr(d["id"]))
            haskey(d, "anatomy") && println(io, "anatomy = ", repr(d["anatomy"]))
            haskey(d, "vendor") && println(io, "vendor = ", repr(d["vendor"]))
            haskey(d, "fully_sampled") && println(io, "fully_sampled = ", d["fully_sampled"])
        end
    end
    mv(tmp, dest; force = true)
    return dest
end

# Small HTTP GET returning the body as a String (used for scraping). A timeout
# keeps a slow/unreachable host from hanging the refresh; callers fall back.
function _http_get_string(url::AbstractString; timeout::Real = 30)
    io = IOBuffer()
    Downloads.download(url, io; timeout = float(timeout))
    return String(take!(io))
end
