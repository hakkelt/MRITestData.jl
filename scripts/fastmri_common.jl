# Shared plumbing for the fastMRI maintainer indexers `index_fastmri.jl` (.tar.xz) and
# `index_fastmri_gz.jl` (.tar.gz): argument parsing, signed-URL lookup, archive download,
# member-path metadata, and the per-archive run loop. Each script supplies only its
# format-specific `index_one!(archive_key, local_path, rows)` callback.
#
# Mirrors the `scripts/synapse_common.jl` pattern used by the CMRxRecon2024 scripts.

using TOML: TOML

const _PKG_DIR = dirname(@__DIR__)
const MAP_PATH = joinpath(_PKG_DIR, "data", "fastmri_map.csv")
const CSV_HEADER = "path,archive,tar_data_offset,file_size,anatomy,coils,split,patient_id"

# ── Argument parsing ──────────────────────────────────────────────────────────

# Returns (fresh, download_dir, output_path, sources). `--output` defaults to MAP_PATH;
# pass a per-job path when running several indexers in parallel to avoid append races.
function parse_args(raw::Vector{String})
    fresh = false
    download_dir = "/scratch/c_mrrecon/fastmri_dl"
    output_path = MAP_PATH
    sources = String[]
    i = 1
    while i <= length(raw)
        a = raw[i]
        if a == "--fresh"
            fresh = true
        elseif a == "--download-dir"
            i += 1
            i <= length(raw) || error("--download-dir requires an argument")
            download_dir = raw[i]
        elseif a == "--output"
            i += 1
            i <= length(raw) || error("--output requires an argument")
            output_path = raw[i]
        elseif startswith(a, "--")
            error("Unknown option: $a")
        else
            push!(sources, a)
        end
        i += 1
    end
    return fresh, download_dir, output_path, sources
end

# ── Signed URL lookup from LocalPreferences.toml ─────────────────────────────

function _read_stored_urls()::Dict{String, String}
    prefs_path = joinpath(_PKG_DIR, "LocalPreferences.toml")
    isfile(prefs_path) || return Dict{String, String}()
    t = TOML.parsefile(prefs_path)
    raw = get(get(t, "MRITestData", Dict{String, Any}()), "fastmri_urls", Dict{String, Any}())
    return Dict{String, String}(string(k) => string(v) for (k, v) in raw)
end

# Given an argument (URL, local path, or archive key), return
# (archive_key, url_or_nothing, local_dest_path).
function _resolve(arg::AbstractString, download_dir::AbstractString)
    if startswith(arg, "http://") || startswith(arg, "https://")
        key = basename(split(arg, "?")[1])
        return key, arg, joinpath(download_dir, key)
    elseif isfile(arg)
        return basename(arg), nothing, arg
    else
        key = basename(arg)
        urls = _read_stored_urls()
        haskey(urls, key) ||
            error("No stored URL for $(repr(key)). Call MRITestData.set_fastmri_urls! first.")
        return key, urls[key], joinpath(download_dir, key)
    end
end

# ── Resumable download via system curl ───────────────────────────────────────

function download_archive!(url::AbstractString, dest::AbstractString)
    mkpath(dirname(dest))
    isfile(dest) && @info "$(basename(dest)): resuming partial download"
    @info "Downloading $(basename(dest))…"
    # curl -C - resumes, -L follows redirects, --fail errors on HTTP failures
    run(`curl -C - -L --fail --progress-bar -o $dest $url`)
    return @info "$(basename(dest)) ready ($(round(filesize(dest) / 1.0e9; digits = 2)) GB)"
end

# ── Metadata helpers ──────────────────────────────────────────────────────────

# Derive patient_id from an archive member path. Common fastMRI patterns:
#   knee_singlecoil_train/file1000000.h5 → "1000000"
#   <dir>/file0001.h5                    → "0001"
#   <dir>/<name_with_trailing_number>.h5 → the trailing number, else the basename stem
function _patient_id(member_path::AbstractString)::String
    base = first(splitext(basename(member_path)))
    m = match(r"^file(\d+)$", base)
    m !== nothing && return m.captures[1]
    m = match(r"(\d+)$", base)
    m !== nothing && return m.captures[1]
    return base
end

# ── Per-archive run loop ─────────────────────────────────────────────────────

function _append_rows(rows::Vector{Vector{Any}}, output_path::AbstractString)
    isempty(rows) && return
    return open(output_path, "a") do f
        for r in rows
            println(f, join(string.(r), ","))
        end
    end
end

# Resolve, download (if needed), index, and delete each archive in turn. `index_one!`
# is the format-specific callback appending rows for one archive; `accept` filters
# archive keys (e.g. by extension), logging its own skip reason.
function run_indexer(
        raw_args::Vector{String};
        usage::AbstractString,
        index_one!,
        accept = _ -> true,
    )
    fresh, download_dir, output_path, sources = parse_args(raw_args)
    isempty(sources) && error(usage)

    if fresh || !isfile(output_path)
        open(output_path, "w") do f
            println(f, CSV_HEADER)
        end
    end

    mkpath(download_dir)
    total = 0
    failed = String[]

    for arg in sources
        archive_key, url, local_path = _resolve(arg, download_dir)
        accept(archive_key) || continue
        downloaded = false
        rows = Vector{Any}[]
        try
            if url !== nothing && !isfile(local_path)
                download_archive!(url, local_path)
                downloaded = true
            end
            index_one!(archive_key, local_path, rows)
            _append_rows(rows, output_path)
            total += length(rows)
            @info "$(archive_key): wrote $(length(rows)) rows (running total: $total)"
        catch err
            @error "$(archive_key) FAILED — skipping" exception = err
            push!(failed, archive_key)
        finally
            if downloaded && isfile(local_path)
                @info "Deleting $(basename(local_path))"
                rm(local_path)
            end
        end
    end

    @info "Done. Total rows written: $total"
    isempty(failed) || @warn "Failed archives (re-run manually): $(join(failed, ", "))"
    return
end
