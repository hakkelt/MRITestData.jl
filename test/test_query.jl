@testitem "query (offline)" begin
    using MRITestData
    using MRITestData: _human_bytes

    all_of(f, xs) = all(f, xs)

    @testset "query across both sources" begin
        both = query(; offline = true)
        @test both isa Vector{DatasetEntry}
        # union of the two per-source catalogs
        n = length(list_datasets(MRIDATA; offline = true)) +
            length(list_datasets(OCMR_SOURCE; offline = true))
        @test length(both) == n
        @test any(e -> e.source === MRIDATA, both)
        @test any(e -> e.source === OCMR_SOURCE, both)
    end

    @testset "single source argument" begin
        only_ocmr = query(; sources = OCMR_SOURCE, offline = true)
        @test !isempty(only_ocmr)
        @test all_of(e -> e.source === OCMR_SOURCE, only_ocmr)
        # equivalent to list_datasets for one source
        @test length(only_ocmr) == length(list_datasets(OCMR_SOURCE; offline = true))
    end

    @testset "field filters (shared vocabulary with list_datasets)" begin
        knees = query(; sources = MRIDATA, anatomy = :knee, offline = true)
        @test all_of(e -> e.anatomy === :knee, knees)

        fs = query(; sources = OCMR_SOURCE, fully_sampled = true, offline = true)
        @test !isempty(fs)
        @test all_of(e -> e.fully_sampled === true, fs)

        # predicate + membership
        strong = query(; field_strength = f -> f !== nothing && f >= 3.0, offline = true)
        @test all_of(e -> e.field_strength >= 3.0, strong)
        mem = query(; sources = OCMR_SOURCE, field_strength = (1.5, 3.0), offline = true)
        @test all_of(e -> e.field_strength in (1.5, 3.0), mem)
    end

    @testset "extra-field filters" begin
        # OCMR decodes a `subject` extra field (volunteer/patient).
        withsub = filter(e -> haskey(e.extra, "subject"), list_datasets(OCMR_SOURCE; offline = true))
        if !isempty(withsub)
            want = withsub[1].extra["subject"]
            res = query(; sources = OCMR_SOURCE, subject = want, offline = true)
            @test !isempty(res)
            @test all_of(e -> get(e.extra, "subject", nothing) == want, res)
        end
        # a non-existent extra key matches nothing
        @test isempty(query(; nonexistent_key_xyz = "zzz", offline = true))
    end

    @testset "free-text search" begin
        # every OCMR entry's name contains "OCMR"
        @test !isempty(query(; sources = OCMR_SOURCE, text = "ocmr", offline = true))
        # case-insensitive, and a nonsense needle matches nothing
        @test isempty(query(; text = "definitely-not-a-dataset-zzz", offline = true))
        # regex needle
        @test !isempty(query(; sources = OCMR_SOURCE, text = r"OCMR"i, offline = true))
        # predicate needle
        ids = query(; text = e -> startswith(e.id, "fs_"), offline = true)
        @test all_of(e -> startswith(e.id, "fs_"), ids)
    end

    @testset "human-readable byte sizes (pure)" begin
        @test _human_bytes(0) == "0B"
        @test _human_bytes(1500) == "1.5KB"
        @test _human_bytes(1_372_000_000) == "1.3GB"
    end
end
