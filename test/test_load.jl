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

@testitem "load: a missing dwell time is recovered from the header" setup = [Fixtures] begin
    using MRITestData
    using MRIBase: trajectory

    # The USC Speech exporter's spelling and (wrong) unit suffixes: both values are
    # microseconds, so 64 µs over 32 samples is a 2 µs dwell time.
    usc_description() = Dict{String, Any}(
        "identifier" => "HargreavesVDS2000",
        "readTime_ns" => 64,
        "simplingTime_ns" => 2,
    )

    mktempdir() do tmp
        @testset "filled in from the readout duration" begin
            f = write_radial_fixture(
                joinpath(tmp, "zero_dwell.h5"); nsamp = 32,
                sample_time_us = 0, trajectory_description = usc_description()
            )
            raw = load_raw(f)

            @test all(p -> p.head.sample_time_us == 2.0f0, raw.profiles)
            # The point of the repair: a zero dwell time makes this throw
            # `ArgumentError: range step cannot be zero`.
            tr = trajectory(raw)
            @test maximum(tr.times) ≈ 31 * 2.0e-6
        end

        @testset "the sampling interval alone is enough" begin
            desc = usc_description()
            delete!(desc, "readTime_ns")
            f = write_radial_fixture(
                joinpath(tmp, "sampling_only.h5"); nsamp = 32,
                sample_time_us = 0, trajectory_description = desc
            )
            @test all(p -> p.head.sample_time_us == 2.0f0, load_raw(f).profiles)
        end

        @testset "an implausible dwell time is rejected" begin
            # 32 samples in 0.001 µs would be a 32 GHz receiver: the header is unreadable,
            # not repairable, so the zeros stay and the caller is warned.
            f = write_radial_fixture(
                joinpath(tmp, "implausible.h5"); nsamp = 32, sample_time_us = 0,
                trajectory_description = Dict{String, Any}("identifier" => "x", "readTime_us" => 0.001)
            )
            raw = @test_logs (:warn, r"records no dwell time") load_raw(f)
            @test all(p -> iszero(p.head.sample_time_us), raw.profiles)
        end

        @testset "no description: the zeros stay, and Cartesian data is left silent" begin
            f = write_radial_fixture(joinpath(tmp, "no_desc.h5"); sample_time_us = 0)
            raw = @test_logs (:warn, r"records no dwell time") load_raw(f)
            @test all(p -> iszero(p.head.sample_time_us), raw.profiles)

            # The Cartesian branch of `MRIBase.trajectory` ignores the sample times, so a
            # zero dwell time there is harmless and must not warn.
            c = write_cartesian_fixture(joinpath(tmp, "cart_zero_dwell.h5"))
            raw = load_raw(c)
            for p in raw.profiles
                p.head.sample_time_us = 0.0f0
            end
            @test_logs MRITestData._fix_zero_sample_time!(raw)
        end

        @testset "an existing dwell time is left alone" begin
            f = write_radial_fixture(
                joinpath(tmp, "has_dwell.h5"); nsamp = 32,
                sample_time_us = 5, trajectory_description = usc_description()
            )
            @test all(p -> p.head.sample_time_us == 5.0f0, load_raw(f).profiles)
        end
    end
end
