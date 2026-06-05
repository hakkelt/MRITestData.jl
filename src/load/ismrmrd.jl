# Thin wrappers over MRIFiles/MRIBase ISMRMRD readers. The heavy lifting
# (HDF5 + XML parsing, profile placement, trajectory assembly) lives in those
# packages; we only re-export it under convenient names.

"""
    load_raw(path; slice=nothing, repetition=nothing, contrast=nothing) -> RawAcquisitionData

Read an ISMRMRD `.h5` file at `path` into an `MRIBase.RawAcquisitionData` (raw
profiles plus the parsed XML header in `.params`). Optional `slice`, `repetition`
and `contrast` filter which profiles are loaded.
"""
function load_raw(path::AbstractString; slice = nothing, repetition = nothing, contrast = nothing)
    return RawAcquisitionData(ISMRMRDFile(path); slice = slice, repetition = repetition, contrast = contrast)
end

"""
    load_acq(path) -> AcquisitionData

Read an ISMRMRD `.h5` file at `path` into an `MRIBase.AcquisitionData`: profiles
placed onto the encoded grid, with `subsampleIndices`, trajectories, `encodingSize`
and `fov` resolved. This is the intermediate that [`acq_spec`](@ref) consumes.
"""
load_acq(path::AbstractString) = AcquisitionData(ISMRMRDFile(path))

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
