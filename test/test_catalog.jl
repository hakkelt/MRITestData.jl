@testitem "catalog (offline)" begin
    using MRITestData

    all_of(f, xs) = all(f, xs)

    @testset "sources" begin
        srcs = list_sources()
        @test MRIDATA in srcs
        @test OCMR_SOURCE in srcs
        @test M4RAW in srcs
    end

    @testset "mridata catalog + filtering" begin
        all = list_datasets(MRIDATA; offline = true)
        @test !isempty(all)
        @test all isa Vector{DatasetEntry}
        @test endswith(all[1].url, "mridata.org/download/$(all[1].id)")

        knees = list_datasets(MRIDATA; offline = true, anatomy = :knee)
        @test all_of(e -> e.anatomy === :knee, knees)

        # `missing` means "no filter"; `nothing` is a value, and selects the entries
        # whose vendor the catalog does not record.
        @test length(list_datasets(MRIDATA; offline = true, vendor = missing)) == length(all)
        unset = list_datasets(MRIDATA; offline = true, vendor = nothing)
        @test all_of(e -> e.vendor === nothing, unset)
        @test length(unset) == count(e -> e.vendor === nothing, all)
    end

    @testset "ocmr catalog + filtering" begin
        all = list_datasets(OCMR_SOURCE; offline = true)
        @test !isempty(all)
        @test all_of(e -> e.anatomy === :heart, all)
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
        @test endswith(h.entry.url, "mridata.org/download/00000000-1111-2222-3333-444444444444")

        # OCMR synthesis derives field strength / fully-sampled from the stem
        ho = dataset(OCMR_SOURCE, "fs_9999_3T"; offline = true)
        @test endswith(ho.entry.url, "fs_9999_3T.h5")
        @test ho.entry.field_strength == 3.0
        @test ho.entry.fully_sampled === true
    end
end

@testitem "catalog: entry order is deterministic" begin
    using MRITestData
    using MRITestData: _mridata_entries, _cmrx300_entries, _cmrx300_map_path, _BUNDLED_MRIDATA_INDEX

    # Two sources build their entries by grouping rows in a Dict — mridata merges the
    # scrape with the curated overlay, CMRxRecon-300 pairs each `_ks` member with its
    # `_calib` — so without an explicit sort their order would follow Dict iteration and
    # differ between sessions. Both sort by id before returning, which is what makes
    # `first(entries)` in tests, docs and the browser reproducible.
    #
    # The parsers are called directly (twice) rather than through `list_datasets`, whose
    # memo would return the very same vector and prove nothing.
    ids(entries) = [e.id for e in entries]

    @test issorted(ids(_mridata_entries(_BUNDLED_MRIDATA_INDEX)))
    @test ids(_mridata_entries(_BUNDLED_MRIDATA_INDEX)) == ids(_mridata_entries(_BUNDLED_MRIDATA_INDEX))

    demo = _cmrx300_map_path("demo")
    @test issorted(ids(_cmrx300_entries(demo)))
    @test ids(_cmrx300_entries(demo)) == ids(_cmrx300_entries(demo))

    # Across sets the catalog is the per-set maps concatenated in `_CMRX300_SETS` order, so
    # it is deterministic without being globally sorted.
    @test ids(list_datasets(CMRXRECON300; offline = true)) ==
        ids(list_datasets(CMRXRECON300; offline = true))
end

@testitem "catalog: map-backed sources reject unknown ids uniformly" begin
    using MRITestData
    using MRITestData: _can_synthesize

    # Only mridata (any UUID) and OCMR (any bucket file name) can build an entry for an id
    # that is not in the catalog; the map-backed sources need byte coordinates they do not
    # have, and `dataset` raises one shared error for all of them.
    @test _can_synthesize(MRIDATA)
    @test _can_synthesize(OCMR_SOURCE)
    for s in (CMRXRECON2024, CMRXRECON300, USC_SPEECH, M4RAW, FASTMRI)
        @test !_can_synthesize(s)
        err = try
            dataset(s, "__definitely/not/in/the/map__"; offline = true)
            nothing
        catch e
            sprint(showerror, e)
        end
        @test err !== nothing
        @test occursin("not in the catalog", err)
    end
end

@testitem "catalog: static-index sources bypass the fetch/cache layer" begin
    using MRITestData
    using MRITestData: _is_static_index, _bundled_index_path, ensure_index, CACHE_DIR

    @test !_is_static_index(MRIDATA)
    @test !_is_static_index(OCMR_SOURCE)
    mktempdir() do tmp
        old = CACHE_DIR[]
        CACHE_DIR[] = tmp
        try
            for s in (CMRXRECON2024, CMRXRECON300, USC_SPEECH, M4RAW, FASTMRI)
                @test _is_static_index(s)
                # Even with force=true there is no upstream: the bundled map is returned
                # as-is and nothing is written into the cache.
                @test ensure_index(s; force = true) == _bundled_index_path(s)
            end
            @test !isdir(joinpath(tmp, "index"))
        finally
            CACHE_DIR[] = old
        end
    end
end

