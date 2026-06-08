@testitem "load: acq_spec conversion" setup = [Fixtures] begin
    using MRITestData
    using NamedDims: dimnames, dim

    mktempdir() do tmp
        @testset "cartesian (fully sampled)" begin
            f = write_cartesian_fixture(joinpath(tmp, "cart_full.h5"); nx = 16, ny = 16, ncoil = 2)
            acq = load_acq(f)
            spec = acq_spec(acq)

            @test spec.kind === :cartesian
            @test spec.is3D === false
            @test spec.image_size == (16, 16)
            @test spec.coils == 2
            @test dimnames(spec.kspace_data) == (:kx, :ky, :coil, :z)
            @test size(spec.kspace_data, dim(spec.kspace_data, :coil)) == 2

            # fully sampled -> dense grid, no subsampling pattern
            @test spec.subsampling === nothing
        end

        @testset "cartesian (undersampled)" begin
            f = write_cartesian_fixture(joinpath(tmp, "cart_us.h5"); nx = 16, ny = 16, ncoil = 2, accel = 2)
            acq = load_acq(f)
            spec = acq_spec(acq)

            @test spec.kind === :cartesian
            # undersampled -> compressed samples + Bool mask tuple
            @test spec.subsampling isa Tuple{<:AbstractArray{Bool, 2}}
            mask = spec.subsampling[1]
            @test count(mask) < prod(spec.image_size)
            @test count(mask) == length(unique(acq.subsampleIndices[1]))
            # compressed spatial axis -> (:kxy, :coil, :z); kxy length == #samples
            @test dimnames(spec.kspace_data) == (:kxy, :coil, :z)
            @test size(spec.kspace_data, dim(spec.kspace_data, :kxy)) == count(mask)
        end

        @testset "radial (non-cartesian)" begin
            f = write_radial_fixture(joinpath(tmp, "radial.h5"); nspokes = 16, nsamp = 32, ncoil = 2)
            acq = load_acq(f)
            spec = acq_spec(acq)

            @test spec.kind === :noncartesian
            @test spec.dcf === nothing
            @test spec.coils == 2
            @test dimnames(spec.trajectory) == (:coord, :sample)
            @test dimnames(spec.kspace_data) == (:sample, :coil)

            # trajectory: 2 coords, normalized to [-0.5, 0.5)
            @test size(spec.trajectory, dim(spec.trajectory, :coord)) == 2
            @test maximum(abs, spec.trajectory) <= 0.5 + 1.0e-4

            # samples axis of k-space matches trajectory sample count
            nsamp = size(spec.trajectory, dim(spec.trajectory, :sample))
            @test size(spec.kspace_data, dim(spec.kspace_data, :sample)) == nsamp
        end

        @testset "acq_spec from path" begin
            f = write_cartesian_fixture(joinpath(tmp, "cart2.h5"))
            @test acq_spec(f).kind === :cartesian
        end
    end
end
