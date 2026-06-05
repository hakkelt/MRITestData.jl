# Opt-in integration with MriReconstructionToolbox (tag :mrt, skipped by default —
# that package does not precompile cleanly in a merged dev environment).
# Exercises the MRITestDataMRTExt extension: fixture -> AcquisitionInfo -> reconstruct.

@testitem "integration: fixture -> AcquisitionInfo -> reconstruct (MRT)" tags = [:mrt] setup = [Fixtures] begin
    using MRITestData
    using MriReconstructionToolbox: reconstruct, Tikhonov, AcquisitionInfo

    mktempdir() do tmp
        @testset "cartesian" begin
            f = write_cartesian_fixture(joinpath(tmp, "cart.h5"); nx = 16, ny = 16, ncoil = 2)
            acq = MRITestData.load(f)                       # CartesianAcquisitionInfo via ext
            @test acq isa AcquisitionInfo
            img = reconstruct(acq, Tikhonov(0.001); maxit = 3, verbose = false)
            @test size(img) == (16, 16)
        end

        @testset "radial" begin
            f = write_radial_fixture(joinpath(tmp, "radial.h5"); nspokes = 16, nsamp = 32, ncoil = 2)
            acq = MRITestData.load(f)                       # NonCartesianAcquisitionInfo via ext
            img = reconstruct(acq, Tikhonov(0.001); maxit = 3, verbose = false)
            @test size(img) == (32, 32)
        end
    end
end
