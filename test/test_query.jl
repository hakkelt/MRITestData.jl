@testitem "query (offline)" begin
    using MRITestData
    using MRITestData: _human_bytes

    all_of(f, xs) = all(f, xs)

    @testset "query across all sources" begin
        both = query(; offline = true)
        @test both isa Vector{DatasetEntry}
        # union of every per-source catalog
        n = sum(s -> length(list_datasets(s; offline = true)), list_sources())
        @test length(both) == n
        @test any(e -> e.source === MRIDATA, both)
        @test any(e -> e.source === OCMR_SOURCE, both)
        @test any(e -> e.source === CMRXRECON2024, both)
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
        # OCMR decodes cohort (volunteer/patient) as a core field, not `extra`.
        withcohort = filter(e -> e.cohort !== nothing, list_datasets(OCMR_SOURCE; offline = true))
        if !isempty(withcohort)
            want = withcohort[1].cohort
            res = query(; sources = OCMR_SOURCE, cohort = want, offline = true)
            @test !isempty(res)
            @test all_of(e -> e.cohort == want, res)
        end
        # OCMR's `extra["scanner_model"]` is a genuine extra key.
        withmodel = filter(e -> haskey(e.extra, "scanner_model"), list_datasets(OCMR_SOURCE; offline = true))
        if !isempty(withmodel)
            want = withmodel[1].extra["scanner_model"]
            res = query(; sources = OCMR_SOURCE, scanner_model = want, offline = true)
            @test !isempty(res)
            @test all_of(e -> get(e.extra, "scanner_model", nothing) == want, res)
        end
        # a non-existent extra key matches nothing (and warns — see the strict test below)
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
        # Binary prefixes: these sizes come from Content-Length / filesize and are
        # compared against on-disk footprints, so 1024-based units with IEC names.
        @test _human_bytes(0) == "0B"
        @test _human_bytes(1500) == "1.5KiB"
        @test _human_bytes(1_372_000_000) == "1.3GiB"
        @test _human_bytes(1024) == "1.0KiB"
    end
end

@testitem "query: unknown filter keyword validation" begin
    using MRITestData

    # The default just warns and treats the keyword as an always-empty extra filter.
    @test isempty(query(; sources = OCMR_SOURCE, definitely_not_a_field = "x", offline = true))
    # `strict = true` raises instead — catches a typo before it silently returns [].
    @test_throws ErrorException query(; sources = OCMR_SOURCE, definitely_not_a_field = "x", offline = true, strict = true)
    # A key in the source's extra_schema is never flagged, strict or not.
    @test extra_schema(OCMR_SOURCE) isa Dict{String, String}
    @test haskey(extra_schema(OCMR_SOURCE), "scanner_model")
end
