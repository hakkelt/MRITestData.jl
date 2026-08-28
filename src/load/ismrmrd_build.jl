# Shared ISMRMRD assembly for the sources that ship raw k-space arrays rather than complete
# ISMRMRD files (CMRxRecon2024/-300, M4Raw, fastMRI). Each source derives its own profile
# list — sampling patterns, phase-encode numbering and trajectories differ — but the
# acquisition headers, the parameter dictionary and the atomic write are identical.

# One whole-readout acquisition header. `step` is the 0-based `kspace_encode_step_1`;
# `slice` and `contrast` are 0-based too. `traj_dims` is 0 for Cartesian data (no per-profile
# trajectory matrix).
function _acquisition_header(;
        nx::Int, nc::Int, step::Integer, slice::Integer, contrast::Integer,
        counter::UInt32, traj_dims::Int = 0, sample_time_us::Float32 = 0.0f0,
        flags::UInt64 = UInt64(0),
    )
    return AcquisitionHeader(;
        number_of_samples = UInt16(nx),
        available_channels = UInt16(nc),
        active_channels = UInt16(nc),
        center_sample = UInt16(div(nx, 2)),
        trajectory_dimensions = UInt16(traj_dims),
        sample_time_us = sample_time_us,
        read_dir = (1.0f0, 0.0f0, 0.0f0),
        phase_dir = (0.0f0, 1.0f0, 0.0f0),
        slice_dir = (0.0f0, 0.0f0, 1.0f0),
        scan_counter = counter,
        idx = EncodingCounters(;
            kspace_encode_step_1 = UInt16(step),
            kspace_encode_step_2 = UInt16(0),
            slice = UInt16(slice),
            contrast = UInt16(contrast),
            repetition = UInt16(0),
        ),
        flags = flags,
    )
end

"""
    _ismrmrd_params(; nx, ny, nz, nt, nc, kwargs...) -> Dict{String,Any}

Build the `RawAcquisitionData` parameter dictionary from the k-space dimensions.
`enc_size`/`recon_size` default to the k-space matrix and the FOVs to the matrix size (a
placeholder for sources that carry no geometry); sources that parse a scanner header pass
the real values. `enc_lim_1` defaults to the full centred phase-encode extent, and the
slice/contrast limit centres are overridable because the conventions differ per source.
"""
function _ismrmrd_params(;
        nx::Int, ny::Int, nz::Int, nt::Int, nc::Int,
        trajectory::AbstractString = "cartesian",
        enc_size::Vector{Int} = [nx, ny, nz],
        recon_size::Vector{Int} = enc_size,
        enc_fov::Vector{Float64} = [Float64(nx), Float64(ny), Float64(nz)],
        recon_fov::Vector{Float64} = enc_fov,
        field_strength_T::Float64 = 3.0,
        enc_lim_1::MRIFiles.Limit = MRIFiles.Limit(0, ny - 1, div(ny, 2)),
        slice_center::Int = div(nz, 2),
        contrast_center::Int = div(nt, 2),
    )
    return Dict{String, Any}(
        "trajectory" => String(trajectory),
        "encodedSize" => enc_size,
        "reconSize" => recon_size,
        "encodedFOV" => enc_fov,
        "reconFOV" => recon_fov,
        "receiverChannels" => nc,
        "systemVendor" => "Siemens",
        "systemFieldStrength_T" => Float32(field_strength_T),
        "H1resonanceFrequency_Hz" => 123_200_000,
        "enc_lim_kspace_encoding_step_1" => enc_lim_1,
        "enc_lim_kspace_encoding_step_2" => MRIFiles.Limit(0, 0, 0),
        "enc_lim_slice" => MRIFiles.Limit(0, nz - 1, slice_center),
        "enc_lim_contrast" => MRIFiles.Limit(0, nt - 1, contrast_center),
    )
end

# Write `params` + `profiles` to `dest` atomically (via `<dest>.part`), so an interrupted
# conversion never leaves a half-written file in the cache.
function _write_ismrmrd(dest::AbstractString, params::Dict{String, Any}, profiles::Vector{Profile})
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
