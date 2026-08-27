# Convert a fastMRI-layout `.h5` member into a cached Cartesian ISMRMRD `.h5`.
#
# fastMRI h5 layout (h5py / Python row-major, Julia reads axes reversed):
#   • `kspace`          — multicoil: on-disk (slice, coil, kx, ky) → Julia (ky, kx, coil, slice)
#                         singlecoil: on-disk (slice, kx, ky)       → Julia (ky, kx, slice)
#   • `mask`            — 1-D Float32 (ky,), 0/1; marks acquired phase-encode lines.
#                         Present for test-split data (prospectively undersampled for the
#                         fastMRI challenge); absent for fully-sampled train/val data.
#   • `ismrmrd_header`  — ISMRMRD XML string with the scanner's encoding parameters.
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

function _fastmri_ismrmrd_path(e::DatasetEntry)
    dest = string(first(splitext(cache_path(e))), "__mrd.h5")
    isfile(dest) && return dest

    src = download_dataset(e)
    HDF5 = MRIFiles.HDF5

    mask_raw, xml_hdr = HDF5.h5open(src) do f
        m = haskey(f, "mask") ? read(f["mask"]::HDF5.Dataset) : nothing
        x = haskey(f, "ismrmrd_header") ? String(read(f["ismrmrd_header"]::HDF5.Dataset)) : nothing
        m, x
    end

    k = _fastmri_canonical_kspace(_m4raw_read_kspace(src))  # (nx, ny, nc, nz, nt=1)
    nx, ny, nc, nz, nt = size(k)

    hdr = xml_hdr !== nothing ? _fastmri_parse_header(xml_hdr) : nothing

    # Encoding limits from scanner header; fall back to centered fully-sampled defaults.
    lim_ctr = something(hdr !== nothing ? hdr.lim_ctr : nothing, div(ny, 2))
    lim_min = something(hdr !== nothing ? hdr.lim_min : nothing, 0)
    lim_max = something(hdr !== nothing ? hdr.lim_max : nothing, ny - 1)

    # Offset: DC is at 0-indexed h5 ky position (ny÷2), mapped to kspace_encode_step_1 = lim_ctr.
    # step = (ky_0indexed) - offset  where  offset = (ny÷2) - lim_ctr.
    offset = div(ny, 2) - lim_ctr

    # Acquired ky positions (1-indexed) from h5 mask, or from non-zero kspace rows.
    acq_ky = if mask_raw !== nothing && length(mask_raw) == ny
        findall(!iszero, mask_raw)
    else
        Int[ky for ky in 1:ny if any(!iszero, @view k[:, ky, :, :, :])]
    end

    enc_ny_val = something(hdr !== nothing ? hdr.enc_ny : nothing, ny)

    # FastMRI sometimes stores undersampled data densely (squeezed) in the HDF5 array.
    # If the encoded space is significantly larger than the number of stored lines,
    # assume the data is undersampled and scale the indices to span the encoded space.
    multiplier = max(1, round(Int, enc_ny_val / ny))
    # Safety check: only apply multiplier if it makes sense
    if multiplier > 1 && ny * multiplier > enc_ny_val
        multiplier = 1
    end

    # Discard positions outside the valid encoding range.
    valid_ky = filter(acq_ky) do ky
        step = (ky - 1) - offset
        lim_min <= step <= lim_max
    end

    # Build ISMRMRD profiles with correct kspace_encode_step_1 values.
    center = UInt16(div(nx, 2))
    profiles = Profile[]
    counter = UInt32(0)
    for t in 1:nt, z in 1:nz, ky in valid_ky
        base_step = (ky - 1) - offset
        step = base_step * multiplier
        counter += UInt32(1)
        data = ComplexF32.(@view k[:, ky, :, z, t])  # (nx, nc)
        is_radial = e.trajectory === :radial

        traj_mat = Matrix{Float32}(undef, 0, 0)
        if is_radial
            # Golden angle radial
            angle = (ky - 1) * 111.246f0 * pi / 180.0f0
            traj_mat = Matrix{Float32}(undef, 2, nx)
            for s in 1:nx
                # Position relative to center: s is 1-indexed, center is 0-indexed.
                # r goes from approx -0.5 to 0.5
                r = (s - 1 - center) / Float32(nx)
                traj_mat[1, s] = r * cos(angle)
                traj_mat[2, s] = r * sin(angle)
            end
        end

        head = AcquisitionHeader(;
            number_of_samples = UInt16(nx),
            available_channels = UInt16(nc),
            active_channels = UInt16(nc),
            center_sample = center,
            trajectory_dimensions = is_radial ? UInt16(2) : UInt16(0),
            sample_time_us = is_radial ? 1.0f0 : 0.0f0,
            read_dir = (1.0f0, 0.0f0, 0.0f0),
            phase_dir = (0.0f0, 1.0f0, 0.0f0),
            slice_dir = (0.0f0, 0.0f0, 1.0f0),
            scan_counter = counter,
            idx = EncodingCounters(;
                kspace_encode_step_1 = UInt16(step),
                kspace_encode_step_2 = UInt16(0),
                slice = UInt16(z - 1),
                contrast = UInt16(t - 1),
                repetition = UInt16(0),
            ),
        )
        push!(profiles, Profile(head, traj_mat, data))
    end

    # FOV and recon matrix from scanner header; fall back to kspace dimensions.
    enc_nx = something(hdr !== nothing ? hdr.enc_nx : nothing, nx)
    enc_ny = something(hdr !== nothing ? hdr.enc_ny : nothing, ny)
    recon_nx = something(hdr !== nothing ? hdr.recon_nx : nothing, enc_nx)
    recon_ny = something(hdr !== nothing ? hdr.recon_ny : nothing, enc_ny)

    if e.trajectory === :radial
        # Radial datasets span a circle, so the encoded and recon spaces must be square
        # to prevent squishing the image (e.g. Breast has nx=640 samples, ny=288 spokes,
        # but the FOV should be 640x640).
        enc_ny = enc_nx
        recon_ny = recon_nx
    end

    enc_fov_x = something(hdr !== nothing ? hdr.enc_fov_x : nothing, Float64(nx))
    enc_fov_y = something(hdr !== nothing ? hdr.enc_fov_y : nothing, Float64(ny))
    recon_fov_x = something(hdr !== nothing ? hdr.recon_fov_x : nothing, enc_fov_x)
    recon_fov_y = something(hdr !== nothing ? hdr.recon_fov_y : nothing, enc_fov_y)
    fs = Float64(something(e.field_strength, 1.5f0))

    params = Dict{String, Any}(
        "trajectory" => string(e.trajectory),
        "encodedSize" => [enc_nx, enc_ny, nz],
        "reconSize" => [recon_nx, recon_ny, nz],
        "encodedFOV" => [enc_fov_x, enc_fov_y, Float64(nz)],
        "reconFOV" => [recon_fov_x, recon_fov_y, Float64(nz)],
        "receiverChannels" => nc,
        "systemVendor" => "Siemens",
        "systemFieldStrength_T" => Float32(fs),
        "H1resonanceFrequency_Hz" => 123_200_000,
        "enc_lim_kspace_encoding_step_1" =>
            MRIFiles.Limit(lim_min * multiplier, lim_max * multiplier, lim_ctr * multiplier),
        "enc_lim_kspace_encoding_step_2" => MRIFiles.Limit(0, 0, 0),
        "enc_lim_slice" => MRIFiles.Limit(0, nz - 1, div(nz - 1, 2)),
        "enc_lim_contrast" => MRIFiles.Limit(0, nt - 1, div(nt - 1, 2)),
    )

    mkpath(dirname(dest))
    tmp = dest * ".part"
    try
        save(ISMRMRDFile(tmp), RawAcquisitionData(params, profiles))
        mv(tmp, dest; force = true)
    catch
        isfile(tmp) && rm(tmp; force = true)
        rethrow()
    end
    return dest
end
