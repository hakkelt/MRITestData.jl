# End-to-end: ISMRMRD fixture -> MRIBase.AcquisitionData -> MRIReco reconstruction.
# Exercises the MRITestDataMRIRecoExt package extension.

@testitem "integration: fixture -> recon (MRIReco)" tags = [:mrireco] setup = [Fixtures] begin
    using MRITestData
    using MRIReco  # loads MRITestDataMRIRecoExt

    mktempdir() do tmp
        @testset "cartesian (direct)" begin
            f = write_cartesian_fixture(joinpath(tmp, "cart.h5"); nx = 16, ny = 16, ncoil = 2)
            img = recon(load_acq(f); reco = "direct")
            @test size(img)[1:2] == (16, 16)        # [x, y, z, echo, coil, rep]
        end

        @testset "radial (direct)" begin
            f = write_radial_fixture(joinpath(tmp, "radial.h5"); nspokes = 24, nsamp = 32, ncoil = 2)
            img = recon(load_acq(f); reco = "direct")
            @test size(img)[1:2] == (32, 32)
        end

        @testset "path + entry forwarding" begin
            f = write_cartesian_fixture(joinpath(tmp, "cart2.h5"); nx = 16, ny = 16, ncoil = 2)
            @test size(recon(f; reco = "direct"))[1:2] == (16, 16)
        end
    end
end
