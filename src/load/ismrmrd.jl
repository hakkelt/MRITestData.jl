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

"""
    load_raw(path; slice=nothing, repetition=nothing, contrast=nothing) -> RawAcquisitionData

Read an ISMRMRD `.h5` file at `path` into an `MRIBase.RawAcquisitionData` (raw
profiles plus the parsed XML header in `.params`). Optional `slice`, `repetition`
and `contrast` filter which profiles are loaded.
"""
function load_raw(path::AbstractString; slice = nothing, repetition = nothing, contrast = nothing)
    _patch_ismrmrd_if_needed!(path)
    return RawAcquisitionData(ISMRMRDFile(path); slice = slice, repetition = repetition, contrast = contrast)
end

"""
    load_acq(path) -> AcquisitionData

Read an ISMRMRD `.h5` file at `path` into an `MRIBase.AcquisitionData`: profiles
placed onto the encoded grid, with `subsampleIndices`, trajectories, `encodingSize`
and `fov` resolved. This is the intermediate that [`acq_spec`](@ref) consumes.
"""
function load_acq(path::AbstractString)
    _patch_ismrmrd_if_needed!(path)
    return AcquisitionData(ISMRMRDFile(path))
end
