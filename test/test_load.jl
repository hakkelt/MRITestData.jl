@testitem "load: load_raw round-trips ISMRMRD" setup = [Fixtures] begin
    using MRITestData
    using MRIBase: RawAcquisitionData

    # Sorted unique phase-encode (ky) indices present across all profiles (1-based).
    acquired_ky(raw) = sort(unique(Int(p.head.idx.kspace_encode_step_1) + 1 for p in raw.profiles))

    mktempdir() do tmp
        @testset "cartesian (fully sampled)" begin
            f = write_cartesian_fixture(joinpath(tmp, "cart_full.h5"); nx = 16, ny = 16, ncoil = 2)
            raw = load_raw(f)

            @test raw isa RawAcquisitionData
            @test lowercase(get(raw.params, "trajectory", "")) == "cartesian"
            @test !isempty(raw.profiles)
            # data is (samples × channels)
            @test size(raw.profiles[1].data, 2) == 2
            # fully sampled -> every ky line acquired
            @test acquired_ky(raw) == collect(1:16)
        end

        @testset "cartesian (undersampled)" begin
            f = write_cartesian_fixture(joinpath(tmp, "cart_us.h5"); nx = 16, ny = 16, ncoil = 2, accel = 2)
            raw = load_raw(f)

            ky = acquired_ky(raw)
            # accel = 2 -> only half the lines carry data
            @test length(ky) < 16
            @test all(isodd, ky)        # the fixture fills ky = 1:accel:ny
        end

        @testset "radial (non-cartesian)" begin
            f = write_radial_fixture(joinpath(tmp, "radial.h5"); nspokes = 16, nsamp = 32, ncoil = 2)
            raw = load_raw(f)

            @test !isempty(raw.profiles)
            # per-profile trajectory coordinates are recorded (2D radial)
            @test Int(raw.profiles[1].head.trajectory_dimensions) == 2
            @test size(raw.profiles[1].data, 2) == 2
        end

        @testset "load_raw from a DatasetEntry path and with filters" begin
            f = write_cartesian_fixture(joinpath(tmp, "cart2.h5"))
            @test load_raw(f) isa RawAcquisitionData
            @test load_raw(f; slice = 1) isa RawAcquisitionData
        end
    end
end
