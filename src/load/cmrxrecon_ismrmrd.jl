# Convert CMRxRecon2024 MATLAB k-space (+ undersampling mask) into a valid ISMRMRD
# `.h5` file, so CMRxRecon entries flow through the same `load_raw` pipeline as every
# other source. The raw `.mat` files hold a k-space array (`kus` for undersampled,
# `kspace_full` for FullSample) shaped (nx,ny,nc,nz,nt) (4D, no nt, for BlackBlood);
# the undersampling pattern lives in a *separate* mask file (variable `mask`, 2D
# (nx,ny) for Task1, 3D (nx,ny,nt) for Task2) that we pair by filename. See docs/src
# and CLAUDE.md.
#
# All CMRxRecon2024 data is Cartesian k-space — the Uniform/ktUniform/ktGaussian and
# (pseudo-)ktRadial labels are *sampling masks*, not non-Cartesian trajectories. We
# store every acquisition as a Cartesian ISMRMRD: one profile per acquired phase-encode
# line (frame → contrast, slice → slice). A line counts as acquired if the mask selects
# any sample in it; the readout itself carries the `kus` values (already zero-filled at
# unsampled points).

# ── Reading the .mat arrays ─────────────────────────────────────────────────────

function _cmrxrecon_kspace(d::AbstractDict)
    for k in ("kus", "kspace_full", "Recon_ks", "Calib")
        haskey(d, k) && return d[k]
    end
    arrs = [v for v in values(d) if v isa AbstractArray{<:Number}]
    length(arrs) == 1 && return only(arrs)
    return error("could not identify the k-space variable in the .mat file (keys = $(collect(keys(d))))")
end

# Reshape to a canonical 5D (nx,ny,nc,nz,nt); BlackBlood is 4D (no temporal axis).
function _cmrxrecon_as5d(k::AbstractArray)
    nd = ndims(k)
    nd == 5 && return k
    nd == 4 && return reshape(k, size(k, 1), size(k, 2), size(k, 3), size(k, 4), 1)
    return error("expected 4D or 5D CMRxRecon k-space, got $(nd)D")
end

# Normalise the mask to a Bool (nx,ny,nmt) array (nmt ∈ {1, nt}).
function _cmrxrecon_mask3(mask::AbstractArray, nx::Int, ny::Int)
    mb = mask .!= 0
    if ndims(mb) == 2
        size(mb) == (nx, ny) || error("mask size $(size(mb)) does not match k-space ($nx, $ny)")
        return reshape(mb, nx, ny, 1)
    elseif ndims(mb) == 3
        (size(mb, 1) == nx && size(mb, 2) == ny) || error("mask size $(size(mb)) does not match k-space ($nx, $ny)")
        return mb
    end
    return error("mask must be 2D or 3D, got $(ndims(mb))D")
end

# ── Profile builder ─────────────────────────────────────────────────────────────

# Cartesian: one whole-line profile per acquired (frame → contrast, slice, ky). A line
# is acquired if the mask selects any sample in it. Real slice/contrast indices (MRIBase
# handles multi-slice Cartesian); repetition stays 0.
function _cmrxrecon_cartesian_profiles(k, mb, nx, ny, nc, nz, nt, nmt)
    center = UInt16(div(nx, 2))
    profiles = Profile[]
    counter = UInt32(0)
    for t in 1:nt
        mt = nmt == 1 ? 1 : t
        kys = [ky for ky in 1:ny if any(@view mb[:, ky, mt])]
        for z in 1:nz, ky in kys
            counter += UInt32(1)
            data = ComplexF32.(@view k[:, ky, :, z, t])     # (nx, nc)
            head = AcquisitionHeader(;
                number_of_samples = UInt16(nx),
                available_channels = UInt16(nc),
                active_channels = UInt16(nc),
                center_sample = center,
                trajectory_dimensions = UInt16(0),
                read_dir = (1.0f0, 0.0f0, 0.0f0),
                phase_dir = (0.0f0, 1.0f0, 0.0f0),
                slice_dir = (0.0f0, 0.0f0, 1.0f0),
                scan_counter = counter,
                idx = EncodingCounters(;
                    kspace_encode_step_1 = UInt16(ky - 1),
                    kspace_encode_step_2 = UInt16(0),
                    slice = UInt16(z - 1),
                    contrast = UInt16(t - 1),
                    repetition = UInt16(0),
                ),
            )
            push!(profiles, Profile(head, Matrix{Float32}(undef, 0, 0), data))
        end
    end
    return profiles
