# Convert an M4Raw fastMRI-layout `.h5` member into a valid Cartesian ISMRMRD `.h5`, so
# M4Raw entries flow through the same `load_raw` pipeline as every other source. Each
# downloaded member holds three HDF5 datasets (fastMRI convention):
#   • `kspace`             — complex k-space, on-disk shape (slices, coils, freq, phase)
#   • `reconstruction_rss` — per-repetition RSS magnitude image (ground truth; unused here)
#   • `ismrmrd_header`     — an ISMRMRD XML header string
# The data is fully-sampled Cartesian (one repetition per file), so we reuse the
# CMRxRecon Cartesian builder (`_cmrxrecon_to_ismrmrd`) with an all-true mask.
#
# Note on axes: HDF5.jl reads an h5py-written array with its dimensions *reversed* (Julia
# is column-major), so the on-disk (slices, coils, freq, phase) arrives as Julia
# (phase, freq, coils, slices). We permute it to the canonical (nx=freq, ny=phase,
# nc=coils, nz=slices) the builder expects, then add a singleton temporal axis.

# Read the `kspace` dataset as a ComplexF32 array, normalising the various ways HDF5 may
# surface an h5py complex compound (native complex, or an (r,i)/(re,im) NamedTuple).
function _m4raw_read_kspace(path::AbstractString)
    HDF5 = MRIFiles.HDF5
    raw = HDF5.h5open(path) do h
        haskey(h, "kspace") || error("M4Raw file $(path) has no `kspace` dataset (keys: $(keys(h)))")
        read(h["kspace"]::HDF5.Dataset)
    end
    eltype(raw) <: Complex && return ComplexF32.(raw)
    if eltype(raw) <: NamedTuple
        fn = fieldnames(eltype(raw))
        re, im = if fn == (:r, :i)
            (:r, :i)
        elseif fn == (:re, :im)
            (:re, :im)
        else
            error("unexpected complex compound fields $(fn) in M4Raw `kspace`")
        end
        return [ComplexF32(getfield(v, re), getfield(v, im)) for v in raw]
    end
    return error("unexpected eltype $(eltype(raw)) for M4Raw `kspace`")
end

# Permute the HDF5-read kspace (phase, freq, coils, slices) into the canonical
# (nx=freq, ny=phase, nc=coils, nz=slices, nt=1) the Cartesian builder expects.
function _m4raw_canonical_kspace(a::AbstractArray)
    ndims(a) == 4 || error("expected 4-D M4Raw kspace (phase, freq, coils, slices), got $(ndims(a))-D")
    p = permutedims(a, (2, 1, 3, 4))     # (freq, phase, coils, slices)
    nx, ny, nc, nz = size(p)
    return reshape(p, nx, ny, nc, nz, 1)
end

# Resolve (building + caching if needed) the ISMRMRD `.h5` for an M4Raw entry. The
# converted file lives next to the downloaded fastMRI file (same name, `__mrd.h5` suffix,
# so it is distinct from the source — which is itself `.h5`).
function _m4raw_ismrmrd_path(e::DatasetEntry)
    dest = string(first(splitext(cache_path(e))), "__mrd.h5")
    isfile(dest) && return dest

    src = download_dataset(e)
    k = _m4raw_canonical_kspace(_m4raw_read_kspace(src))
    mask = trues(size(k, 1), size(k, 2))
    fs = something(e.field_strength, 0.3)
    return _cmrxrecon_to_ismrmrd(k, mask, dest; field_strength_T = fs)
end
