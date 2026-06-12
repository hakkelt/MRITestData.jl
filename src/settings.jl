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
  • mridata.org  →  http://mridata.org/terms
  • OCMR         →  https://www.ocmr.info/download/

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

Persistently store a Synapse Personal Access Token used to download the
[`CMRXRECON2024`](@ref) dataset. The token is saved in `LocalPreferences.toml` and
survives across sessions. It is read by [`download_dataset`](@ref) for CMRxRecon2024
files (the `SYNAPSE_AUTH_TOKEN` environment variable takes precedence if set).

The token must belong to an account that has completed the CMRxRecon2024 challenge
registration; otherwise it lacks permission to download the data fragments. See the
package README for registration instructions.
"""
function set_synapse_token!(token::AbstractString)
    set_preferences!(MRITestData, "synapse_token" => String(token); export_prefs = false, force = true)
    return nothing
end

"""
    get_synapse_token() -> String

Return the Synapse Personal Access Token used for [`CMRXRECON2024`](@ref) downloads.
The `SYNAPSE_AUTH_TOKEN` environment variable takes precedence; otherwise the value
persisted by [`set_synapse_token!`](@ref) is returned, or `""` if none is set.
"""
function get_synapse_token()::String
    env = get(ENV, "SYNAPSE_AUTH_TOKEN", "")
    isempty(env) || return env
    return load_preference(MRITestData, "synapse_token", "")
end