end

# ── Builder + orchestration ─────────────────────────────────────────────────────

"""
    _cmrxrecon_to_ismrmrd(k, mask, dest; fov_x, fov_y, field_strength_T) -> dest

Build a valid Cartesian ISMRMRD `.h5` at `dest` from a CMRxRecon2024 k-space array `k`
(`(nx,ny,nc,nz,nt)`, or 4D for BlackBlood) and its `mask`. FOV kwargs (mm) and
field_strength_T come from the info-CSV annotation; when absent the matrix size is used
as a FOV placeholder (encoding/recon size still reflect the true matrix dimensions).
"""
function _cmrxrecon_to_ismrmrd(
        k::AbstractArray,
        mask::AbstractArray,
        dest::AbstractString;
        fov_x::Union{Float64, Nothing} = nothing,
        fov_y::Union{Float64, Nothing} = nothing,
        field_strength_T::Float64 = 3.0,
    )
    k5 = _cmrxrecon_as5d(k)
    nx, ny, nc, nz, nt = size(k5)
    mb = _cmrxrecon_mask3(mask, nx, ny)
    nmt = size(mb, 3)
    (nmt == 1 || nmt == nt) || error("mask has $nmt frames, incompatible with k-space $nt frames")

    profiles = _cmrxrecon_cartesian_profiles(k5, mb, nx, ny, nc, nz, nt, nmt)

    enc_fov_x = fov_x !== nothing ? fov_x : Float64(nx)
    enc_fov_y = fov_y !== nothing ? fov_y : Float64(ny)
    params = Dict{String, Any}(
        "trajectory" => "cartesian",
        "encodedSize" => [nx, ny, nz],
        "reconSize" => [nx, ny, nz],
        "encodedFOV" => [enc_fov_x, enc_fov_y, Float64(nz)],
        "reconFOV" => [enc_fov_x, enc_fov_y, Float64(nz)],
        "receiverChannels" => nc,
        "systemVendor" => "Siemens",
        "systemFieldStrength_T" => Float32(field_strength_T),
        "H1resonanceFrequency_Hz" => 123_200_000,
    )

    mkpath(dirname(dest))
    tmp = dest * ".part"
    save(ISMRMRDFile(tmp), RawAcquisitionData(params, profiles))
    mv(tmp, dest; force = true)
    return dest
end

# Per-frame acquired-line mask derived from the data itself: a phase-encode line is
# "acquired" in a frame iff it carries any non-zero sample. CMRxRecon2024 FullSample data
# is genuinely fully sampled (every line non-zero → all-true mask), but CMRxRecon-300 `_ks`
# files are **undersampled** (regular k-t pattern, e.g. R≈3) zero-filled to the full matrix
# — deriving the mask from the zero pattern records the true sampling so the ISMRMRD is not
# mislabelled as fully sampled. Returns an (nx, ny, nt) Bool mask.
function _cmrxrecon_sampling_mask(k::AbstractArray)
    k5 = _cmrxrecon_as5d(k)
    nx, ny, _, _, nt = size(k5)
    mask = falses(nx, ny, nt)
    for t in 1:nt, ky in 1:ny
        any(!iszero, @view k5[:, ky, :, :, t]) && (@view(mask[:, ky, t]) .= true)
    end
    return mask
end

# Resolve (building + caching if needed) the ISMRMRD `.h5` for a CMRxRecon entry. The
# converted file lives next to the cached `.mat` (same name, `.h5` extension). When
# `derive_mask` is true the acquired-line mask is read from the data's zero pattern
# (CMRxRecon-300, which is undersampled); otherwise an all-true mask is used
# (CMRxRecon2024 FullSample, which is genuinely fully sampled).
function _cmrxrecon_ismrmrd_path(e::DatasetEntry; derive_mask::Bool = false)
    dest = string(first(splitext(cache_path(e))), ".h5")
    isfile(dest) && return dest
    k = _cmrxrecon_kspace(load_mat(download_dataset(e)))
    mask = derive_mask ? _cmrxrecon_sampling_mask(k) : trues(size(k, 1), size(k, 2))
    fov_x = get(e.extra, "fov_x", nothing)
    fov_y = get(e.extra, "fov_y", nothing)
    fs = something(e.field_strength, 3.0)
    return _cmrxrecon_to_ismrmrd(k, mask, dest; fov_x = fov_x, fov_y = fov_y, field_strength_T = fs)
end
