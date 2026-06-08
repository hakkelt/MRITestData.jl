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

"""
    sizes_path(source) -> String

Path to the persisted dataset sizes sidecar for `source`. Stores a mapping from
dataset id to `approx_size_bytes` so sizes fetched via HTTP HEAD are not lost
across sessions. Lives alongside the cached index in the index directory.
"""
sizes_path(s::AbstractSource) = joinpath(_index_dir(), string(source_name(s), ".sizes.toml"))

"""
    read_sizes(source) -> Dict{String,Int}

Return the persisted id → size mapping for `source`, or an empty dict if none exists.
"""
function read_sizes(s::AbstractSource)
    p = sizes_path(s)
    isfile(p) || return Dict{String, Int}()
    raw = TOML.parsefile(p)
    return Dict{String, Int}(k => Int(v) for (k, v) in get(raw, "sizes", Dict()))
end

"""
    write_sizes(source, sizes::Dict{String,Int})

Persist `sizes` (id → approx_size_bytes) for `source`, merging with any previously
stored values. Existing entries are never removed — sizes are expected to be stable.
"""
function write_sizes(s::AbstractSource, sizes::AbstractDict{<:AbstractString, <:Integer})
    p = sizes_path(s)
    existing = read_sizes(s)
    merged = merge(existing, Dict{String, Int}(k => Int(v) for (k, v) in sizes))
    tmp = p * ".part"
    open(tmp, "w") do io
        TOML.print(io, Dict("sizes" => merged))
    end
    mv(tmp, p; force = true)
    return p
end

"""
    merge_sizes(entries, source) -> Vector{DatasetEntry}

Return `entries` with `approx_size_bytes` filled in from the persisted sizes sidecar
for `source`. Entries that already have a size are left unchanged.
"""
function merge_sizes(entries::AbstractVector{DatasetEntry}, s::AbstractSource)
    sizes = read_sizes(s)
    isempty(sizes) && return entries
    return map(entries) do e
        e.approx_size_bytes !== nothing && return e
        sz = get(sizes, e.id, nothing)
        sz === nothing && return e
        return DatasetEntry(;
            source = e.source,
            id = e.id,
            name = e.name,
            anatomy = e.anatomy,
            vendor = e.vendor,
            field_strength = e.field_strength,
            trajectory = e.trajectory,
            coils = e.coils,
            fully_sampled = e.fully_sampled,
            is3D = e.is3D,
            approx_size_bytes = sz,
            sha256 = e.sha256,
            url = e.url,
            extra = e.extra,
        )
    end
end

function _read_index_meta(s::AbstractSource)
    mp = _index_meta_path(s)
    isfile(mp) || return Dict{String, Any}()
    return TOML.parsefile(mp)
end

function _write_index_meta(s::AbstractSource, url::AbstractString, ok::Bool)
    meta = Dict{String, Any}("fetched_at" => round(Int, time()), "url" => url, "ok" => ok)
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
function ensure_index(s::AbstractSource; force::Bool = false, ttl_days::Real = INDEX_TTL_DAYS[], offline::Bool = false, progress::Bool = false, fetch_sizes::Bool = false)
    cached = index_path(s)
    age = index_age_days(s)
    fresh = isfile(cached) && age !== nothing && age < ttl_days

    if offline || (!force && fresh)
        isfile(cached) && return cached
        offline && return _bundled_index_path(s)
    end

    url = _index_source_url(s)
    try
        @info "Fetching $(source_name(s)) index from $url"
        _fetch_index(s, cached; progress = progress, fetch_sizes = fetch_sizes)
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
    refresh_index(source; progress=true, fetch_sizes=false)
    refresh_index(; progress=true, fetch_sizes=false)

Force-refresh the cached dataset index from upstream — the manual trigger. With no
argument, refreshes every source in parallel. Returns the index path(s).

