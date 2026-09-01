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

@testitem "query: string expression language — tokenizer/parser" begin
    using MRITestData: parse_query_expr, QueryParseError, QCmp, QAnd, QOr

    @testset "single comparison, every operator" begin
        for (txt, op) in
            [("a=1", :eq), ("a!=1", :neq), ("a<1", :lt), ("a<=1", :lte), ("a>1", :gt), ("a>=1", :gte)]
            node = parse_query_expr(txt)
            @test node isa QCmp
            @test node.field == "a"
            @test node.op == op
            @test node.value == 1.0
        end
    end

    @testset "AND binds tighter than OR; parens override" begin
        n = parse_query_expr("a=1 AND b=2 OR c=3")
        @test n isa QOr
        @test n.l isa QAnd
        n2 = parse_query_expr("a=1 AND (b=2 OR c=3)")
        @test n2 isa QAnd
        @test n2.r isa QOr
        # case-insensitive keywords, no spaces needed around operators
        n3 = parse_query_expr("a=1 and b<3")
        @test n3 isa QAnd
    end

    @testset "value forms" begin
        @test parse_query_expr("a='fs_*'").value == "fs_*"
        @test parse_query_expr("a=\"x y\"").value == "x y"
        @test parse_query_expr("a=bareword").value == "bareword"
        @test parse_query_expr("a=true").value === true
        @test parse_query_expr("a=false").value === false
        @test parse_query_expr("a=-1.5").value == -1.5
        # missing-value sentinel, however spelled
        for w in ("nothing", "null", "missing", "none", "NOTHING")
            @test parse_query_expr("a=$w").value === MRITestData._QMISSING
        end
    end

    @testset "size suffixes on numeric literals" begin
        @test parse_query_expr("size<100M").value == 100_000_000.0
        @test parse_query_expr("size<=2GiB").value == 2.0 * 1024^3
        @test parse_query_expr("size>500KB").value == 500_000.0
        @test parse_query_expr("size<1.5G").value == 1.5e9
        # a plain number is unchanged; a non-numeric word stays a bareword
        @test parse_query_expr("frames>10").value == 10.0
        @test parse_query_expr("anatomy=knee").value == "knee"
        # a lone trailing 'T' is ignored so field strength works; 'P' is not a suffix
        @test parse_query_expr("b0=3T").value == 3.0
        @test parse_query_expr("a=3P").value == "3P"
    end

    @testset "parse errors carry a usable message" begin
        @test_throws QueryParseError parse_query_expr("a=")
        @test_throws QueryParseError parse_query_expr("a=1 AND")
        @test_throws QueryParseError parse_query_expr("(a=1")
        @test_throws QueryParseError parse_query_expr("a='unterminated")
        @test_throws QueryParseError parse_query_expr("a 1")   # missing operator
        try
            parse_query_expr("a=")
        catch e
            @test e isa QueryParseError
            @test occursin("byte", sprint(showerror, e))
        end
    end
end

@testitem "query: string expression language — evaluation (offline)" begin
    using MRITestData

    @testset "field aliases match the browser's column headers" begin
        fastmri_r = query("dataset=fastmri AND R<3"; offline = true)
        @test !isempty(fastmri_r)
        @test all(e -> MRITestData.source_name(e.source) == "fastmri", fastmri_r)
        @test all(e -> e.acceleration !== nothing && e.acceleration < 3, fastmri_r)

        # keyword and string forms agree
        kw = query(; sources = FASTMRI, acceleration = a -> a !== nothing && a < 3, offline = true)
        @test Set(e.id for e in fastmri_r) == Set(e.id for e in kw)

        b0 = query("b0=3"; offline = true)
        @test !isempty(b0)
        @test all(e -> e.field_strength == 3.0, b0)
    end

    @testset "size comparison with a suffix" begin
        small = query("dataset=ocmr AND size < 100M"; offline = true)
        @test !isempty(small)
        @test all(e -> e.approx_size_bytes !== nothing && e.approx_size_bytes < 100_000_000, small)
    end

    @testset "nothing / not-nothing" begin
        all_e = query(; offline = true)
        with_r = query("R != nothing"; offline = true)
        without_r = query("R = nothing"; offline = true)
        @test all(e -> e.acceleration !== nothing, with_r)
        @test all(e -> e.acceleration === nothing, without_r)
        @test length(with_r) + length(without_r) == length(all_e)
        # `null`/`missing` are accepted spellings; `:unknown` symbols count as missing too
        @test Set(e.id for e in query("R = null"; offline = true)) == Set(e.id for e in without_r)
        @test all(e -> e.anatomy === :unknown, query("anatomy = missing"; offline = true))
    end

    @testset "wildcard vs exact string match" begin
        glob = query("id='fs_*'"; offline = true)
        @test !isempty(glob)
        @test all(e -> startswith(e.id, "fs_"), glob)

        exact = query("anatomy=knee"; offline = true)
        @test !isempty(exact)
        @test all(e -> e.anatomy === :knee, exact)
        # exact match is case-insensitive but not a substring match
        @test isempty(query("anatomy=kne"; offline = true))
    end

    @testset "AND/OR/parens combine like the grammar says" begin
        a = query("(anatomy=knee AND R<3) OR fully_sampled=true"; offline = true)
        b = filter(
            e -> (e.anatomy === :knee && e.acceleration !== nothing && e.acceleration < 3) ||
                e.fully_sampled === true, query(; offline = true),
        )
        @test Set(e.id for e in a) == Set(e.id for e in b)
    end

    @testset "extra-key field resolution" begin
        withmodel = filter(e -> haskey(e.extra, "scanner_model"), list_datasets(OCMR_SOURCE; offline = true))
        if !isempty(withmodel)
            want = withmodel[1].extra["scanner_model"]
            res = query("scanner_model='$(want)'"; sources = OCMR_SOURCE, offline = true)
            @test !isempty(res)
            @test all(e -> get(e.extra, "scanner_model", nothing) == want, res)
        end
    end

    @testset "unknown field: warn (default, matches nothing) vs strict (errors)" begin
        @test isempty(query("definitely_not_a_field=1"; sources = OCMR_SOURCE, offline = true))
        @test_throws ErrorException query(
            "definitely_not_a_field=1"; sources = OCMR_SOURCE, offline = true, strict = true,
        )
    end
end
