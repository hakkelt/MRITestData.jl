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
    k = nothing
    for key in ("kus", "kspace_full", "Recon_ks")
        if haskey(d, key)
            k = d[key]
            break
        end
    end

    if k !== nothing
        if haskey(d, "Calib")
            return k, d["Calib"]
        end
        return k, nothing
    end

    haskey(d, "Calib") && return d["Calib"], nothing

    arrs = [v for v in values(d) if v isa AbstractArray{<:Number}]
    length(arrs) == 1 && return only(arrs), nothing
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
function _cmrxrecon_cartesian_profiles(k, mb, nx, ny, nc, nz, nt, nmt; ky_offset::Int = 0, flags::UInt64 = UInt64(0), start_counter::UInt32 = UInt32(0))
    profiles = Profile[]
    counter = start_counter
    for t in 1:nt
        mt = nmt == 1 ? 1 : t
        kys = [ky for ky in 1:size(mb, 2) if any(@view mb[:, ky, mt])]
        for z in 1:nz, ky in kys
            counter += UInt32(1)
            data = ComplexF32.(@view k[:, ky, :, z, t])     # (nx, nc)
            head = _acquisition_header(;
                nx = nx, nc = nc, step = ky + ky_offset - 1,
                slice = z - 1, contrast = t - 1, counter = counter, flags = flags,
            )
            push!(profiles, Profile(head, Matrix{Float32}(undef, 0, 0), data))
        end
    end
    return profiles, counter
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
        calib_data::Union{AbstractArray, Nothing} = nothing,
    )
    k5 = _cmrxrecon_as5d(k)
    nx, ny, nc, nz, nt = size(k5)
    mb = _cmrxrecon_mask3(mask, nx, ny)
    nmt = size(mb, 3)
    (nmt == 1 || nmt == nt) || error("mask has $nmt frames, incompatible with k-space $nt frames")

    profiles, counter = _cmrxrecon_cartesian_profiles(k5, mb, nx, ny, nc, nz, nt, nmt)

    if calib_data !== nothing
        c5 = _cmrxrecon_as5d(calib_data)
        # The ACS calibration shares the readout and coil axes with the imaging k-space
        # but is its own (smaller) phase-encode region and may carry a different number of
        # slices/frames; drive the calib profiles from the calib array's own dimensions
        # (not the imaging array's) so a mismatched temporal/slice extent neither overruns
        # nor mislabels. Readout (nx) and channels (nc) must match for the profiles to
        # combine into one coherent acquisition.
        ncx, ncalib, ncc, ncz, nct = size(c5)
        (ncx == nx && ncc == nc) || error(
            "calibration array $(size(c5)) is incompatible with k-space $(size(k5)): " *
                "readout (nx) and channel (nc) dimensions must match",
        )
        # Centre the ACS lines within the full phase-encode extent of the imaging k-space.
        lo = div(ny, 2) - div(ncalib, 2) + 1
        calib_mb = _cmrxrecon_mask3(trues(ncx, ncalib), ncx, ncalib)
        c_profiles, _ = _cmrxrecon_cartesian_profiles(c5, calib_mb, ncx, ny, ncc, ncz, nct, 1; ky_offset = lo - 1, flags = MRIFiles.ACQ_IS_PARALLEL_CALIBRATION, start_counter = counter)
        append!(profiles, c_profiles)
    end

    fov = [
        fov_x !== nothing ? fov_x : Float64(nx),
        fov_y !== nothing ? fov_y : Float64(ny),
        Float64(nz),
    ]
    params = _ismrmrd_params(;
        nx = nx, ny = ny, nz = nz, nt = nt, nc = nc,
        enc_fov = fov, field_strength_T = field_strength_T,
    )
    return _write_ismrmrd(dest, params, profiles)
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

    d = load_mat(download_dataset(e))

    if haskey(e.extra, "calib_data_offset") && !haskey(d, "Calib")
        calib_e = DatasetEntry(;
            source = e.source,
            id = string(e.id, "_calib"),
            name = string(e.name, " (calibration)"),
            anatomy = e.anatomy,
            vendor = e.vendor,
            field_strength = e.field_strength,
            trajectory = e.trajectory,
            coils = e.coils,
            fully_sampled = true,
            is3D = e.is3D,
            approx_size_bytes = e.extra["calib_size"],
            url = e.url,
            extra = Dict{String, Any}(
                "path" => e.extra["calib_path"],
                "set" => e.extra["set"],
                "data_offset" => e.extra["calib_data_offset"],
                "size" => e.extra["calib_size"],
                "mat_file" => replace(e.extra["mat_file"], r"_ks\.mat$" => "_calib.mat")
            )
        )
        calib_d = load_mat(download_dataset(calib_e))
        if haskey(calib_d, "Calib")
            d["Calib"] = calib_d["Calib"]
        end
    end

    k, calib_data = _cmrxrecon_kspace(d)
    mask = derive_mask ? _cmrxrecon_sampling_mask(k) : trues(size(k, 1), size(k, 2))
    fov_x = get(e.extra, "fov_x", nothing)
    fov_y = get(e.extra, "fov_y", nothing)
    fs = something(e.field_strength, 3.0)
    return _cmrxrecon_to_ismrmrd(k, mask, dest; fov_x = fov_x, fov_y = fov_y, field_strength_T = fs, calib_data = calib_data)
end
