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
