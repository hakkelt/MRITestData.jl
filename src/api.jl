# High-level convenience API tying catalog -> download -> load together.

"""
    load(path::AbstractString; echo=1, rep=1, slice=1, as=:auto) -> AcquisitionInfo

Load an ISMRMRD `.h5` file directly into a `MriReconstructionToolbox.AcquisitionInfo`.
Requires `MriReconstructionToolbox` to be loaded (see `to_acquisition_info`).

`as` selects the container kind: `:auto` (decide from the file's trajectory),
`:cartesian`, or `:noncartesian`.
"""
function load(path::AbstractString; echo::Int = 1, rep::Int = 1, slice::Int = 1, as::Symbol = :auto)
    spec = acq_spec(path; echo, rep, slice)
    spec = _coerce_kind(spec, as)
    return to_acquisition_info(spec)
end

function _coerce_kind(spec::NamedTuple, as::Symbol)
    as === :auto && return spec
    as in (:cartesian, :noncartesian) ||
        throw(ArgumentError("`as` must be :auto, :cartesian or :noncartesian, got $(as)"))
    spec.kind === as || throw(ArgumentError(
        "requested as=$(as) but the dataset's trajectory is $(spec.kind)",
    ))
    return spec
end

"""
    load_dataset(x; as=:auto, echo=1, rep=1, slice=1,
                 force=false, verify=true, progress=true, max_bytes=nothing)
        -> AcquisitionInfo

Download the dataset for `x` (a [`DatasetEntry`](@ref) or [`DatasetHandle`](@ref))
if it is not already cached, then [`load`](@ref) it into an `AcquisitionInfo`.
Download-related keywords are forwarded to [`download_dataset`](@ref); loading
keywords (`as`, `echo`, `rep`, `slice`) to [`load`](@ref).
"""
function load_dataset(
    x::Union{DatasetEntry,DatasetHandle};
    as::Symbol = :auto,
    echo::Int = 1,
    rep::Int = 1,
    slice::Int = 1,
    force::Bool = false,
    verify::Bool = true,
    progress::Bool = true,
    max_bytes::Union{Integer,Nothing} = nothing,
)
    path = download_dataset(x; force, verify, progress, max_bytes)
    return load(path; echo, rep, slice, as)
end

# AcquisitionData method is provided by the MRIReco extension; these forward paths
# and catalog entries to it after reading/downloading. The `recon` generic (with the
# docstring) is declared in load/ismrmrd.jl (included earlier).
recon(path::AbstractString; kwargs...) = recon(load_acq(path); kwargs...)

function recon(
    x::Union{DatasetEntry,DatasetHandle};
    force::Bool = false,
    verify::Bool = true,
    progress::Bool = true,
    max_bytes::Union{Integer,Nothing} = nothing,
    kwargs...,
)
    path = download_dataset(x; force, verify, progress, max_bytes)
    return recon(path; kwargs...)
end
