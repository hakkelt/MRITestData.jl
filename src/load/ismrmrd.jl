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

"""
    recon(acq; reco="direct", kwargs...)
    recon(path::AbstractString; kwargs...)
    recon(x::Union{DatasetEntry,DatasetHandle}; download_kwargs..., kwargs...)

Reconstruct an image from MRI k-space using [MRIReco.jl](https://github.com/MagneticResonanceImaging/MRIReco.jl).
Accepts an `MRIBase.AcquisitionData`, an ISMRMRD file path, or a catalog entry/handle
(downloaded if needed). Requires `MRIReco` to be loaded — the implementation lives in
the `MRITestDataMRIRecoExt` package extension.

Keyword arguments are forwarded to MRIReco's `reconstruction` as reconstruction
parameters (merged over sensible defaults). Common ones:

- `reco`: `"direct"` (default), `"standard"`, `"multiCoil"` (SENSE), …
- `reconSize`: output image size (defaults to the encoded size).
- `solver`, `iterations`, `reg`: iterative-reconstruction controls.
- `senseMaps`: coil sensitivity maps for `"multiCoil"`.

# Examples
```julia
using MRITestData, MRIReco
img = recon(load_acq("scan.h5"))                       # direct Fourier
img = recon("scan.h5"; reco = "standard", iterations = 20)
img = recon(first(list_datasets(OCMR_SOURCE)); reco = "direct")
```
"""
function recon(acq; kwargs...)
    # The real `recon(::AcquisitionData; ...)` method is added by MRITestDataMRIRecoExt
    # when MRIReco is loaded. This catch-all is intentionally untyped so the extension's
    # method is strictly more specific and does not trigger "method overwriting".
    if acq isa AcquisitionData
        error(
            "recon on an AcquisitionData requires MRIReco to be loaded.\n" *
                "Run `using MRIReco` to enable reconstruction.",
        )
    end
    throw(ArgumentError("recon does not support arguments of type $(typeof(acq))"))
end
