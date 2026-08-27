# Persistent per-user settings backed by Preferences.jl.
# Values are stored in LocalPreferences.toml and survive across Julia sessions.
# The module's __init__ reads these into the runtime Refs on startup.

# ── Terms-of-use notice ────────────────────────────────────────────────────────

function _terms_accepted()::Bool
    return load_preference(MRITestData, "terms_notice_dismissed", false)
end

"""
    dismiss_terms_notice!()

Permanently suppress the data-source terms-of-use warning that is printed when
`using MRITestData` is called. Only call this after you have reviewed the terms:
  • mridata.org    →  http://mridata.org/terms
  • OCMR           →  https://www.ocmr.info/download/
  • CMRxRecon2024  →  https://cmrxrecon.github.io/2024/FAQ.html
  • CMRxRecon-300  →  https://www.synapse.org/Synapse:syn52965326

The setting is stored in `LocalPreferences.toml` and persists across Julia sessions.
Re-enable the notice with [`enable_terms_notice!`](@ref).
"""
function dismiss_terms_notice!()
    set_preferences!(MRITestData, "terms_notice_dismissed" => true; export_prefs = false, force = true)
    @info "Terms notice permanently disabled. Re-enable with `MRITestData.enable_terms_notice!()`."
    return nothing
end

"""
    enable_terms_notice!()

Re-enable the data-source terms-of-use warning printed on `using MRITestData`.
Reverts a previous [`dismiss_terms_notice!`](@ref) call.
"""
function enable_terms_notice!()
    set_preferences!(MRITestData, "terms_notice_dismissed" => false; export_prefs = false, force = true)
    @info "Terms notice re-enabled."
    return nothing
end

# ── Chunk count ────────────────────────────────────────────────────────────────

"""
    get_chunk_size() -> Int

Return the number of parallel download chunks (see [`MRITestData.PARALLEL_CHUNKS`](@ref)).
Reads the persistent preference; defaults to `4` if not set.
"""
function get_chunk_size()::Int
    return load_preference(MRITestData, "chunk_size", 4)
end

"""
    set_chunk_size!(n::Int)

Persistently set the number of parallel byte-range chunks used during download.
Also updates [`MRITestData.PARALLEL_CHUNKS`](@ref) for the current session.
Set to `1` to disable parallel chunking.
"""
function set_chunk_size!(n::Int)
    n >= 1 || throw(ArgumentError("chunk_size must be >= 1"))
    set_preferences!(MRITestData, "chunk_size" => n; export_prefs = false, force = true)
    PARALLEL_CHUNKS[] = n
    return nothing
end

# ── Minimum file size for parallel chunking ────────────────────────────────────

"""
    get_min_file_size() -> Int

Return the minimum file size in bytes below which parallel chunking is skipped
(see [`MRITestData.PARALLEL_MIN_BYTES`](@ref)). Defaults to `8_388_608` (8 MiB).
"""
function get_min_file_size()::Int
    return load_preference(MRITestData, "min_file_size", 8 * 1024 * 1024)
end

"""
    set_min_file_size!(n::Int)

Persistently set the minimum file size (bytes) threshold for parallel chunking.
Also updates [`MRITestData.PARALLEL_MIN_BYTES`](@ref) for the current session.
"""
function set_min_file_size!(n::Int)
    n >= 0 || throw(ArgumentError("min_file_size must be >= 0"))
    set_preferences!(MRITestData, "min_file_size" => n; export_prefs = false, force = true)
    PARALLEL_MIN_BYTES[] = n
    return nothing
end

# ── Index refresh period ───────────────────────────────────────────────────────

"""
    get_refresh_period() -> Int

Return the dataset-index TTL in days (see [`MRITestData.INDEX_TTL_DAYS`](@ref)).
Defaults to `30`.
"""
function get_refresh_period()::Int
    return load_preference(MRITestData, "refresh_period_days", 30)
end

"""
    set_refresh_period!(days::Int)

Persistently set how many days a cached dataset index is kept before it is
re-fetched from upstream. Also updates [`MRITestData.INDEX_TTL_DAYS`](@ref) for
the current session.
"""
function set_refresh_period!(days::Int)
    days >= 0 || throw(ArgumentError("refresh_period_days must be >= 0"))
    set_preferences!(MRITestData, "refresh_period_days" => days; export_prefs = false, force = true)
    INDEX_TTL_DAYS[] = days
    return nothing
end

# ── Synapse Personal Access Token (CMRxRecon2024) ───────────────────────────────

