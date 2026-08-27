# fastMRI catalog. Like M4Raw (and unlike OCMR/mridata) there is no remote index to
# scrape: the catalog is a *static* offset map, generated once by the maintainer scripts
# `scripts/index_fastmri.jl` (.tar.xz) and `scripts/index_fastmri_gz.jl` (.tar.gz) and
# committed to the package as `data/fastmri_map.csv`. Each row records where one
# fastMRI-layout `.h5` member lives inside its archive — as an absolute byte position in
# the concatenated tar stream (tar_data_offset) and file_size — along with member metadata
# (anatomy, coils, split, patient_id). For `.tar.xz` (knee, brain) the runtime fetches the
# xz stream index (2 tiny range requests), finds overlapping xz blocks, downloads +
# decompresses only those blocks, and splices out the member bytes. For `.tar.gz`
# (prostate, breast) it seeds a raw-inflate decoder from the nearest per-archive zran
# checkpoint (`data/fastmri_zran/<stem>.bin.gz`) and streams only the member's bytes.
#
# Map CSV schema:
#   path, archive, tar_data_offset, file_size, anatomy, coils, split, patient_id
#   (for prostate the `coils` column holds the sequence type: DIFF or T2)

const _FASTMRI_MAP_PATH = normpath(joinpath(@__DIR__, "..", "..", "data", "fastmri_map.csv"))
index_ext(::FastMRI) = "csv"
_bundled_index_path(::FastMRI) = _FASTMRI_MAP_PATH

# The map is static and bundled — there is no upstream to scrape. "Fetching" just copies
# the bundled file into the cache (no network). The sentinel URL is used for the meta sidecar.
_index_source_url(::FastMRI) = "bundled://fastmri_map.csv"

function _fetch_index(::FastMRI, dest::AbstractString; progress::Bool = false, fetch_sizes::Bool = false)
    mkpath(dirname(dest))
    cp(_FASTMRI_MAP_PATH, dest; force = true)
    return dest
end

# Defensive int reader: handles integer, float-parsed, and string CSV cells.
function _fastmri_int(row, col, key)
    idx = get(col, key, 0)
    idx == 0 && return nothing
    v = row[idx]
    v isa Integer && return Int(v)
    v isa Real && return round(Int, v)
    return tryparse(Int, strip(String(v)))
end

# Defensive string reader: returns "" for absent or empty columns.
function _fastmri_str(row, col, key)
    idx = get(col, key, 0)
    idx == 0 && return ""
    v = row[idx]
    return strip(v isa AbstractString ? String(v) : string(v))
end

# Derive the user-facing id from the member path. The path is
# "<anatomy_split_prefix>/<filename>.h5" (e.g. "knee_singlecoil_train/file1000000.h5");
# the id drops the extension: "knee_singlecoil_train/file1000000".
function _fastmri_path_to_id(path::AbstractString)
    return replace(String(path), r"\.h5$"i => "")
end

# Map anatomy strings from the CSV to symbols used in DatasetEntry.
function _fastmri_anatomy(s::AbstractString)
    s == "knee" && return :knee
    s == "brain" && return :brain
    s == "prostate" && return :prostate
    s == "breast" && return :breast
    return nothing
end

# Map coils string to an Int (or nothing if not a number).
function _fastmri_coils(s::AbstractString)
    n = tryparse(Int, s)
    n !== nothing && return n
    return nothing
end

function _fastmri_entry(row, col)
    path = _fastmri_str(row, col, "path")
    isempty(path) && return nothing

    archive = _fastmri_str(row, col, "archive")
    isempty(archive) && return nothing

    tar_data_offset = _fastmri_int(row, col, "tar_data_offset")
    file_size = _fastmri_int(row, col, "file_size")

    (tar_data_offset === nothing || file_size === nothing) && return nothing

    anat_str = _fastmri_str(row, col, "anatomy")
    anatomy = _fastmri_anatomy(anat_str)
    coils_str = _fastmri_str(row, col, "coils")
    coils = _fastmri_coils(coils_str)
    split = _fastmri_str(row, col, "split")
    patient_id = _fastmri_str(row, col, "patient_id")

    # Field strength: knee/brain — leave unset (ISMRMRD header carries it).
    # Prostate / breast: 3 T scanners in the fastMRI protocol.
    field_strength = anatomy === :prostate || anatomy === :breast ? 3.0f0 : nothing

    id = _fastmri_path_to_id(path)
    anat_label = isempty(anat_str) ? "?" : uppercasefirst(anat_str)
    # For prostate, the coils column holds the sequence type (DIFF / T2); include it.
    seq_label = coils_str ∉ ("singlecoil", "multicoil") && !isempty(coils_str) ?
        string(" ", uppercase(coils_str)) : ""
    label = string("fastMRI ", anat_label, seq_label, " — ", basename(id))

    extra = Dict{String, Any}(
        "path" => path,
        "archive" => archive,
        "tar_data_offset" => tar_data_offset,
        "file_size" => file_size,
    )
    isempty(split) || (extra["split"] = split)
    isempty(patient_id) || (extra["patient_id"] = patient_id)
    # Prostate uses the coils column to store sequence type (DIFF / T2).
    if coils_str ∉ ("singlecoil", "multicoil") && !isempty(coils_str)
        extra["sequence"] = uppercase(coils_str)
    end

    # The prostate dataset is highly accelerated (aliased).
    is_fully_sampled = (anatomy === :prostate) ? false : true

    return DatasetEntry(;
        source = FASTMRI,
        id = id,
        name = label,
        anatomy = anatomy,
        vendor = nothing,
        field_strength = field_strength,
        trajectory = anatomy === :breast ? :radial : :cartesian,
        coils = coils,
        fully_sampled = is_fully_sampled,
        is3D = anatomy === :breast,
        approx_size_bytes = file_size,
        # The URL is resolved at download time from stored Preferences; leave it empty.
        url = "",
        extra = extra,
    )
end

function _fastmri_entries(path::AbstractString)
    isfile(path) || return DatasetEntry[]
    data, header = readdlm(path, ','; header = true)
    col = Dict(strip(String(h)) => i for (i, h) in enumerate(vec(header)))
    haskey(col, "path") || return DatasetEntry[]
    entries = DatasetEntry[]
    for r in axes(data, 1)
        e = _fastmri_entry(data[r, :], col)
        e === nothing || push!(entries, e)
    end
    return entries
end

function _catalog_entries(s::FastMRI; offline::Bool = false)
    path = ensure_index(s; offline = offline)
    return _fastmri_entries(path)
end

function _synthesize_entry(::FastMRI, id::String)
    return error(
        "Unknown fastMRI file $(repr(id)). fastMRI entries must be present in the " *
            "committed offset map (data/fastmri_map.csv); generate it with " *
            "`scripts/index_fastmri.jl` after receiving download links from fastmri.med.nyu.edu.",
    )
end