@testitem "catalog: shared CSV cell readers" begin
    using MRITestData: _csv_cell_int, _csv_cell_float, _csv_cell_str, _put_optional!

    col = Dict("i" => 1, "f" => 2, "s" => 3, "blank" => 4, "numstr" => 5)
    row = [7, 3.7, "  hi ", "", "42"]

    @test _csv_cell_int(row, col, "i") === 7
    @test _csv_cell_int(row, col, "f") === 4          # Float64 cells round
    @test _csv_cell_int(row, col, "numstr") === 42    # readdlm may hand back a string
    @test _csv_cell_int(row, col, "missing") === nothing
    @test _csv_cell_int(row, col, "blank") === nothing
    @test _csv_cell_float(row, col, "f") === 3.7
    @test _csv_cell_float(row, col, "i") === 7.0
    @test _csv_cell_float(row, col, "numstr") === 42.0
    @test _csv_cell_float(row, col, "blank") === nothing
    @test _csv_cell_float(row, col, "missing") === nothing
    @test _csv_cell_str(row, col, "s") == "hi"
    @test _csv_cell_str(row, col, "missing") == ""

    extra = Dict{String, Any}()
    _put_optional!(extra, "a", nothing)
    _put_optional!(extra, "b", "")
    _put_optional!(extra, "c", 0)
    @test collect(keys(extra)) == ["c"]                # only "" and nothing are dropped
end

@testitem "catalog: ZipSpan round-trips through locator" begin
    using MRITestData: ZipSpan, _zip_span_from_row, _zip_span_locator, _zip_span, DatasetEntry

    col = Dict(
        "start_off" => 1, "end_off" => 2, "lfh_size" => 3,
        "compressed_size" => 4, "uncompressed_size" => 5, "compression" => 6,
    )
    span = _zip_span_from_row([100, 199, 30, 70, 512, 8], col)
    @test span == ZipSpan(100, 199, 30, 70, 512, 8)

    # A row missing any fetch coordinate is unusable; a missing uncompressed_size is not.
    @test _zip_span_from_row([100, 199, 30, 70, 512, ""], col) === nothing
    @test _zip_span_from_row([100, 199, 30, 70, "", 8], col) == ZipSpan(100, 199, 30, 70, nothing, 8)

    e = DatasetEntry(; source = M4RAW, id = "x", name = "x", url = "", locator = _zip_span_locator(span))
    got = _zip_span(e)
    @test (got.start_off, got.end_off, got.lfh_size, got.compressed_size, got.compression) ==
        (100, 199, 30, 70, 8)
end

@testitem "catalog: missing means no filter and nothing means unset" begin
    using MRITestData
    using MRITestData: _filter_hit, _matches

    # `_filter_hit` is the one predicate behind both named-field and `extra` filtering.
    @test _filter_hit(:knee, missing)              # no filter
    @test _filter_hit(nothing, missing)
    @test _filter_hit(nothing, nothing)            # nothing matches an unset field
    @test !_filter_hit(:knee, nothing)
    @test _filter_hit(:knee, :knee)
    @test _filter_hit(3.0, (1.5, 3.0))             # collection membership
    @test !_filter_hit(0.55, (1.5, 3.0))
    @test _filter_hit(8, c -> c !== nothing && c >= 4)   # predicate

    e = first(list_datasets(OCMR_SOURCE; offline = true))
    # The dictionary form must agree with the keyword form — `query` uses the former to
    # avoid rebuilding the keyword tuple per entry.
    for filters in (Dict(:anatomy => :heart), Dict(:anatomy => :knee), Dict(:vendor => missing))
        @test _matches(e, filters) == _matches(e; filters...)
    end

    # Whole-catalog behaviour: unknown-value selection is expressible, and the two
    # sentinels partition the catalog.
    every = list_datasets(FASTMRI; offline = true)
    unset = list_datasets(FASTMRI; offline = true, receiver_channels = nothing)
    known = list_datasets(FASTMRI; offline = true, receiver_channels = !isnothing)
    @test length(list_datasets(FASTMRI; offline = true, receiver_channels = missing)) == length(every)
    @test length(unset) + length(known) == length(every)
    @test all(e -> e.receiver_channels === nothing, unset)
end

@testitem "query: extra filters and text share the same sentinels" begin
    using MRITestData

    base = query(; sources = OCMR_SOURCE, offline = true)
    @test !isempty(base)

    # `missing` (the default) and an explicit `missing` text filter are both no-ops.
    @test length(query(; sources = OCMR_SOURCE, offline = true, text = missing)) == length(base)
    @test length(query(; sources = OCMR_SOURCE, offline = true, cohort = missing)) == length(base)

    # An `extra` key the entry does not carry reads as `nothing`, so it is selectable.
    without = query(; sources = OCMR_SOURCE, offline = true, __no_such_key__ = nothing)
    @test length(without) == length(base)
    @test isempty(query(; sources = OCMR_SOURCE, offline = true, __no_such_key__ = "x"))

    # Filtering through `query` must agree with filtering through `list_datasets`.
    @test length(query(; sources = OCMR_SOURCE, offline = true, fully_sampled = true)) ==
        length(list_datasets(OCMR_SOURCE; offline = true, fully_sampled = true))
end