"""
    set_synapse_token!(token::AbstractString)

Persistently store a Synapse Personal Access Token used to download the Synapse-hosted
sources, [`CMRXRECON2024`](@ref) and [`CMRXRECON300`](@ref). The token is saved in
`LocalPreferences.toml` and survives across sessions. It is read by
[`download_dataset`](@ref) for both CMRxRecon sources (the `SYNAPSE_AUTH_TOKEN`
environment variable takes precedence if set).

CMRxRecon-300 is CC-BY and only needs a free Synapse account. CMRxRecon2024
additionally requires that the account has completed the CMRxRecon2024 challenge
registration; otherwise the token lacks permission to download its data fragments. See
the package README for registration instructions.
"""
function set_synapse_token!(token::AbstractString)
    set_preferences!(MRITestData, "synapse_token" => String(token); export_prefs = false, force = true)
    return nothing
end

"""
    get_synapse_token() -> String

Return the Synapse Personal Access Token used for [`CMRXRECON2024`](@ref) and
[`CMRXRECON300`](@ref) downloads. The `SYNAPSE_AUTH_TOKEN` environment variable takes
precedence; otherwise the value persisted by [`set_synapse_token!`](@ref) is returned,
or `""` if none is set.
"""
function get_synapse_token()::String
    env = get(ENV, "SYNAPSE_AUTH_TOKEN", "")
    isempty(env) || return env
    return load_preference(MRITestData, "synapse_token", "")
end

# ── fastMRI signed-URL credentials ────────────────────────────────────────────────

"""
    set_fastmri_urls!(text::AbstractString)

Parse the confirmation email from fastmri.med.nyu.edu (or the curl-command block within
it) and persistently store all signed download URLs in `LocalPreferences.toml`.

`text` must contain one or more lines of the form:
```
curl -C - "https://fastmri-dataset.s3.amazonaws.com/..." --output filename.tar.xz
```
All matching URLs and their output filenames are extracted and stored as a
`filename => url` mapping. The `Expires` Unix timestamp (the same across all URLs in one
email) is extracted from any URL and stored separately; [`fastmri_url_expires`](@ref)
converts it to a `DateTime`.

Call this once after receiving the access email — credentials last 90 days. Re-run after
requesting a new set of links at [https://fastmri.med.nyu.edu](https://fastmri.med.nyu.edu).
"""
function set_fastmri_urls!(text::AbstractString)
    urls = Dict{String, String}()
    expires = 0
    for m in eachmatch(r"""curl\s+-C\s+-\s+"([^"]+)"\s+--output\s+(\S+)""", text)
        c1, c2 = m.captures[1], m.captures[2]
        (c1 === nothing || c2 === nothing) && continue
        url = string(c1)
        filename = string(c2)
        urls[filename] = url
        em = match(r"[?&]Expires=(\d+)", url)
        if em !== nothing && expires == 0
            ec = em.captures[1]
            ec === nothing || (expires = parse(Int, ec))
        end
    end
    isempty(urls) &&
        throw(ArgumentError("no `curl -C - \"<url>\" --output <file>` commands found in the provided text"))
    set_preferences!(MRITestData, "fastmri_urls" => urls; export_prefs = false, force = true)
    set_preferences!(MRITestData, "fastmri_expires" => expires; export_prefs = false, force = true)
    exp_str = expires > 0 ? string(Dates.unix2datetime(expires), " UTC") : "unknown"
    @info "Stored $(length(urls)) fastMRI signed URLs; credentials expire $exp_str."
    return nothing
end

"""
    get_fastmri_url(filename) -> String

Return the stored signed URL for the fastMRI archive `filename`
(e.g. `"knee_singlecoil_train.tar.xz"`). Errors with instructions if the URL is missing
or the credentials have expired. Use [`set_fastmri_urls!`](@ref) to store new URLs.
"""
function get_fastmri_url(filename::AbstractString)::String
    urls = load_preference(MRITestData, "fastmri_urls", Dict{String, Any}())
    if !haskey(urls, filename)
        error(
            "No fastMRI signed URL stored for $(repr(filename)). " *
                "Call `MRITestData.set_fastmri_urls!(email_text)` with the text of your " *
                "fastmri.med.nyu.edu confirmation email to register the download links.",
        )
    end
    exp = load_preference(MRITestData, "fastmri_expires", 0)
    if exp > 0 && time() > exp
        error(
            "fastMRI signed URLs expired on $(Dates.unix2datetime(exp)) UTC. " *
                "Request new links at https://fastmri.med.nyu.edu and call " *
                "`MRITestData.set_fastmri_urls!(email_text)` again.",
        )
    end
    return String(urls[filename])
end

"""
    fastmri_url_expires() -> Union{DateTime, Nothing}

Return the expiry `DateTime` (UTC) of the stored fastMRI signed URLs, or `nothing` if no
URLs have been stored yet. Use [`set_fastmri_urls!`](@ref) to register new URLs.
"""
function fastmri_url_expires()::Union{Dates.DateTime, Nothing}
    exp = load_preference(MRITestData, "fastmri_expires", 0)
    exp == 0 && return nothing
    return Dates.unix2datetime(exp)
end
