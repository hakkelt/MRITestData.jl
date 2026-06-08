# High-level convenience API tying catalog -> download -> reconstruct together.

# AcquisitionData method is provided by the MRIReco extension; these forward paths
# and catalog entries to it after reading/downloading. The `recon` generic (with the
# docstring) is declared in load/ismrmrd.jl (included earlier).
recon(path::AbstractString; kwargs...) = recon(load_acq(path); kwargs...)

function recon(
        x::Union{DatasetEntry, DatasetHandle};
        force::Bool = false,
        verify::Bool = true,
        progress::Bool = true,
        max_bytes::Union{Integer, Nothing} = nothing,
        kwargs...,
    )
    path = download_dataset(x; force, verify, progress, max_bytes)
    return recon(path; kwargs...)
end
