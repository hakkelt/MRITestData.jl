# fastMRI catalog. Like M4Raw (and unlike OCMR/mridata) there is no remote index to
# scrape: the catalog is a *static* offset map, generated once by the maintainer scripts
# `scripts/index_fastmri.jl` (.tar.xz) and `scripts/index_fastmri_gz.jl` (.tar.gz) and
# committed to the package as `data/fastmri_map.csv`. Each row records where one
# fastMRI-layout `.h5` member lives inside its archive — as an absolute byte position in
# the concatenated tar stream (tar_data_offset) and file_size — along with member metadata
# (anatomy, series_variant, split, patient_id). For `.tar.xz` (knee, brain) the runtime
# fetches the xz stream index (2 tiny range requests), finds overlapping xz blocks,
# downloads + decompresses only those blocks, and splices out the member bytes. For
# `.tar.gz` (prostate, breast) it seeds a raw-inflate decoder from the nearest per-archive
# zran checkpoint (`data/fastmri_zran/<stem>.bin.gz`) and streams only the member's bytes.
#
# Map CSV schema:
#   path, archive, tar_data_offset, file_size, anatomy, series_variant, split, patient_id
#
# `series_variant` is the archive filename's middle token, NOT a coil count:
# "singlecoil"/"multicoil" for knee/brain (e.g. knee_singlecoil_train), or the sequence
# type "T2"/"DIFF" for prostate (e.g. fastMRI_prostate_T2_IDS_001_020.tar.gz). Breast rows
# leave it blank (its archives carry no such token). See plan §7.1 for the correctness bug
# this used to hide: `tryparse(Int, "singlecoil")` silently returned `nothing` on every row.

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

# The per-anatomy protocol facts the fastMRI papers document (plan §6, §12). Applied on
# top of what the map row itself carries (split, patient_id, brain contrast token).
function _fastmri_series(anatomy::Union{Symbol, Nothing}, brain_token::AbstractString)
    anatomy === :knee && return (
        contrast = :proton_density, orientation = :coronal, sequence = "fast spin echo",
        vendor = :siemens, scanner_model = nothing, field_strength = nothing,
        receiver_channels = nothing, num_slices = nothing, trajectory = :cartesian,
        acquisition_dim = 2, acceleration = nothing, partial_fourier = nothing,
        contrast_agent = nothing,
    )
    if anatomy === :brain
        contrast, contrast_agent = if brain_token == "AXT1POST"
            :t1, true
        elseif brain_token in ("AXT1", "AXT1PRE")
            :t1, false
        elseif brain_token == "AXT2"
            :t2, nothing
        elseif brain_token == "AXFLAIR"
            :fluid_attenuated, nothing
        else
            :unknown, nothing
        end
        return (
            contrast = contrast, orientation = :axial, sequence = nothing,
            vendor = nothing, scanner_model = nothing, field_strength = nothing,
            receiver_channels = nothing, num_slices = nothing, trajectory = :cartesian,
            acquisition_dim = 2, acceleration = nothing, partial_fourier = nothing,
            contrast_agent = contrast_agent,
        )
    end
    if anatomy === :prostate
        contrast, sequence = brain_token == "DIFF" ? (:diffusion, "echo-planar imaging") : (:t2, "turbo spin echo")
        return (
            contrast = contrast, orientation = :axial, sequence = sequence,
            vendor = nothing, scanner_model = nothing, field_strength = 3.0,
            receiver_channels = nothing, num_slices = nothing, trajectory = :cartesian,
            acquisition_dim = 2, acceleration = nothing, partial_fourier = nothing,
            contrast_agent = nothing,
        )
    end
    anatomy === :breast && return (
        contrast = :t1, orientation = nothing, sequence = "radial VIBE (stack-of-stars)",
        vendor = :siemens, scanner_model = "Siemens MAGNETOM TimTrio", field_strength = 3.0,
        receiver_channels = 16, num_slices = 192, trajectory = :goldenangle,
        acquisition_dim = 3, acceleration = 2.8, partial_fourier = true,
        contrast_agent = nothing,
    )
    return (
        contrast = :unknown, orientation = nothing, sequence = nothing,
        vendor = nothing, scanner_model = nothing, field_strength = nothing,
        receiver_channels = nothing, num_slices = nothing, trajectory = :unknown,
        acquisition_dim = 2, acceleration = nothing, partial_fourier = nothing,
        contrast_agent = nothing,
    )
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
    series_variant = _csv_cell_str(row, col, "series_variant")

    # singlecoil/multicoil (knee, brain) vs. T2/DIFF (prostate sequence token).
    coil_data = series_variant == "singlecoil" ? :derived : :original
    brain_token = series_variant in ("singlecoil", "multicoil") ? "" : uppercase(series_variant)

    series = _fastmri_series(anatomy, brain_token)

    split_str = _csv_cell_str(row, col, "split")
    split = _normalize_split(split_str)
    patient_id = _csv_cell_str(row, col, "patient_id")

    id = _fastmri_path_to_id(path)
    anat_label = isempty(anat_str) ? "?" : uppercasefirst(anat_str)
    variant_label = isempty(brain_token) ? "" : string(" ", brain_token)
    label = string("fastMRI ", anat_label, variant_label, " — ", basename(id))

    locator = Dict{String, Any}(
        "path" => path,
        "archive" => archive,
        "tar_data_offset" => tar_data_offset,
        "file_size" => file_size,
    )

    # Test-split knee/brain data is prospectively undersampled (ships a `mask`), and
    # prostate/breast are highly accelerated regardless of split — only train/val
    # knee/brain is genuinely fully sampled. Previously `anatomy !== :prostate` alone
    # decided this, so all 1342 knee/brain test-split entries claimed `fully_sampled =
    # true` while being undersampled (fixed here; plan §7.1).
    fully_sampled = anatomy in (:prostate, :breast) ? false : split !== :test

    return DatasetEntry(;
        source = FASTMRI,
        id = id,
        name = label,
        subject_id = isempty(patient_id) ? nothing : patient_id,
        split = split,
        vendor = series.vendor,
        scanner_model = series.scanner_model,
        field_strength = series.field_strength,
        receiver_channels = series.receiver_channels,
        coil_data = coil_data,
        anatomy = something(anatomy, :unknown),
        contrast = series.contrast,
        orientation = series.orientation,
        sequence = series.sequence,
        acquisition_dim = series.acquisition_dim,
        num_slices = series.num_slices,
        trajectory = series.trajectory,
        fully_sampled = fully_sampled,
        acceleration = series.acceleration,
        partial_fourier = series.partial_fourier,
        contrast_agent = series.contrast_agent,
        file_format = :fastmri_h5,
        approx_size_bytes = file_size,
        # The URL is resolved at download time from stored Preferences; leave it empty.
        url = "",
        extra = Dict{String, Any}(),
        locator = locator,
    )
end

_fastmri_entries(path::AbstractString) = _parse_offset_map(path, _fastmri_entry)

function _catalog_entries(s::FastMRI; offline::Bool = false)
    return _cached_index_entries(ensure_index(s; offline = offline), _fastmri_entries)
end
