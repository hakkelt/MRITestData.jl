# Reader for "fastMRI-layout" `.h5` files — the convention shared by the NYU fastMRI
# release and by M4Raw, which adopted it. Relevant datasets:
#   • `kspace`            — complex k-space (see `_fastmri_complex_kspace` for the eltype
#                           variants HDF5 can surface).
#   • `mask`              — optional 1-D 0/1 phase-encode mask (prospectively undersampled
#                           fastMRI test splits); absent for fully-sampled data.
#   • `ismrmrd_header`    — optional ISMRMRD XML string with the scanner's encoding
#                           parameters.
#   • `reconstruction_rss` — ground-truth magnitude image; unused here.
#
# Axis order is *not* normalised here — it varies per dataset (singlecoil/multicoil/prostate
# /breast/M4Raw) and each loader permutes it into the canonical layout itself.

# Normalise the `kspace` array HDF5 surfaced into a complex array. h5py complex compounds
# arrive either as a native complex eltype or as an `(r,i)` / `(re,im)` NamedTuple; the
# fastMRI breast release instead stores real and imaginary parts as a trailing size-2 axis
# of a Float64 array.
function _fastmri_complex_kspace(raw::AbstractArray)
    eltype(raw) === ComplexF32 && return raw
    eltype(raw) <: Complex && return ComplexF32.(raw)
    if eltype(raw) <: NamedTuple
        fn = fieldnames(eltype(raw))
        re, im = if fn == (:r, :i)
            (:r, :i)
        elseif fn == (:re, :im)
            (:re, :im)
        else
            error("unexpected complex compound fields $(fn) in fastMRI-layout `kspace`")
        end
        return [ComplexF32(getfield(v, re), getfield(v, im)) for v in raw]
    end
    if eltype(raw) == Float64 && ndims(raw) == 5 && size(raw, 5) == 2
        # Breast data is saved as Float64 (slice, coil, kx, ky, 2). Convert to complex
        # and permute to match standard fastMRI (ky, kx, coil, slice).
        c = complex.(raw[:, :, :, :, 1], raw[:, :, :, :, 2])
        return permutedims(ComplexF32.(c), (4, 3, 2, 1))
    end
    return error("unexpected eltype $(eltype(raw)) for fastMRI-layout `kspace`")
end

# Open a fastMRI-layout file once and return its k-space plus the optional mask
# (`nothing` when absent) and ISMRMRD header XML (`""` when absent).
function _read_fastmri_layout(path::AbstractString)
    HDF5 = MRIFiles.HDF5
    return HDF5.h5open(path) do h
        haskey(h, "kspace") ||
            error("fastMRI-layout file $(path) has no `kspace` dataset (keys: $(keys(h)))")
        kspace = _fastmri_complex_kspace(read(h["kspace"]::HDF5.Dataset))
        mask = haskey(h, "mask") ? read(h["mask"]::HDF5.Dataset) : nothing
        header = haskey(h, "ismrmrd_header") ? String(read(h["ismrmrd_header"]::HDF5.Dataset)) : ""
        (kspace = kspace, mask = mask, header = header)
    end
end
