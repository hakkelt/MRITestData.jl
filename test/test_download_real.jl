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

@testitem "mridata: download + reconstruct (relatively small)" tags = [:network] begin
    using MRITestData
    using MRIReco

    mktempdir() do tmp
        old = MRITestData.CACHE_DIR[]
        MRITestData.CACHE_DIR[] = tmp
        try
            # Use the relatively-smallest curated mridata entry. The Stanford 3D FSE
            # knee is ~1.5 GB; allow it via a generous max_bytes (no smaller 2D set is
            # curated yet). Absolute size is not critical for this opt-in test.
            entries = list_datasets(MRIDATA)
            @test !isempty(entries)
            sized = filter(e -> e.approx_size_bytes !== nothing, entries)
            e = isempty(sized) ? first(entries) : argmin(x -> x.approx_size_bytes, sized)

            # Attempt download; skip gracefully if mridata.org is unreachable.
            path = try
                download_dataset(e; progress = false, max_bytes = 4_000_000_000)
            catch err
                if err isa Exception && occursin("timed out", sprint(showerror, err))
                    @warn "mridata.org unreachable (connection timed out); skipping download test"
                    return
                end
                rethrow(err)
            end
            @test isfile(path)
            @test filesize(path) > 0

            img = recon(path; reco = "direct")
            @test ndims(img) >= 2
            @test all(>(0), size(img)[1:2])
        finally
            MRITestData.CACHE_DIR[] = old
        end
    end
end
