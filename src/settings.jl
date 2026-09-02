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
`using MRITestData` is called. Only call this after you have reviewed the terms — the
notice itself lists them, and `MRITestData.terms_notice()` reprints it at any time
(`terms_url(source)` gives a single source's URL).

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

# ── Download path ──────────────────────────────────────────────────────────────

# Absolute path of the package Scratch space, filled in by `__init__`. `set_download_path!`
# points downloads either here (`:cache`) or at a user directory.
const _SCRATCH_DIR = Ref{String}("")

# Whether a download destination has been chosen (via `set_download_path!` or a persisted
# preference). Downloads are refused until it is `true`; see `_require_download_path`.
const DOWNLOAD_PATH_SET = Ref(false)

# Apply the persisted `download_path` preference to the runtime Refs. Called from `__init__`
# after `_SCRATCH_DIR` is known.
function _apply_download_path_preference()
    pref = load_preference(MRITestData, "download_path", nothing)
    if pref === nothing
        CACHE_DIR[] = ""
        DOWNLOAD_PATH_SET[] = false
    elseif pref == "cache"
        CACHE_DIR[] = _SCRATCH_DIR[]
        DOWNLOAD_PATH_SET[] = true
    else
        CACHE_DIR[] = String(pref)
        DOWNLOAD_PATH_SET[] = true
    end
    return nothing
end

function _require_download_path()
    (DOWNLOAD_PATH_SET[] || !isempty(CACHE_DIR[])) && return nothing
    error(
        """
        No download path is configured. MRITestData does not download anything until you
        choose where files should be stored:

          MRITestData.set_download_path!("/path/to/directory")  # download into this folder
          MRITestData.set_download_path!(:cache)                # use the package Scratch cache

        The choice is persisted across sessions. Alternatively pass `path=` to
        `download_dataset` for a one-off destination without setting a default.
        """,
    )
end

"""
    set_download_path!(dir::AbstractString)
    set_download_path!(:cache)

Choose where downloaded datasets (and their cached ISMRMRD conversions) are stored, and
persist the choice in `LocalPreferences.toml`.

Until this is called **all downloads are refused** — [`download_dataset`](@ref),
[`copy_dataset`](@ref) and an entry-based [`load_raw`](@ref) throw with instructions.
(Passing `path=` to `download_dataset` is the one-off exception.)

- `set_download_path!(dir)` uses `dir` (created if missing) as the cache root.
- `set_download_path!(:cache)` uses the package's per-user Scratch space — the original
  default behaviour.

Retrieve the current value with [`get_download_path`](@ref); clear it with
[`unset_download_path!`](@ref).
"""
function set_download_path!(dir::AbstractString)
    p = abspath(String(dir))
    mkpath(p)
    set_preferences!(MRITestData, "download_path" => p; export_prefs = false, force = true)
    CACHE_DIR[] = p
    DOWNLOAD_PATH_SET[] = true
    @info "MRITestData download path set to $p (persisted across sessions)."
    return nothing
end

function set_download_path!(which::Symbol)
    which === :cache || which === :scratch ||
        throw(ArgumentError("expected a directory path or `:cache`, got `:$which`"))
    set_preferences!(MRITestData, "download_path" => "cache"; export_prefs = false, force = true)
    CACHE_DIR[] = _SCRATCH_DIR[]
    DOWNLOAD_PATH_SET[] = true
    @info "MRITestData downloads will use the package Scratch cache ($(_SCRATCH_DIR[]))."
    return nothing
end

"""
    get_download_path() -> Union{String, Nothing}

Return the configured download directory, or `nothing` if none has been set (in which
case downloads are refused — see [`set_download_path!`](@ref)).
"""
function get_download_path()::Union{String, Nothing}
    isempty(CACHE_DIR[]) && return nothing
    return CACHE_DIR[]
end

"""
    unset_download_path!()

Forget the persisted download path. Downloads are refused again until
[`set_download_path!`](@ref) is called.
"""
function unset_download_path!()
    set_preferences!(MRITestData, "download_path" => nothing; export_prefs = false, force = true)
    CACHE_DIR[] = ""
    DOWNLOAD_PATH_SET[] = false
    @info "MRITestData download path cleared; downloads are refused until it is set again."
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

# Extract `filename => url` pairs and the shared `Expires` Unix timestamp (0 when no URL
# carries one) from a fastMRI access email. Split out of `set_fastmri_urls!` so the parser
# can be tested without touching Preferences. Throws if the text holds no curl commands.
function _parse_fastmri_email(text::AbstractString)::Tuple{Dict{String, String}, Int}
    urls = Dict{String, String}()
    expires = 0
    for m in eachmatch(r"""curl\s+-C\s+-\s+"([^"]+)"\s+--output\s+(\S+)""", text)
        url = string(m.captures[1])
        urls[string(m.captures[2])] = url
        em = match(r"[?&]Expires=(\d+)", url)
        if em !== nothing && expires == 0
            ec = em.captures[1]
            ec === nothing || (expires = parse(Int, ec))
        end
    end
    isempty(urls) &&
        throw(ArgumentError("no `curl -C - \"<url>\" --output <file>` commands found in the provided text"))
    return urls, expires
end

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
    urls, expires = _parse_fastmri_email(text)
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
