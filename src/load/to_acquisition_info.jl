# Convert an MRIBase.AcquisitionData into a source-agnostic `AcqSpec` NamedTuple.
#
# This is the decoupling seam: all the layout logic lives here and depends only on
# MRIBase, so it is unit-testable without MriReconstructionToolbox. The package
# extension turns an AcqSpec into the toolbox's `AcquisitionInfo` types.
#
# AcqSpec shapes:
#   (; kind=:cartesian,    kspace_data, image_size, is3D, subsampling, coils)
#   (; kind=:noncartesian, kspace_data, trajectory, dcf, image_size, is3D, coils)

"""
    acq_spec(acq::AcquisitionData; echo=1, rep=1, slice=1) -> NamedTuple
    acq_spec(path::AbstractString; kwargs...) -> NamedTuple

Build a source-agnostic acquisition spec (a `NamedTuple`) from an
`MRIBase.AcquisitionData` (or an ISMRMRD file path). The result has `kind`
`:cartesian` or `:noncartesian` and carries `NamedDimsArray` k-space data plus the
metadata needed to construct an `AcquisitionInfo`. See [`load`](@ref) to go all the
way to the toolbox type.
"""
function acq_spec(acq::AcquisitionData; echo::Int = 1, rep::Int = 1, slice::Int = 1)
    tr = trajectory(acq, echo)
    return isCartesian(tr) ? _cartesian_spec(acq; echo, rep) :
           _noncartesian_spec(acq; echo, rep, slice)
end

acq_spec(path::AbstractString; kwargs...) = acq_spec(load_acq(path); kwargs...)

# Map a Cartesian AcquisitionData to an AcqSpec. The toolbox accepts two layouts:
#  * fully sampled -> a dense grid with separate (:kx,:ky[,:kz]) dims and no
#    subsampling pattern;
#  * undersampled  -> the samples *compressed* at the masked positions, with the
#    spatial axes flattened into a single :kxy (2D) / :kxyz (3D) dimension and the
#    Bool mask supplied as a 1-tuple `(mask,)`.
function _cartesian_spec(acq::AcquisitionData{T,D}; echo::Int, rep::Int) where {T,D}
    # Dense, zero-filled encoded grid: [x, y, z*slices, channels, echoes, reps].
    grid = kDataCart(acq)
    N = encodingSize(acq)
    ncoil = numChannels(acq)
    is3D = D == 3

    # Sampling mask over the encoded grid (subsampleIndices are linear indices).
    mask = falses(N...)
    mask[acq.subsampleIndices[echo]] .= true
    fully_sampled = all(mask)

    if is3D
        ksp = grid[:, :, :, :, echo, rep]                    # kx, ky, kz, coil
        if fully_sampled
            kspace = NamedDimsArray(ksp, (:kx, :ky, :kz, :coil))
            subsampling = nothing
        else
            # compress spatial axes -> (:kxyz, :coil)
            compressed = reshape(ksp, prod(N), ncoil)[vec(mask), :]
            kspace = NamedDimsArray(compressed, (:kxyz, :coil))
            subsampling = (mask,)
        end
    else
        # 2D (single- or multi-slice): reorder to (..., :coil, :z).
        ksp = permutedims(grid[:, :, :, :, echo, rep], (1, 2, 4, 3))  # kx, ky, coil, z
        nz = size(ksp, 4)
        if fully_sampled
            kspace = NamedDimsArray(ksp, (:kx, :ky, :coil, :z))
            subsampling = nothing
        else
            # compress spatial axes per coil/slice -> (:kxy, :coil, :z)
            compressed = reshape(ksp, prod(N), ncoil, nz)[vec(mask), :, :]
            kspace = NamedDimsArray(compressed, (:kxy, :coil, :z))
            subsampling = (mask,)
        end
    end

    return (;
        kind = :cartesian,
        kspace_data = kspace,
        image_size = Tuple(N),
        is3D = is3D,
        subsampling = subsampling,
        coils = ncoil,
    )
end

function _noncartesian_spec(acq::AcquisitionData{T,D}; echo::Int, rep::Int, slice::Int) where {T,D}
    tr = trajectory(acq, echo)
    nodes = kspaceNodes(tr)                       # D × Nsamples, normalized to [-0.5,0.5)
    ncoil = numChannels(acq)
    ndim = size(nodes, 1)
    is3D = ndim == 3

    ksp = acq.kdata[echo, slice, rep]             # Nsamples × ncoil

    traj = NamedDimsArray(Matrix{T}(nodes), (:coord, :sample))
    kspace = NamedDimsArray(Matrix{Complex{T}}(ksp), (:sample, :coil))

    N = encodingSize(acq)
    image_size = is3D ? (N[1], N[2], N[3]) : (N[1], N[2])

    return (;
        kind = :noncartesian,
        kspace_data = kspace,
        trajectory = traj,
        dcf = nothing,
        image_size = image_size,
        is3D = is3D,
        coils = ncoil,
    )
end

"""
    to_acquisition_info(spec::NamedTuple) -> AcquisitionInfo

Construct a `MriReconstructionToolbox.AcquisitionInfo` from an [`acq_spec`](@ref)
result. This is a stub that errors unless `MriReconstructionToolbox` is loaded; the
real implementation lives in the `MRITestDataMRTExt` package extension.
"""
function to_acquisition_info(::NamedTuple)
    error(
        "to_acquisition_info requires MriReconstructionToolbox to be loaded.\n" *
        "Run `using MriReconstructionToolbox` to enable conversion to AcquisitionInfo,\n" *
        "or use `acq_spec`/`load_acq` to work with the raw MRIBase data instead.",
    )
end
