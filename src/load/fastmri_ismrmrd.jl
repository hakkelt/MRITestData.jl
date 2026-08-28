# Convert a fastMRI-layout `.h5` member into a cached Cartesian ISMRMRD `.h5`. The file is
# read by `_read_fastmri_layout` (src/load/fastmri_layout.jl); the axis orders it leaves
# alone are (h5py / Python row-major, so Julia reads them reversed):
#   • `kspace`          — multicoil: on-disk (slice, coil, kx, ky) → Julia (ky, kx, coil, slice)
#                         singlecoil: on-disk (slice, kx, ky)       → Julia (ky, kx, slice)
#   • `mask`            — 1-D Float32 (ky,), 0/1; marks acquired phase-encode lines.
#                         Present for test-split data (prospectively undersampled for the
#                         fastMRI challenge); absent for fully-sampled train/val data.
#
# Conversion:
#   1. Read kspace, mask (if any), and ISMRMRD header from the h5 file.
#   2. Parse encodedSpace, reconSpace, FOVs, and kspace_encoding_step_1 limits from the
#      embedded XML header.  These give the correct enc_lim center and the true reconSize
#      (fastMRI brain: reconSize y=408 vs encodedSize y=213; knee: 320×320 vs 640×322).
#   3. Compute the offset: 0-indexed h5 ky position of DC minus enc_lim_center.
#      Assign kspace_encode_step_1 = (ky_0indexed) - offset.
#   4. Include profiles only for ky positions where mask[ky] = 1 (or non-zero energy when
#      no mask field is present).  Discard positions outside [lim_min, lim_max].
#   5. Write ISMRMRD with correct params from the scanner header.

# Parse key acquisition parameters from the ISMRMRD XML header embedded in fastMRI h5 files.
function _fastmri_parse_header(xml::AbstractString)
    function _mat(s)
        m = match(r"<matrixSize>\s*<x>(\d+)</x>\s*<y>(\d+)</y>"s, s)
        m === nothing && return nothing, nothing
        return parse(Int, m.captures[1]), parse(Int, m.captures[2])
    end
    function _fov(s)
        m = match(r"<fieldOfView_mm>\s*<x>([\d.]+)</x>\s*<y>([\d.]+)</y>"s, s)
        m === nothing && return nothing, nothing
        return parse(Float64, m.captures[1]), parse(Float64, m.captures[2])
    end
    function _lim(xml, tag)
        m = match(
            Regex("<$tag>.*?<minimum>(\\d+)</minimum>.*?<maximum>(\\d+)</maximum>.*?<center>(\\d+)</center>", "s"),
            xml,
        )
        m === nothing && return nothing, nothing, nothing
        return parse(Int, m.captures[1]), parse(Int, m.captures[2]), parse(Int, m.captures[3])
    end

    enc_m = match(r"<encodedSpace>(.*?)</encodedSpace>"s, xml)
    recon_m = match(r"<reconSpace>(.*?)</reconSpace>"s, xml)

    enc_nx, enc_ny = enc_m !== nothing ? _mat(enc_m.match) : (nothing, nothing)
    enc_fov_x, enc_fov_y = enc_m !== nothing ? _fov(enc_m.match) : (nothing, nothing)
    recon_nx, recon_ny = recon_m !== nothing ? _mat(recon_m.match) : (nothing, nothing)
    recon_fov_x, recon_fov_y = recon_m !== nothing ? _fov(recon_m.match) : (nothing, nothing)
    lim_min, lim_max, lim_ctr = _lim(xml, "kspace_encoding_step_1")

    return (
        enc_nx = enc_nx, enc_ny = enc_ny,
        enc_fov_x = enc_fov_x, enc_fov_y = enc_fov_y,
        recon_nx = recon_nx, recon_ny = recon_ny,
        recon_fov_x = recon_fov_x, recon_fov_y = recon_fov_y,
        lim_min = lim_min, lim_max = lim_max, lim_ctr = lim_ctr,
    )
end

# Permute HDF5-read kspace into canonical (nx=kx, ny=ky, nc, nz, nt=1).
# h5py on-disk: multicoil (slice, coil, kx, ky) → Julia (ky, kx, coil, slice) — 4-D.
#               singlecoil (slice, kx, ky)       → Julia (ky, kx, slice)       — 3-D.
function _fastmri_canonical_kspace(a::AbstractArray)
    if ndims(a) == 4
        p = permutedims(a, (2, 1, 3, 4))   # (kx, ky, coil, slice)
        nx, ny, nc, nz = size(p)
        return reshape(p, nx, ny, nc, nz, 1)
    elseif ndims(a) == 3
        p = permutedims(a, (2, 1, 3))       # (kx, ky, slice); insert nc=1
        nx, ny, nz = size(p)
        return reshape(p, nx, ny, 1, nz, 1)
    elseif ndims(a) == 5
        # Prostate data: (kx, ky, coil, slice, averages).
        # Averages are interleaved shots. Sum them to get the full k-space contrast.
        p = sum(a, dims = 5)
        p = permutedims(p, (2, 1, 3, 4, 5)) # (kx, ky, coil, slice, 1)
        return p
    else
        error("expected 3-D (singlecoil), 4-D (multicoil), or 5-D (prostate) fastMRI kspace, got $(ndims(a))-D")
    end
end

