@testitem "M4Raw catalog (offline)" begin
    using MRITestData
    using MRITestData: _cache_basename, _m4raw_path_to_id

    all_of(f, xs) = all(f, xs)

    @testset "source registration" begin
        @test M4RAW in list_sources()
        @test MRITestData.source_name(M4RAW) == "m4raw"
        @test occursin("creativecommons.org", MRITestData.terms_url(M4RAW))
    end

    @testset "catalog loading + fields" begin
        es = list_datasets(M4RAW; offline = true)
        @test !isempty(es)
        @test es isa Vector{DatasetEntry}
        # M4Raw: 0.3 T 4-channel fully-sampled Cartesian brain k-space.
        @test all_of(e -> e.anatomy === :brain, es)
        @test all_of(e -> e.field_strength == 0.3, es)
        @test all_of(e -> e.trajectory === :cartesian, es)
        @test all_of(e -> e.coils == 4, es)
        @test all_of(e -> e.fully_sampled === true, es)
        @test all_of(e -> e.is3D === false, es)
        @test all_of(e -> e.approx_size_bytes !== nothing, es)
        # ids are <set>/<study>_<contrast><rep> with no .h5 extension.
        @test all_of(e -> !endswith(e.id, ".h5"), es)
        @test all_of(e -> occursin('/', e.id), es)
        @test all_of(e -> e.url == "", es)
        # ZIP range-extraction coordinates carried in extra.
        for k in ("archive", "start_off", "end_off", "lfh_size", "compressed_size", "compression")
            @test all_of(e -> haskey(e.extra, k), es)
        end
        # byte spans are well-formed (end after start, header smaller than the span).
        @test all_of(e -> e.extra["end_off"] > e.extra["start_off"], es)
        @test all_of(e -> e.extra["lfh_size"] < (e.extra["end_off"] - e.extra["start_off"]), es)
        # every archive name points at the Zenodo record's ZIPs.
        @test all_of(e -> endswith(e.extra["archive"], ".zip"), es)
    end

    @testset "id derivation drops the .h5 suffix and prefixes the set" begin
        @test _m4raw_path_to_id("2022061003_FLAIR01.h5", "multicoil_val") ==
            "multicoil_val/2022061003_FLAIR01"
        @test _m4raw_path_to_id("multicoil_train/2022061003_T101.h5", "multicoil_train") ==
            "multicoil_train/2022061003_T101"
    end

    @testset "filtering + query" begin
        cart = list_datasets(M4RAW; offline = true, trajectory = :cartesian)
        @test !isempty(cart)
        @test all_of(e -> e.trajectory === :cartesian, cart)
        @test !isempty(query(; sources = M4RAW, anatomy = :brain, offline = true))
    end

    @testset "cache file restores the .h5 extension on the id" begin
        e = list_datasets(M4RAW; offline = true)[1]
        @test !endswith(e.id, ".h5")
        @test _cache_basename(M4RAW, e) == string(e.id, ".h5")
        @test endswith(cache_path(e), string(e.id, ".h5"))
        @test occursin("m4raw", cache_path(e))
    end

    @testset "synthesis of unknown file errors" begin
        # ids absent from the bundled offset map cannot be extracted.
        @test_throws ErrorException dataset(M4RAW, "multicoil_val/nope_T199"; offline = true)
        # A known id round-trips through `dataset`.
        e = list_datasets(M4RAW; offline = true)[1]
        @test dataset(M4RAW, e.id; offline = true).entry.id == e.id
    end
end

@testitem "M4Raw transparent load (network)" tags = [:network] begin
    using MRITestData
    using MRIBase: numChannels, AcquisitionData

    es = list_datasets(M4RAW; offline = true)
    @test !isempty(es)
    # Smallest member, pulled via Zenodo ZIP range-extraction + DEFLATE inflate, then
    # converted from fastMRI layout to a cached Cartesian ISMRMRD on first load.
    sm = first(sort(es; by = e -> something(e.extra["compressed_size"], typemax(Int))))
    raw = load_raw(sm)
    @test !isempty(raw.profiles)
    # M4Raw is fully-sampled Cartesian with a 4-channel head coil.
    @test lowercase(get(raw.params, "trajectory", "")) == "cartesian"
    acq = AcquisitionData(raw)
    @test numChannels(acq) == 4
end
