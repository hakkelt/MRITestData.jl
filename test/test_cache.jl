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
            e_bad = MRITestData.DatasetEntry(; source = e.source, id = e.id,
                name = e.name, url = e.url, sha256 = "deadbeef")
            @test !is_cached(e_bad)

            # Pinned-and-matching checksum is cached.
            e_ok = MRITestData.DatasetEntry(; source = e.source, id = e.id,
                name = e.name, url = e.url, sha256 = digest)
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
