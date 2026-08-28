@testitem "USC Speech catalog (offline)" begin
    using MRITestData
    using MRITestData: _cache_basename, _usc_path_to_id

    all_of(f, xs) = all(f, xs)

    @testset "source registration" begin
        @test USC_SPEECH in list_sources()
        @test MRITestData.source_name(USC_SPEECH) == "usc_speech"
        @test occursin("creativecommons.org", MRITestData.terms_url(USC_SPEECH))
    end

    @testset "catalog loading + fields" begin
        es = list_datasets(USC_SPEECH; offline = true)
        @test !isempty(es)
        @test es isa Vector{DatasetEntry}
        # USC SPAN: GE 1.5 T 8-channel spiral pharynx/larynx (vocal tract) rtMRI.
        @test all_of(e -> e.anatomy === :pharynx_larynx, es)
        @test all_of(e -> e.vendor === :ge, es)
        @test all_of(e -> e.field_strength == 1.5, es)
        @test all_of(e -> e.trajectory === :spiral, es)
        @test all_of(e -> e.receiver_channels == 8, es)
        @test all_of(e -> e.acquisition_dim == 2, es)
        @test all_of(e -> e.approx_size_bytes !== nothing, es)
        # ids are subject/2drt/<stimulus>_r<rep> paths with no .h5 extension or raw/ folder.
        @test all_of(e -> !endswith(e.id, ".h5"), es)
        @test all_of(e -> !occursin("/raw/", e.id), es)
        @test all_of(e -> startswith(e.id, "sub"), es)
        @test all_of(e -> e.url == "", es)
        # ZIP range-extraction coordinates carried in locator.
        for k in ("file_id", "start_off", "end_off", "lfh_size", "compressed_size", "compression")
            @test all_of(e -> haskey(e.locator, k), es)
        end
        # byte spans are well-formed (end after start, header smaller than the span).
        @test all_of(e -> e.locator["end_off"] > e.locator["start_off"], es)
        @test all_of(e -> e.locator["lfh_size"] < (e.locator["end_off"] - e.locator["start_off"]), es)
    end

    @testset "id derivation drops raw/ folder + filename prefix + suffix" begin
        @test _usc_path_to_id("sub001/2drt/raw/sub001_2drt_01_vcv1_r1_raw.h5") ==
            "sub001/2drt/01_vcv1_r1"
        @test _usc_path_to_id("sub010/2drt/raw/sub010_2drt_12_picture1_raw.h5") ==
            "sub010/2drt/12_picture1"
    end

    @testset "metadata from CSV columns" begin
        es = list_datasets(USC_SPEECH; offline = true)
        e = first(filter(e -> e.id == "sub001/2drt/01_vcv1_r1", es))
        @test e.subject_id == "sub001"
        @test get(e.extra, "protocol_name", "") == "01_vcv1"
        @test e.repetition == 1
    end

    @testset "filtering + query" begin
        sp = list_datasets(USC_SPEECH; offline = true, trajectory = :spiral)
        @test !isempty(sp)
        @test all_of(e -> e.trajectory === :spiral, sp)
        @test !isempty(query(; sources = USC_SPEECH, text = "vcv1", offline = true))
    end

    @testset "cache file restores the .h5 extension on the id" begin
        e = list_datasets(USC_SPEECH; offline = true)[1]
        @test !endswith(e.id, ".h5")
        @test _cache_basename(USC_SPEECH, e) == string(e.id, ".h5")
        @test endswith(cache_path(e), string(e.id, ".h5"))
        @test occursin("usc_speech", cache_path(e))
    end

    @testset "synthesis of unknown file errors" begin
        # ids absent from the bundled offset map cannot be extracted.
        @test_throws ErrorException dataset(USC_SPEECH, "sub999/2drt/nope_r1"; offline = true)
        # A known id round-trips through `dataset`.
        e = list_datasets(USC_SPEECH; offline = true)[1]
        @test dataset(USC_SPEECH, e.id; offline = true).entry.id == e.id
    end
end

@testitem "USC Speech transparent load (network)" tags = [:network] begin
    using MRITestData

    es = list_datasets(USC_SPEECH; offline = true)
    @test !isempty(es)
    # Smallest member, pulled via figshare ZIP range-extraction + DEFLATE inflate.
    fs = first(sort(es; by = e -> something(e.locator["compressed_size"], typemax(Int))))
    raw = load_raw(fs)
    @test !isempty(raw.profiles)
    # USC 2drt is a 13-interleaf spiral acquisition — not Cartesian.
    @test lowercase(get(raw.params, "trajectory", "")) != "cartesian"
end
