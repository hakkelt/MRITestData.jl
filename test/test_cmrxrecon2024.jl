@testitem "CMRxRecon2024 catalog (offline)" begin
    using MRITestData
    using MRITestData: _cache_basename

    all_of(f, xs) = all(f, xs)

    @testset "source registration" begin
        @test CMRXRECON2024 in list_sources()
        @test MRITestData.source_name(CMRXRECON2024) == "cmrxrecon2024"
        @test occursin("cmrxrecon", MRITestData.terms_url(CMRXRECON2024))
    end

    @testset "catalog loading + fields" begin
        es = list_datasets(CMRXRECON2024; offline = true)
        @test !isempty(es)
        @test es isa Vector{DatasetEntry}
        # All CMRxRecon2024 files are Siemens cardiac Cartesian, sizes known.
        @test all_of(e -> e.anatomy === :cardiac, es)
        @test all_of(e -> e.vendor === :siemens, es)
        # Measured field strength from info CSVs (~2.89 T); nominal 3 T for entries
        # without acquisition parameters.
        @test all_of(e -> e.field_strength !== nothing, es)
        @test all_of(e -> 2.5 <= e.field_strength <= 3.5, es)
        @test all_of(e -> e.trajectory === :cartesian, es)
        @test all_of(e -> e.approx_size_bytes !== nothing, es)
        # ids are modality-rooted paths ending in .mat; no static download URL.
        @test all_of(e -> endswith(e.id, ".mat"), es)
        @test all_of(e -> !startswith(e.id, "MultiCoil/"), es)
        @test all_of(e -> !occursin("/FullSample/", e.id), es)
        @test all_of(e -> e.url == "", es)
        # all entries are fully-sampled FullSample ground truth
        @test all_of(e -> e.fully_sampled === true, es)
        # fragment coordinates carried in extra
        for k in ("start_frag", "start_off", "end_frag", "end_off", "lfh_size", "compressed_size", "compression")
            @test all_of(e -> haskey(e.extra, k), es)
        end
    end

    @testset "metadata from CSV annotations" begin
        es = list_datasets(CMRXRECON2024; offline = true)
        # Spot-check a known FullSample entry using the simplified id.
        fs = first(filter(e -> e.id == "Cine/TrainingSet/P001/cine_sax.mat", es))
        @test get(fs.extra, "modality", "") == "Cine"
        @test get(fs.extra, "dataset_set", "") == "TrainingSet"
        @test get(fs.extra, "subject", "") == "P001"
        @test fs.fully_sampled === true
        @test get(fs.extra, "mat_file", "") == "cine_sax.mat"
        @test get(fs.extra, "sampling", "") == "full"
        @test get(fs.extra, "archive", "") == "training"
        # Spot-check a ValidationSet entry (from the AfterCompetition archive).
        vs = first(filter(e -> e.id == "Cine/ValidationSet/P001/cine_sax.mat", es))
        @test get(vs.extra, "dataset_set", "") == "ValidationSet"
        @test get(vs.extra, "archive", "") == "aftercompetition"
        @test vs.fully_sampled === true
        # All three dataset sets are present.
        sets = Set(get(e.extra, "dataset_set", "") for e in es)
        @test "TrainingSet" in sets
        @test "ValidationSet" in sets
        @test "TestSet" in sets
    end

    @testset "filtering + query" begin
        fs = list_datasets(CMRXRECON2024; offline = true, fully_sampled = true)
        @test !isempty(fs)
        @test all_of(e -> e.fully_sampled === true, fs)

        cine = query(; sources = CMRXRECON2024, modality = "Cine", offline = true)
        @test !isempty(cine)
        @test all_of(e -> get(e.extra, "modality", nothing) == "Cine", cine)

        @test !isempty(query(; sources = CMRXRECON2024, text = "cine_sax", offline = true))
    end

    @testset "cache path uses .mat id verbatim" begin
        e = list_datasets(CMRXRECON2024; offline = true)[1]
        @test _cache_basename(CMRXRECON2024, e) == e.id
        @test endswith(cache_path(e), e.id)
        @test occursin("cmrxrecon2024", cache_path(e))
    end

    @testset "synthesis of unknown file errors" begin
        # Files absent from the offset map cannot be extracted.
        @test_throws ErrorException dataset(CMRXRECON2024, "Cine/Nope/x.mat"; offline = true)
        # A known id round-trips through `dataset`.
        e = list_datasets(CMRXRECON2024; offline = true)[1]
        @test dataset(CMRXRECON2024, e.id; offline = true).entry.id == e.id
    end

    @testset "synapse token preference" begin
        # With no env var and no stored preference the token is empty.
        if !haskey(ENV, "SYNAPSE_AUTH_TOKEN")
            @test get_synapse_token() isa String
        end
    end
end

@testitem "CMRxRecon2024 sampling/ids (offline)" begin
    using MRITestData

    es = list_datasets(CMRXRECON2024; offline = true)

    @testset "sampling annotation present" begin
        @test all(e -> haskey(e.extra, "sampling"), es)
        @test all(e -> get(e.extra, "sampling", "") == "full", es)
    end

    @testset "ids use simplified (no MultiCoil/, no FullSample/) form" begin
        @test all(e -> !startswith(e.id, "MultiCoil/"), es)
        @test all(e -> !occursin("/FullSample/", e.id), es)
    end
end

