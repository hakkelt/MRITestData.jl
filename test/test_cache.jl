@testitem "cache (offline)" begin
    using MRITestData
    using MRITestData: CACHE_DIR, cache_path, _write_meta, _sha256_hex

    mktempdir() do tmp
        old = CACHE_DIR[]
        CACHE_DIR[] = tmp
        try
            e = list_datasets(OCMR_SOURCE; offline = true)[1]

            @test !is_cached(e)
            path = cache_path(e)
            @test startswith(path, tmp)
            @test endswith(path, ".h5")

            # Fake a completed download: write a file + matching sidecar.
            mkpath(dirname(path))
            write(path, b"not really hdf5 but enough for cache bookkeeping")
            digest = _sha256_hex(path)
            _write_meta(e, path, digest)

            @test is_cached(e)               # no pinned sha256 -> existence suffices

            # Pinned-but-mismatched checksum must invalidate the cache.
            e_bad = MRITestData.DatasetEntry(;
                source = e.source, id = e.id,
                name = e.name, url = e.url, sha256 = "deadbeef"
            )
            @test !is_cached(e_bad)

            # Pinned-and-matching checksum is cached.
            e_ok = MRITestData.DatasetEntry(;
                source = e.source, id = e.id,
                name = e.name, url = e.url, sha256 = digest
            )
            @test is_cached(e_ok)

            # clear_cache removes it.
            clear_cache(; source = OCMR_SOURCE)
            @test !is_cached(e)
        finally
            CACHE_DIR[] = old
        end
    end
end

@testitem "index cache fallback (offline)" begin
    using MRITestData
    using MRITestData: CACHE_DIR, index_path, ensure_index

    mktempdir() do tmp
        old = CACHE_DIR[]
        CACHE_DIR[] = tmp
        try
            # No cached index yet -> age is nothing, offline list still works via the
            # bundled fallback files.
            @test index_age_days(OCMR_SOURCE) === nothing
            @test !isempty(list_datasets(OCMR_SOURCE; offline = true))
            @test !isempty(list_datasets(MRIDATA; offline = true))

            # ensure_index(offline) returns a usable path without touching the network.
            p = ensure_index(OCMR_SOURCE; offline = true)
            @test isfile(p)
        finally
            CACHE_DIR[] = old
        end
    end
end

@testitem "fetch_sizes preserves already-sized entries and returns correct shape" begin
    using MRITestData

    entries = list_datasets(MRIDATA; offline = true)
    @test !isempty(entries)

    # Entries without approx_size_bytes stay as-is (no network call for them here —
    # we just verify the function returns a Vector{DatasetEntry} of the same length
    # with no error, and that entries already carrying a size are unchanged).
    pre_sized = filter(e -> e.approx_size_bytes !== nothing, entries)
    # Run with all entries but block network by picking entries that already have size
    # (or none at all — the function is safe to call offline, it just returns nothing for unknowns).
    result = fetch_sizes(pre_sized)
    @test result isa Vector{DatasetEntry}
    @test length(result) == length(pre_sized)
    for (orig, got) in zip(pre_sized, result)
        @test got.approx_size_bytes === orig.approx_size_bytes
        @test got.id == orig.id
    end
end

@testitem "PARALLEL_CHUNKS and PARALLEL_MIN_BYTES are configurable" begin
    using MRITestData

    old_chunks = MRITestData.PARALLEL_CHUNKS[]
    old_min = MRITestData.PARALLEL_MIN_BYTES[]
    try
        MRITestData.PARALLEL_CHUNKS[] = 1
        @test MRITestData.PARALLEL_CHUNKS[] == 1
        MRITestData.PARALLEL_MIN_BYTES[] = 1024
        @test MRITestData.PARALLEL_MIN_BYTES[] == 1024
    finally
        MRITestData.PARALLEL_CHUNKS[] = old_chunks
        MRITestData.PARALLEL_MIN_BYTES[] = old_min
    end
end

@testitem "refresh_index no-arg returns one path per source" begin
    using MRITestData
    using MRITestData: CACHE_DIR

    # The no-arg refresh_index must return a collection with one entry per source.
    # We don't actually hit the network here — we only verify the shape of the return
    # value, which is independent of whether the fetches succeed or fail (failures fall
    # back to the bundled index and return a valid path).
    mktempdir() do tmp
        old = CACHE_DIR[]
        CACHE_DIR[] = tmp
        try
            paths = refresh_index(; progress = false)
            @test paths isa AbstractVector
            @test length(paths) == length(list_sources())
            @test all(isfile, paths)
        finally
            CACHE_DIR[] = old
        end
    end
end
