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
_bundled_index_path(::FastMRI) = _FASTMRI_MAP_PATH
_is_static_index(::FastMRI) = true

# Derive the user-facing id from the member path. The path is
# "<anatomy_split_prefix>/<filename>.h5" (e.g. "knee_singlecoil_train/file1000000.h5");
# the id drops the extension: "knee_singlecoil_train/file1000000".
function _fastmri_path_to_id(path::AbstractString)
    return replace(String(path), r"\.h5$"i => "")
end

# Map anatomy strings from the CSV to symbols used in DatasetEntry.
function _fastmri_anatomy(s::AbstractString)
    return s in ("knee", "brain", "prostate", "breast") ? Symbol(s) : nothing
end

function _fastmri_entry(row, col)
    path = _csv_cell_str(row, col, "path")
    isempty(path) && return nothing

    archive = _csv_cell_str(row, col, "archive")
    isempty(archive) && return nothing

    tar_data_offset = _csv_cell_int(row, col, "tar_data_offset")
    file_size = _csv_cell_int(row, col, "file_size")

    (tar_data_offset === nothing || file_size === nothing) && return nothing

    anat_str = _csv_cell_str(row, col, "anatomy")
    anatomy = _fastmri_anatomy(anat_str)
    coils_str = _csv_cell_str(row, col, "coils")
    coils = tryparse(Int, coils_str)

    # For prostate the `coils` column holds the sequence type (DIFF / T2), not a count.
    seq = !isempty(coils_str) && coils_str ∉ ("singlecoil", "multicoil") ? uppercase(coils_str) : ""

    # Field strength: knee/brain — leave unset (ISMRMRD header carries it).
    # Prostate / breast: 3 T scanners in the fastMRI protocol.
    field_strength = anatomy === :prostate || anatomy === :breast ? 3.0f0 : nothing

    id = _fastmri_path_to_id(path)
    anat_label = isempty(anat_str) ? "?" : uppercasefirst(anat_str)
    seq_label = isempty(seq) ? "" : string(" ", seq)
    label = string("fastMRI ", anat_label, seq_label, " — ", basename(id))

    extra = Dict{String, Any}(
        "path" => path,
        "archive" => archive,
        "tar_data_offset" => tar_data_offset,
        "file_size" => file_size,
    )
    _put_columns!(extra, row, col, _csv_cell_str, ("split", "patient_id"))
    _put_optional!(extra, "sequence", seq)

    # The prostate dataset is highly accelerated (aliased).
    is_fully_sampled = anatomy !== :prostate

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

_fastmri_entries(path::AbstractString) = _parse_offset_map(path, _fastmri_entry)

function _catalog_entries(s::FastMRI; offline::Bool = false)
    return _cached_index_entries(ensure_index(s; offline = offline), _fastmri_entries)
end