# The breast release ships radial spokes without a stored trajectory, so the acquisition's
# own golden-angle scheme is reconstructed here: spoke `ky` (1-indexed) is rotated by
# `(ky - 1) * 111.246°` and sampled uniformly from -0.5 to 0.5 across the readout. This
# synthesises k-space coordinates the file omits — it is part of the acquisition, not a
# reconstruction step.
function _fastmri_radial_spoke(ky::Int, nx::Int, center::Int)
    angle = (ky - 1) * 111.246f0 * pi / 180.0f0
    sa, ca = sincos(angle)
    traj = Matrix{Float32}(undef, 2, nx)
    for s in 1:nx
        # Position relative to center: s is 1-indexed, center is 0-indexed, so r runs from
        # approximately -0.5 to 0.5.
        r = (s - 1 - center) / Float32(nx)
        traj[1, s] = r * ca
        traj[2, s] = r * sa
    end
    return traj
end

function _fastmri_ismrmrd_path(e::DatasetEntry)
    dest = string(first(splitext(cache_path(e))), "__mrd.h5")
    isfile(dest) && return dest

    raw = _read_fastmri_layout(download_dataset(e))
    mask_raw = raw.mask

    k = _fastmri_canonical_kspace(raw.kspace)  # (nx, ny, nc, nz, nt=1)
    nx, ny, nc, nz, nt = size(k)

    # Always returns a NamedTuple; every field is `nothing` when the header is absent or
    # a sub-pattern does not match, so call sites just `something(hdr.x, default)`.
    hdr = _fastmri_parse_header(raw.header)

    # Encoding limits from scanner header; fall back to centered fully-sampled defaults.
    lim_ctr = something(hdr.lim_ctr, div(ny, 2))
    lim_min = something(hdr.lim_min, 0)
    lim_max = something(hdr.lim_max, ny - 1)

    # Offset: DC is at 0-indexed h5 ky position (ny÷2), mapped to kspace_encode_step_1 = lim_ctr.
    # step = (ky_0indexed) - offset  where  offset = (ny÷2) - lim_ctr.
    offset = div(ny, 2) - lim_ctr

    # Acquired ky positions (1-indexed) from h5 mask, or from non-zero kspace rows.
    acq_ky = if mask_raw !== nothing && length(mask_raw) == ny
        findall(!iszero, mask_raw)
    else
        Int[ky for ky in 1:ny if any(!iszero, @view k[:, ky, :, :, :])]
    end

    enc_ny_val = something(hdr.enc_ny, ny)

    # FastMRI sometimes stores undersampled data densely (squeezed) in the HDF5 array. If
    # the encoded space is a whole multiple of the stored line count, scale the step indices
    # back onto the encoded grid — but only while the scaled extent still fits inside it.
    multiplier = max(1, round(Int, enc_ny_val / ny))
    multiplier * ny > enc_ny_val && (multiplier = 1)

    # Discard positions outside the valid encoding range.
    valid_ky = filter(acq_ky) do ky
        step = (ky - 1) - offset
        lim_min <= step <= lim_max
    end

    # Build ISMRMRD profiles with correct kspace_encode_step_1 values.
    is_radial = e.trajectory === :radial
    center = div(nx, 2)
    profiles = Profile[]
    counter = UInt32(0)
    for t in 1:nt, z in 1:nz, ky in valid_ky
        counter += UInt32(1)
        data = ComplexF32.(@view k[:, ky, :, z, t])  # (nx, nc)
        traj_mat = is_radial ? _fastmri_radial_spoke(ky, nx, center) : Matrix{Float32}(undef, 0, 0)
        head = _acquisition_header(;
            nx = nx, nc = nc, step = ((ky - 1) - offset) * multiplier,
            slice = z - 1, contrast = t - 1, counter = counter,
            traj_dims = is_radial ? 2 : 0,
            sample_time_us = is_radial ? 1.0f0 : 0.0f0,
        )
        push!(profiles, Profile(head, traj_mat, data))
    end

    # FOV and recon matrix from scanner header; fall back to kspace dimensions.
    enc_nx = something(hdr.enc_nx, nx)
    enc_ny = something(hdr.enc_ny, ny)
    recon_nx = something(hdr.recon_nx, enc_nx)
    recon_ny = something(hdr.recon_ny, enc_ny)

    if e.trajectory === :radial
        # Radial datasets span a circle, so the encoded and recon spaces must be square
        # to prevent squishing the image (e.g. Breast has nx=640 samples, ny=288 spokes,
        # but the FOV should be 640x640).
        enc_ny = enc_nx
        recon_ny = recon_nx
    end

    enc_fov_x = something(hdr.enc_fov_x, Float64(nx))
    enc_fov_y = something(hdr.enc_fov_y, Float64(ny))
    recon_fov_x = something(hdr.recon_fov_x, enc_fov_x)
    recon_fov_y = something(hdr.recon_fov_y, enc_fov_y)
    params = _ismrmrd_params(;
        nx = nx, ny = ny, nz = nz, nt = nt, nc = nc,
        trajectory = string(e.trajectory),
        enc_size = [enc_nx, enc_ny, nz],
        recon_size = [recon_nx, recon_ny, nz],
        enc_fov = [enc_fov_x, enc_fov_y, Float64(nz)],
        recon_fov = [recon_fov_x, recon_fov_y, Float64(nz)],
        field_strength_T = Float64(something(e.field_strength, 1.5f0)),
        enc_lim_1 = MRIFiles.Limit(lim_min * multiplier, lim_max * multiplier, lim_ctr * multiplier),
        slice_center = div(nz - 1, 2),
        contrast_center = div(nt - 1, 2),
    )
    return _write_ismrmrd(dest, params, profiles)
end
