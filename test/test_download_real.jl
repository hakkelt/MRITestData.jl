# Opt-in real-download tests (tag :network). Skipped unless the runner includes the
# :network tag (see runtests.jl, gated by MRITESTDATA_NETWORK_TESTS=true). These hit
# OCMR / mridata.org live, refresh the index, download a relatively-small dataset,
# and reconstruct it with MRIReco.

@testitem "OCMR: refresh index + download + reconstruct" tags = [:network] begin
    using MRITestData
    using MRIReco  # loads MRITestDataMRIRecoExt

    mktempdir() do tmp
        old = MRITestData.CACHE_DIR[]
        MRITestData.CACHE_DIR[] = tmp
        try
            # Refresh the OCMR index from S3, then pick the relatively-smallest
            # candidate: a fully-sampled, single-slice file. Try candidates in order
            # until one loads without error (some files have non-standard XML headers
            # that MRIFiles cannot parse).
            refresh_index(OCMR_SOURCE; progress = false)
            @test index_age_days(OCMR_SOURCE) !== nothing

            candidates = filter(
                e -> e.fully_sampled === true && get(e.extra, "slices", 99) == 1,
                list_datasets(OCMR_SOURCE),
            )
            @test !isempty(candidates)

            img = nothing
            chosen = nothing
            for e in candidates
                path = download_dataset(e; progress = false)
                @test isfile(path)
                @test filesize(path) > 0
                @test is_cached(e)
                @test download_dataset(e; progress = false) == path   # cached, same path
                try
                    img = recon(path; reco = "direct")
                    chosen = e
                    break
                catch err
                    @warn "Skipping $(e.name): $(sprint(showerror, err))"
                end
            end
            @test chosen !== nothing  # at least one candidate loaded successfully
            @test img !== nothing
            @test ndims(img) >= 2
            @test all(>(0), size(img)[1:2])
        finally
            MRITestData.CACHE_DIR[] = old
        end
    end
end

@testitem "mridata: download + reconstruct (2D curated entry)" tags = [:network] begin
    using MRITestData
    using MRIReco

    mktempdir() do tmp
        old = MRITestData.CACHE_DIR[]
        MRITestData.CACHE_DIR[] = tmp
        try
            # The live-scraped index carries no size/dimensionality metadata.
            # Curated entries (bundled TOML, merged in by list_datasets) carry
            # approx_size_bytes and is3D. Prefer non-3D curated entries sorted by
            # size; 3D data triggers a BoundsError in MRIReco's direct reco mode.
            # Retry downloads on timeout (mridata.org is sometimes unstable) and
            # skip on any recon failure.
            entries = list_datasets(MRIDATA)
            @test !isempty(entries)

            curated_2d = filter(
                e -> e.approx_size_bytes !== nothing && e.is3D === false,
                entries,
            )
            curated_3d = filter(
                e -> e.approx_size_bytes !== nothing && e.is3D !== false,
                entries,
            )
            # Try 2D first, then 3D (may still work), both sorted smallest-first.
            candidates = vcat(
                sort(curated_2d; by = e -> e.approx_size_bytes),
                sort(curated_3d; by = e -> e.approx_size_bytes),
            )
            @test !isempty(candidates)

            img = nothing
            chosen = nothing
            for e in candidates
                path = try
                    download_dataset(e; progress = false)
                catch err
                    msg = sprint(showerror, err)
                    if occursin("timed out", msg)
                        @warn "mridata.org timed out downloading $(e.id); retrying in 10 s"
                        sleep(10)
                        try
                            download_dataset(e; progress = false)
                        catch err2
                            if occursin("timed out", sprint(showerror, err2))
                                @warn "mridata.org still unreachable; skipping download test"
                                return
                            end
                            rethrow(err2)
                        end
                    else
                        rethrow(err)
                    end
                end
                @test isfile(path)
                @test filesize(path) > 0
                try
                    img = recon(path; reco = "direct")
                    chosen = e
                    break
                catch err
                    @warn "Skipping $(e.id): $(sprint(showerror, err))"
                end
            end
            @test chosen !== nothing
            @test img !== nothing
            @test ndims(img) >= 2
            @test all(>(0), size(img)[1:2])
        finally
            MRITestData.CACHE_DIR[] = old
        end
    end
end

@testitem "OCMR parallel chunked download produces correct file" tags = [:network] begin
    using MRITestData
    using MRITestData: CACHE_DIR, PARALLEL_CHUNKS, PARALLEL_MIN_BYTES, _probe_url, _download_parallel

    # Verify that parallel chunked download produces the same bytes as a normal download.
    url = "https://ocmr.s3.amazonaws.com/data/fs_0001_1_5T.h5"
    accept_ranges, total = _probe_url(url)
    if !accept_ranges || total == 0
        @warn "OCMR S3 did not advertise byte-range support; skipping parallel-chunk test"
        return
    end

    mktempdir() do tmp
        # Download a small prefix (256 KB) via the parallel path and the single path,
        # then compare bytes to confirm the chunked reassembly is correct.
        nbytes = 256 * 1024
        nchunks = 4

        # Parallel download of the first nbytes
        par_dest = joinpath(tmp, "par.bin")
        par_tmp = par_dest * ".part"
        _download_parallel(url, par_tmp, nbytes, nchunks; progress = false, desc = "")
        mv(par_tmp, par_dest; force = true)

        # Single-connection download of the same range
        using Downloads
        single_dest = joinpath(tmp, "single.bin")
        Downloads.download(url, single_dest; headers = ["Range" => "bytes=0-$(nbytes - 1)"])

        par_bytes = read(par_dest)
        single_bytes = read(single_dest)
        @test length(par_bytes) == nbytes
        @test par_bytes == single_bytes
    end
end

@testitem "fetch_sizes fills approx_size_bytes for OCMR entries" tags = [:network] begin
    using MRITestData

    entries = list_datasets(OCMR_SOURCE; offline = true)
    # Pick a small subset to avoid too many HEAD requests in CI
    subset = first(entries, 3)
    result = fetch_sizes(subset)
    @test result isa Vector{DatasetEntry}
    @test length(result) == length(subset)
    # OCMR S3 serves Accept-Ranges: bytes so all three should be sized
    @test all(e -> e.approx_size_bytes !== nothing && e.approx_size_bytes > 0, result)
end

@testitem "refresh_index fetch_sizes populates approx_size_bytes" tags = [:network] begin
    using MRITestData

    mktempdir() do tmp
        old = MRITestData.CACHE_DIR[]
        MRITestData.CACHE_DIR[] = tmp
        try
            refresh_index(MRIDATA; progress = false, fetch_sizes = true)
            entries = list_datasets(MRIDATA)
            @test !isempty(entries)
            sized = filter(e -> e.approx_size_bytes !== nothing, entries)
            @test !isempty(sized)
            @test all(e -> e.approx_size_bytes > 0, sized)
        finally
            MRITestData.CACHE_DIR[] = old
        end
    end
end
