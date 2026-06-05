@testitem "catalog (offline)" begin
    using MRITestData

    all_of(f, xs) = all(f, xs)

    @testset "sources" begin
        srcs = list_sources()
        @test MRIDATA in srcs
        @test OCMR_SOURCE in srcs
    end

    @testset "mridata catalog + filtering" begin
        all = list_datasets(MRIDATA; offline = true)
        @test !isempty(all)
        @test all isa Vector{DatasetEntry}
        @test all[1].url == "https://mridata.org/download/$(all[1].id)"

        knees = list_datasets(MRIDATA; offline = true, anatomy = :knee)
        @test all_of(e -> e.anatomy === :knee, knees)

        # nothing filter is a no-op
        @test length(list_datasets(MRIDATA; offline = true, vendor = nothing)) == length(all)
    end

    @testset "ocmr catalog + filtering" begin
        all = list_datasets(OCMR_SOURCE; offline = true)
        @test !isempty(all)
        @test all_of(e -> e.anatomy === :cardiac, all)
        @test all_of(e -> startswith(e.url, "https://ocmr.s3.amazonaws.com/data/"), all)

        fs = list_datasets(OCMR_SOURCE; offline = true, fully_sampled = true)
        @test !isempty(fs)
        @test all_of(e -> e.fully_sampled === true, fs)
        # field strength + slices are derived from the file name / CSV
        @test all_of(e -> e.field_strength !== nothing, fs)

        us = list_datasets(OCMR_SOURCE; offline = true, fully_sampled = false)
        @test all_of(e -> e.fully_sampled === false, us)

        # membership filter
        @test all_of(e -> e.field_strength in (1.5, 3.0), list_datasets(OCMR_SOURCE; offline = true, field_strength = (1.5, 3.0)))
    end

    @testset "dataset lookup + synthesis" begin
        e = list_datasets(MRIDATA; offline = true)[1]
        @test dataset(MRIDATA, e.id; offline = true).entry.id == e.id

        # arbitrary UUID not in the index -> synthesised entry
        h = dataset(MRIDATA, "00000000-1111-2222-3333-444444444444"; offline = true)
        @test h.entry.url == "https://mridata.org/download/00000000-1111-2222-3333-444444444444"

        # OCMR synthesis derives field strength / fully-sampled from the stem
        ho = dataset(OCMR_SOURCE, "fs_9999_3T"; offline = true)
        @test endswith(ho.entry.url, "fs_9999_3T.h5")
        @test ho.entry.field_strength == 3.0
        @test ho.entry.fully_sampled === true
    end
end