When `fetch_sizes=true`, an HTTP HEAD request is issued for each entry whose size is
not already known, and the result is stored as `approx_size_bytes` in the index. This
costs one extra round-trip per entry but enables the `max_bytes` guard in
`download_dataset` for sources (like mridata.org) that do not publish sizes in their
catalog. The option has no effect for sources that already carry size information.
"""
function refresh_index(s::AbstractSource; progress::Bool = true, fetch_sizes::Bool = false)
    return ensure_index(s; force = true, progress = progress, fetch_sizes = fetch_sizes)
end
function refresh_index(; progress::Bool = true, fetch_sizes::Bool = false)
    results = Vector{String}(undef, length(list_sources()))
    @sync for (i, s) in enumerate(list_sources())
        @async results[i] = refresh_index(s; progress = progress, fetch_sizes = fetch_sizes)
    end
    return results
end

# ---- OCMR: authoritative CSV ------------------------------------------------

_index_source_url(::OCMR) = "https://ocmr.s3.amazonaws.com/ocmr_data_attributes.csv"

function _fetch_index(s::OCMR, dest::AbstractString; progress::Bool = false, fetch_sizes::Bool = false)
    _download_with_progress(_index_source_url(s), dest; progress = progress, desc = "Fetching OCMR index ")
    return dest
end

# ---- mridata.org: scrape the HTML list page ---------------------------------

_index_source_url(::MridataOrg) = "http://mridata.org/list"

# mridata has no JSON API, but the /list page renders one *fully-populated* card
# per dataset: a `<div class="card my-2">` block holding a summary table
# (Project / Anatomy / Fullysampled / Uploader) and a collapsible detail table of
# `<th>Field</th><td>value</td>` pairs (System Vendor, Number of Channels, Matrix
# Size, Trajectory, TE/TR, …). We split the page into card blocks, parse every
# field we can, and write a TOML in the same shape as the bundled index — so a
# successful scrape carries the same rich metadata a human would read off the page,
# with no per-dataset request and no dataset download. We page until no new UUID
# appears (or a cap).
const _UUID_RE = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
const _MRIDATA_PAGE_CAP = 50

function _fetch_index(s::MridataOrg, dest::AbstractString; progress::Bool = false, fetch_sizes::Bool = false)
    base = _index_source_url(s)
    entries = Dict{String, Dict{String, Any}}()
    for page in 1:_MRIDATA_PAGE_CAP
        url = page == 1 ? base : string(base, "?page=", page)
        html = try
            _http_get_string(url)
        catch
            break
        end
        new_on_page = 0
        for card in _split_mridata_cards(html)
            d = _scrape_mridata_card(card)
            d === nothing && continue
            haskey(entries, d["id"]) && continue
            entries[d["id"]] = d
            new_on_page += 1
        end
        new_on_page == 0 && break
    end

    isempty(entries) && error("mridata.org list page yielded no datasets")

    if fetch_sizes
        for (uuid, d) in entries
            haskey(d, "approx_size_bytes") && continue
            sz = _http_head_content_length(mridata_url(uuid))
            sz === nothing || (d["approx_size_bytes"] = sz)
        end
    end

    _write_mridata_index_toml(dest, entries)
    return dest
end

# Split the page into per-dataset card blocks. Each dataset is wrapped in
# `<div class="card my-2">`; splitting on that marker gives one block per card
# (the first chunk is page chrome and is dropped by the no-UUID guard downstream).
_split_mridata_cards(html::AbstractString) = split(html, "<div class=\"card my-2\">")

# Pull a single field out of a card block. mridata renders two shapes:
#   detail table:  <th ...>Label</th> <td>value</td>
#   summary table: >Label:</td> <td ...>value</td>
# We try the detail form first, then the summary form, and collapse whitespace.
function _card_field(card::AbstractString, label::AbstractString)
    th = Regex("<th[^>]*>\\s*" * _re_escape(label) * "\\s*</th>\\s*<td>\\s*(.*?)\\s*</td>", "is")
    m = match(th, card)
    if m === nothing
        td = Regex(">\\s*" * _re_escape(label) * ":\\s*</td>\\s*<td[^>]*>\\s*(.*?)\\s*</td>", "is")
        m = match(td, card)
    end
    m === nothing && return nothing
    val = strip(replace(m.captures[1], r"\s+" => " "))
    return isempty(val) ? nothing : val
end

# Minimal regex-escape for field labels (they contain only word chars/spaces today,
# but escaping keeps the matcher correct if a label ever gains punctuation).
_re_escape(s::AbstractString)::String = replace(s, r"([\\^$.|?*+()\[\]{}])" => s"\\\1")

# Map mridata's free-text vendor string to our vendor Symbol vocabulary.
function _normalize_vendor(s::AbstractString)
    v = lowercase(s)
    occursin("siemens", v) && return "siemens"
    occursin("philips", v) && return "philips"
    (occursin("ge ", v) || v == "ge" || occursin("general electric", v)) && return "ge"
    return v
end

# Map mridata's anatomy label to our anatomy vocabulary (lowercased; multi-word
# labels like "Fruits/Vegetables" are kept verbatim, lowercased).
_normalize_anatomy(s::AbstractString) = lowercase(s)

# "Yes"/"No" -> Bool; anything else (e.g. "Unknown") -> nothing.
function _yesno(s::AbstractString)
    v = lowercase(strip(s))
    v == "yes" && return true
    v == "no" && return false
    return nothing
end

# Parse "512 x 512 x 240" -> (512, 512, 240). Returns an empty vector if unparseable.
function _parse_matrix_size(s::AbstractString)
    dims = Int[]
    for m in eachmatch(r"\d+", s)
        push!(dims, parse(Int, m.match))
    end
    return dims
end

# "trajectoryType.CARTESIAN" / "cartesian" -> "cartesian"; "...RADIAL" -> "radial".
function _normalize_trajectory(s::AbstractString)
    v = lowercase(s)
    occursin("cartesian", v) && return "cartesian"
    occursin("radial", v) && return "radial"
    occursin("spiral", v) && return "spiral"
    return v
end

# Parse a full card block into a metadata dict in the bundled-TOML shape. Returns
# `nothing` for blocks with no UUID (page chrome). Unknown fields are simply left
# out, so the catalog reader's defaults apply.
function _scrape_mridata_card(card::AbstractString)
    um = match(_UUID_RE, card)
    um === nothing && return nothing
    d = Dict{String, Any}("id" => lowercase(um.match))

    anat = _card_field(card, "Anatomy")
    anat === nothing || (d["anatomy"] = _normalize_anatomy(anat))

    vend = _card_field(card, "System Vendor")
    vend === nothing || (d["vendor"] = _normalize_vendor(vend))

    fs = _card_field(card, "Fullysampled")
    if fs !== nothing
        b = _yesno(fs)
        b === nothing || (d["fully_sampled"] = b)
    end

    fld = _card_field(card, "System Field Strength")  # e.g. "2.89362 T"
    if fld !== nothing
        fm = match(r"[-+]?\d*\.?\d+", fld)
        fm === nothing || (d["field_strength"] = parse(Float64, fm.match))
    end

    ch = _card_field(card, "Number of Channels")
    if ch !== nothing
        cm = match(r"\d+", ch)
        cm === nothing || (d["coils"] = parse(Int, cm.match))
    end

    traj = _card_field(card, "Trajectory")
    traj === nothing || (d["trajectory"] = _normalize_trajectory(traj))

    # Matrix size drives is3D and provides a useful size hint. Some cards carry a
    # placeholder "2 x 2 x 1" (metadata not populated upstream) — treat a degenerate
    # matrix as "unknown" rather than asserting 2D.
    msz = _card_field(card, "Matrix Size")
    if msz !== nothing
        dims = _parse_matrix_size(msz)
        if length(dims) >= 3 && maximum(dims) > 2
            d["matrix_size"] = join(dims, "x")
            d["is3D"] = dims[3] > 1
        end
    end

    # Everything else is preserved verbatim under `extra` for downstream filtering
    # and display. These are optional and skipped when absent.
    for (key, label) in (
            "project" => "Project",
            "model" => "System Model",
            "coil_name" => "Coil Name",
            "institution" => "Institution Name",
            "protocol" => "Protocol Name",
            "series_description" => "Series Description",
            "sequence_type" => "Sequence Type",
            "slices" => "Number of Slices",
            "repetitions" => "Number of Repetition",
            "contrasts" => "Number of Contrasts",
            "field_of_view" => "Field Of View",
            "echo_time" => "Echo Time",
            "repetition_time" => "Repetition Time",
            "flip_angle" => "Flip Angle",
            "downloads" => "Downloads",
            "upload_date" => "Upload Date",
        )
        v = _card_field(card, label)
        v === nothing || (d[key] = v)
    end

    return d
end

# Keys written as native TOML types (not quoted strings).
const _MRIDATA_NUMERIC_KEYS = ("approx_size_bytes", "coils", "field_strength")
const _MRIDATA_BOOL_KEYS = ("fully_sampled", "is3D")

function _write_mridata_index_toml(dest::AbstractString, entries::AbstractDict)
    tmp = dest * ".part"
    open(tmp, "w") do io
        println(io, "# mridata.org dataset index (auto-generated by refresh_index).")
        println(io, "# One [[dataset]] per card scraped from mridata.org/list.")
        for (_, d) in sort(collect(entries); by = first)
            println(io, "\n[[dataset]]")
            println(io, "id = ", repr(d["id"]))
            # Stable field order: the typed catalog fields first, then extras.
            for k in ("name", "anatomy", "vendor", "trajectory", "matrix_size")
                haskey(d, k) && println(io, k, " = ", repr(String(d[k])))
            end
            for k in _MRIDATA_NUMERIC_KEYS
                haskey(d, k) && println(io, k, " = ", d[k])
            end
            for k in _MRIDATA_BOOL_KEYS
                haskey(d, k) && println(io, k, " = ", d[k])
            end
            # Remaining string-valued extras, sorted for a stable diff.
            handled = Set(["id", "name", "anatomy", "vendor", "trajectory", "matrix_size", _MRIDATA_NUMERIC_KEYS..., _MRIDATA_BOOL_KEYS...])
            for k in sort(collect(keys(d)))
                k in handled && continue
                println(io, k, " = ", repr(string(d[k])))
            end
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

# Issue an HTTP HEAD request and return the Content-Length as an Int, or nothing
# if the server does not advertise a size or the request fails.
function _http_head_content_length(url::AbstractString; timeout::Real = 30)::Union{Int, Nothing}
    try
        resp = Downloads.request(String(url); method = "HEAD", output = devnull, timeout = float(timeout))
        for (k, v) in resp.headers
            lowercase(k) == "content-length" || continue
            n = tryparse(Int, strip(v))
            n === nothing || return n
        end
    catch
        # network error or unsupported method — size stays unknown
    end
    return nothing
end
