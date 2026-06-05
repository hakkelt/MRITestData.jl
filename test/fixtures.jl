# Shared test fixtures: synthesise tiny ISMRMRD .h5 files on disk (no network, no
# committed binaries). Built by constructing a synthetic MRIBase.AcquisitionData,
# converting to RawAcquisitionData, and saving via MRIFiles. Round-tripping through
# the real writer/reader exercises the same code path MRITestData uses on real files.
#
# Used by @testitems via `setup = [Fixtures]`.

@testmodule Fixtures begin

    using MRIBase
    using MRIFiles: ISMRMRDFile
    using FileIO: save

    export write_cartesian_fixture, write_radial_fixture

    # The MRIFiles ISMRMRD writer always emits x/y/z for matrixSize and fieldOfView,
    # so the params produced from a 2D AcquisitionData (length-2 vectors) must be
    # padded to length 3 before saving.
    function _pad_params_to_3d!(raw)
        for (k, fill) in (("encodedSize", 1), ("reconSize", 1), ("encodedFOV", 1.0), ("reconFOV", 1.0))
            if haskey(raw.params, k)
                v = raw.params[k]
                while length(v) < 3
                    push!(v, fill)
                end
            end
        end
        return raw
    end

    """
        write_cartesian_fixture(path; nx=16, ny=16, ncoil=2, accel=1) -> path

    Write a tiny 2D Cartesian ISMRMRD file. With `accel > 1`, only every `accel`-th
    phase-encode line carries data (the rest are zero), giving an undersampled set.
    """
    function write_cartesian_fixture(path; nx = 16, ny = 16, ncoil = 2, accel = 1)
        ksp = zeros(ComplexF32, nx, ny, 1, ncoil, 1, 1)  # [x, y, z, ch, echo, rep]
        for c in 1:ncoil, ky in 1:accel:ny, kx in 1:nx
            ksp[kx, ky, 1, c, 1, 1] = ComplexF32(kx + 0.5kx * im) * (ky + c)
        end
        acq = AcquisitionData(ksp; enc2D = true)
        raw = _pad_params_to_3d!(RawAcquisitionData(acq))
        save(ISMRMRDFile(path), raw)
        return path
    end

    """
        write_radial_fixture(path; nspokes=16, nsamp=32, ncoil=2) -> path

    Write a tiny 2D radial (non-Cartesian) ISMRMRD file.
    """
    function write_radial_fixture(path; nspokes = 16, nsamp = 32, ncoil = 2)
        tr = RadialTrajectory(Float32, nspokes, nsamp; TE = 0.0f0, AQ = 1.0f-3)
        npts = nspokes * nsamp
        kdata = Array{Matrix{ComplexF32}}(undef, 1, 1, 1)
        kdata[1, 1, 1] = ComplexF32.(reshape(1:(npts * ncoil), npts, ncoil)) ./ npts
        acq = AcquisitionData(tr, kdata; encodingSize = (nsamp, nsamp), fov = (200.0, 200.0, 1.0))
        raw = _pad_params_to_3d!(RawAcquisitionData(acq))
        save(ISMRMRDFile(path), raw)
        return path
    end

end # @testmodule Fixtures