@testitem "CMRxRecon2024 fetch: archive specs + entity-id lookup (offline)" begin
    using MRITestData
    using MRITestData: _ARCHIVES, _load_cmrxrecon_parts!, _cmrxrecon_entity_id

    @test haskey(_ARCHIVES, "training")
    @test haskey(_ARCHIVES, "aftercompetition")

    # Both committed entity-ID maps load, share the 4 GiB chunk size, and resolve a
    # real Synapse id for fragment 0; out-of-range fragments error clearly. This is the
    # symmetric runtime path both archives now share (no offset conversion).
    for archive in ("training", "aftercompetition")
        parts, chunk = _load_cmrxrecon_parts!(archive)
        @test chunk == 4 * 1024^3
        @test !isempty(parts)
        spec = _ARCHIVES[archive]
        @test startswith(_cmrxrecon_entity_id(spec, parts, 0), "syn")
        @test_throws ErrorException _cmrxrecon_entity_id(spec, parts, 99_999)
    end
end

@testitem "CMRxRecon2024 .mat→ISMRMRD conversion (offline)" begin
    using MRITestData
    using MRITestData: _cmrxrecon_to_ismrmrd

    nx, ny, nc, nz, nt = 10, 8, 3, 2, 2
    k = ComplexF32.(reshape(1:(nx * ny * nc * nz * nt), nx, ny, nc, nz, nt))

    # contrast (1-based) → sorted acquired ky lines (1-based), read off the profiles
    # written into the ISMRMRD file.
    function ky_by_contrast(raw)
        d = Dict{Int, Vector{Int}}()
        for p in raw.profiles
            c = Int(p.head.idx.contrast) + 1
            push!(get!(d, c, Int[]), Int(p.head.idx.kspace_encode_step_1) + 1)
        end
        return Dict(c => sort(unique(v)) for (c, v) in d)
    end

    @testset "Task1 2D line mask (applies to every frame)" begin
        acquired = [2, 4, 5, 6]
        mask = falses(nx, ny)
        for ky in acquired
            mask[:, ky] .= true
        end
        dest = tempname() * ".h5"
        _cmrxrecon_to_ismrmrd(k, mask, dest)
        raw = load_raw(dest)
        @test lowercase(get(raw.params, "trajectory", "")) == "cartesian"
        @test size(raw.profiles[1].data) == (nx, nc)
        @test raw.params["encodedSize"][1:2] == [nx, ny]
        kbc = ky_by_contrast(raw)
        @test kbc[1] == acquired
        @test kbc[2] == acquired
        # both slices are emitted
        @test sort(unique(Int(p.head.idx.slice) for p in raw.profiles)) == [0, 1]
    end

    @testset "Task2 per-frame 3D mask (frame → contrast)" begin
        mask = falses(nx, ny, nt)
        mask[:, [2, 3], 1] .= true
        mask[:, [5, 6, 7], 2] .= true
        dest = tempname() * ".h5"
        _cmrxrecon_to_ismrmrd(k, mask, dest)
        kbc = ky_by_contrast(load_raw(dest))
        @test kbc[1] == [2, 3]
        @test kbc[2] == [5, 6, 7]
    end

    @testset "FullSample (mask = trues) → all lines, every frame" begin
        dest = tempname() * ".h5"
        _cmrxrecon_to_ismrmrd(k, trues(nx, ny), dest)
        kbc = ky_by_contrast(load_raw(dest))
        @test kbc[1] == collect(1:ny)
        @test kbc[2] == collect(1:ny)
    end

    @testset "Pseudo-radial 2D mask: a line is acquired if it holds any sample" begin
        mask = falses(nx, ny, nt)
        mask[2, 2, 1] = true; mask[5, 3, 1] = true; mask[8, 6, 1] = true   # ky 2,3,6
        mask[1, 1, 2] = true; mask[4, 4, 2] = true                          # ky 1,4
        dest = tempname() * ".h5"
        _cmrxrecon_to_ismrmrd(k, mask, dest)
        kbc = ky_by_contrast(load_raw(dest))
        @test kbc[1] == [2, 3, 6]
        @test kbc[2] == [1, 4]
    end

    @testset "BlackBlood 4D (no temporal axis)" begin
        kb = ComplexF32.(reshape(1:(nx * ny * nc * nz), nx, ny, nc, nz))
        mask = falses(nx, ny)
        mask[:, [3, 4]] .= true
        dest = tempname() * ".h5"
        _cmrxrecon_to_ismrmrd(kb, mask, dest)
        raw = load_raw(dest)
        @test ky_by_contrast(raw)[1] == [3, 4]
        @test size(raw.profiles[1].data) == (nx, nc)
    end
end

@testitem "CMRxRecon2024 transparent load — TrainingSet (network)" tags = [:network] begin
    using MRITestData

    es = list_datasets(CMRXRECON2024; offline = true)
    training = filter(e -> get(e.extra, "dataset_set", "") == "TrainingSet", es)
    @test !isempty(training)
    fs = first(sort(training; by = e -> something(e.approx_size_bytes, typemax(Int))))
    raw = load_raw(fs)
    @test lowercase(get(raw.params, "trajectory", "")) == "cartesian"
    @test !isempty(raw.profiles)
end

@testitem "CMRxRecon2024 transparent load — AfterCompetition (network)" tags = [:network] begin
    using MRITestData

    es = list_datasets(CMRXRECON2024; offline = true)
    aftercomp = filter(e -> get(e.extra, "archive", "") == "aftercompetition", es)
    @test !isempty(aftercomp)
    # Smallest entry across ValidationSet and TestSet, fetched via Synapse range requests.
    fs = first(sort(aftercomp; by = e -> something(e.approx_size_bytes, typemax(Int))))
    raw = load_raw(fs)
    @test lowercase(get(raw.params, "trajectory", "")) == "cartesian"
    @test !isempty(raw.profiles)
end
