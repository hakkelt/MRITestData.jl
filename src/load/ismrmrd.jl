# Thin wrappers over MRIFiles/MRIBase ISMRMRD readers. The heavy lifting
# (HDF5 + XML parsing, profile placement, trajectory assembly) lives in those
# packages; we only re-export it under convenient names.

# MRIFiles.GeneralParameters parses `<waveformName>` as Float64 (bug: it's a
# String in cardiac OCMR files, e.g. "ECG"). Strip waveformInformation blocks
# from the cached HDF5 file before MRIFiles reads it — done in-place once so
# subsequent loads are free.
function _patch_ismrmrd_if_needed!(path::AbstractString)
    HDF5 = MRIFiles.HDF5
    # `h[name]` is typed `Union{Dataset,Datatype,Group}`; `/dataset/xml` is always a
    # Dataset. Assert it so `read` resolves to `read(::Dataset)` (also keeps JET happy).
    xml = HDF5.h5open(path) do h
        read(h["/dataset/xml"]::HDF5.Dataset)[1]::String
    end
    occursin("<waveformInformation>", xml) || return nothing
    patched = replace(xml, r"<waveformInformation>.*?</waveformInformation>"s => "")
    HDF5.h5open(path, "r+") do h
        HDF5.delete_object(h, "/dataset/xml")
        h["/dataset/xml"] = [patched]
    end
    return nothing
end

# Resolve a dataset entry to a local ISMRMRD `.h5` path. OCMR/mridata.org cache files
# are already ISMRMRD, so the default is just the downloaded file; CMRxRecon2024 entries
# are MATLAB k-space (+ a separate mask) and are converted to ISMRMRD on first use.
_ismrmrd_path(::AbstractSource, e::DatasetEntry) = download_dataset(e)
_ismrmrd_path(::CMRxRecon2024, e::DatasetEntry) = _cmrxrecon_ismrmrd_path(e)

"""
    load_raw(path; slice=nothing, repetition=nothing, contrast=nothing) -> RawAcquisitionData
    load_raw(entry_or_handle; kwargs...) -> RawAcquisitionData

Read an ISMRMRD `.h5` file at `path` into an `MRIBase.RawAcquisitionData` (raw
profiles plus the parsed XML header in `.params`). Optional `slice`, `repetition`
and `contrast` filter which profiles are loaded.

Given a [`DatasetEntry`](@ref) or [`DatasetHandle`](@ref), the dataset is downloaded
(and cached) first; CMRxRecon2024 entries are converted from their MATLAB k-space
(plus the paired undersampling mask) into a cached ISMRMRD file transparently.
"""
function load_raw(path::AbstractString; slice = nothing, repetition = nothing, contrast = nothing)
    _patch_ismrmrd_if_needed!(path)
    return RawAcquisitionData(ISMRMRDFile(path); slice = slice, repetition = repetition, contrast = contrast)
end

load_raw(e::DatasetEntry; kwargs...) = load_raw(_ismrmrd_path(e.source, e); kwargs...)
load_raw(h::DatasetHandle; kwargs...) = load_raw(h.entry; kwargs...)

"""
    load_acq(path) -> AcquisitionData
    load_acq(entry_or_handle) -> AcquisitionData

Read an ISMRMRD `.h5` file at `path` into an `MRIBase.AcquisitionData`: profiles
placed onto the encoded grid, with `subsampleIndices`, trajectories, `encodingSize`
and `fov` resolved. This is the intermediate that [`acq_spec`](@ref) consumes.

Given a [`DatasetEntry`](@ref) or [`DatasetHandle`](@ref), the dataset is downloaded
(and cached) first; CMRxRecon2024 entries are converted from their MATLAB k-space
(plus the paired undersampling mask) into a cached ISMRMRD file transparently.
"""
function load_acq(path::AbstractString)
    _patch_ismrmrd_if_needed!(path)
    return AcquisitionData(ISMRMRDFile(path))
end

load_acq(e::DatasetEntry) = load_acq(_ismrmrd_path(e.source, e))
load_acq(h::DatasetHandle) = load_acq(h.entry)
