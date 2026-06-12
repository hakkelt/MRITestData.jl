@testitem "CMRxRecon-300 catalog (offline)" begin
    using MRITestData
    using MRITestData: _cache_basename

    @testset "source registration" begin
        @test CMRXRECON300 in list_sources()
        @test MRITestData.source_name(CMRXRECON300) == "cmrxrecon300"
        @test occursin("syn52965326", MRITestData.terms_url(CMRXRECON300))
    end

    @testset "catalog loading + fields (committed DemoData map)" begin
        es = list_datasets(CMRXRECON300; offline = true)
        @test !isempty(es)
        @test es isa Vector{DatasetEntry}
        @test all(e -> e.anatomy === :cardiac, es)
        @test all(e -> e.vendor === :siemens, es)
        @test all(e -> e.trajectory === :cartesian, es)
        # `_ks` k-space is undersampled; only the `_calib` ACS files are fully sampled.
        @test all(e -> e.fully_sampled === false, filter(e -> endswith(e.id, "_ks"), es))
        @test all(e -> e.fully_sampled === true, filter(e -> endswith(e.id, "_calib"), es))
        @test all(e -> haskey(e.extra, "calib_id"), filter(e -> endswith(e.id, "_ks"), es))
        @test all(e -> !endswith(e.id, ".mat"), es)   # ids drop the .mat extension
        @test all(e -> e.url == "", es)
        # every entry carries the coordinates the zran engine needs
        @test all(e -> haskey(e.extra, "set"), es)
        @test all(e -> haskey(e.extra, "data_offset"), es)
        @test all(e -> haskey(e.extra, "size"), es)
        @test all(e -> e.approx_size_bytes == e.extra["size"], es)
    end

    @testset "DemoData members + metadata" begin
        es = list_datasets(CMRXRECON300; offline = true)
        ks = first(filter(e -> endswith(e.id, "t2map_ks"), es))
        @test get(ks.extra, "set", "") == "DemoData"
        @test get(ks.extra, "subject", "") == "P001"
        @test get(ks.extra, "modality", "") == "T2map"
        @test ks.extra["data_offset"] isa Int && ks.extra["size"] isa Int
        @test get(ks.extra, "mat_file", "") == "t2map_ks.mat"   # original filename retained
        # both k-space and calibration members are catalogued
        @test any(e -> endswith(e.id, "_ks"), es)
        @test any(e -> endswith(e.id, "_calib"), es)
    end

    @testset "filtering + query" begin
        t2 = query(; sources = CMRXRECON300, modality = "T2map", offline = true)
        @test !isempty(t2)
        @test all(e -> get(e.extra, "modality", nothing) == "T2map", t2)
        @test !isempty(query(; sources = CMRXRECON300, text = "cine_sax", offline = true))
    end

    @testset "cache file restores the .mat extension on the id" begin
        e = list_datasets(CMRXRECON300; offline = true)[1]
        @test !endswith(e.id, ".mat")
        @test _cache_basename(CMRXRECON300, e) == string(e.id, ".mat")
        @test endswith(cache_path(e), string(e.id, ".mat"))
        @test occursin("cmrxrecon300", cache_path(e))
    end

    @testset "synthesis of unknown file errors" begin
        @test_throws ErrorException dataset(CMRXRECON300, "DemoData/Nope/x"; offline = true)
        e = list_datasets(CMRXRECON300; offline = true)[1]
        @test dataset(CMRXRECON300, e.id; offline = true).entry.id == e.id
    end
end

@testitem "CMRxRecon-300 sampling mask from undersampled k-space (offline)" begin
    using MRITestData
    using MRITestData: _cmrxrecon_sampling_mask, _cmrxrecon_to_ismrmrd

    nx, ny, nc, nz, nt = 12, 18, 4, 2, 3
    # zero-filled R=3 undersampled k-space (every 3rd ky line acquired), like CMRxRecon-300
    k = zeros(ComplexF32, nx, ny, nc, nz, nt)
    acquired = 3:3:ny
    for t in 1:nt, ky in acquired
        k[:, ky, :, :, t] .= ComplexF32(t + ky)   # nonzero on acquired lines only
    end

    mask = _cmrxrecon_sampling_mask(k)
    @test size(mask) == (nx, ny, nt)
    for t in 1:nt
        @test findall(vec(any(mask[:, :, t]; dims = 1))) == collect(acquired)
    end

    # The derived mask must drive the ISMRMRD to emit only the acquired lines (not all ny).
    dest = tempname() * ".h5"
    _cmrxrecon_to_ismrmrd(k, mask, dest)
    raw = load_raw(dest)
    ky0 = sort(unique(Int(p.head.idx.kspace_encode_step_1) + 1 for p in raw.profiles if Int(p.head.idx.contrast) == 0))
    @test ky0 == collect(acquired)
    @test length(raw.profiles) == length(acquired) * nz * nt
end

@testitem "CMRxRecon-300 zran random access (offline)" begin
    using MRITestData
    using MRITestData: Zran
    import CodecZlib

    # Moderately compressible, multi-block data so the scan captures several checkpoints
    # with non-trivial back-references (so the 32 KiB dictionary actually matters).
    data = rand(0x00:0x3f, 4_000_000)
    gz = CodecZlib.transcode(CodecZlib.GzipCompressor, data)

    collected = UInt8[]
    st = Zran.ScanState()
    # Capture a checkpoint at the start of every chunk (every block boundary), mimicking
    # the indexer's per-file `scan_capture!` calls; the first lands at the stream start.
    st.on_output = (buf, n) -> (Zran.scan_capture!(st); append!(collected, view(buf, 1:n)))
    # feed in irregular chunks to exercise the cross-chunk prev_byte bookkeeping
    let i = 1
        while i <= length(gz)
            j = min(i + 137_000, length(gz))
            Zran.scan_feed!(st, view(gz, i:j))
            i = j + 1
        end
    end
    cps = Zran.scan_finish!(st)

    @testset "scan decodes the whole stream and captures checkpoints" begin
        @test collected == data
        @test length(cps) >= 3
        # checkpoints advance monotonically in both axes; the first is the stream start
        @test issorted([c.comp_off for c in cps])
        @test issorted([c.unc_off for c in cps])
        @test cps[1].unc_off == 0 && isempty(cps[1].window)
    end

    @testset "extract from the stream-start checkpoint (first block, no dictionary)" begin
        ex = Zran.ExtractState(cps[1]; skip = 0, nbytes = 40_000)
        Zran.extract_feed!(ex, gz[(cps[1].comp_off + 1):end])
        @test ex.out == data[1:40_000]
    end

    @testset "random-access extract from a mid-stream checkpoint matches" begin
        target_off, target_len = 2_000_000, 77_777
        ck = cps[findlast(c -> c.unc_off <= target_off, cps)]
        ex = Zran.ExtractState(ck; skip = target_off - ck.unc_off, nbytes = target_len)
        let p = ck.comp_off + 1
            while !Zran.extract_done(ex) && p <= length(gz)
                q = min(p + 200_000, length(gz))
                Zran.extract_feed!(ex, view(gz, p:q))
                p = q + 1
            end
        end
        @test ex.out == data[(target_off + 1):(target_off + target_len)]
    end

    @testset "negative control: extracting without the dictionary is wrong" begin
        # Use a checkpoint with a non-empty window but bypass inflateSetDictionary by
        # zeroing it; the back-references then resolve against garbage.
        ck = cps[2]
        bad = Zran.Checkpoint(ck.comp_off, ck.unc_off, ck.bits, ck.prev_byte, zeros(UInt8, length(ck.window)))
        ex = Zran.ExtractState(bad; skip = 0, nbytes = 50_000)
        let p = ck.comp_off + 1
            while !Zran.extract_done(ex) && p <= length(gz)
                q = min(p + 200_000, length(gz))
                Zran.extract_feed!(ex, view(gz, p:q))
                p = q + 1
            end
        end
        @test ex.out != data[(ck.unc_off + 1):(ck.unc_off + 50_000)]
    end

    @testset "index (de)serialise round-trips through gzip" begin
        buf = IOBuffer()
        Zran.write_index(buf, 500_000, cps)
        raw = take!(buf)
        comp = CodecZlib.transcode(CodecZlib.GzipCompressor, raw)
        interval2, cps2 = Zran.read_index(IOBuffer(CodecZlib.transcode(CodecZlib.GzipDecompressor, comp)))
        @test interval2 == 500_000
        @test length(cps2) == length(cps)
        @test all(
            cps[k].comp_off == cps2[k].comp_off && cps[k].unc_off == cps2[k].unc_off &&
                cps[k].bits == cps2[k].bits && cps[k].prev_byte == cps2[k].prev_byte &&
                cps[k].window == cps2[k].window for k in eachindex(cps)
        )
    end
end

@testitem "CMRxRecon-300 tar parsing (offline)" begin
    using MRITestData
    using MRITestData: TarIO

    # Build a tar in memory: two short files plus one whose path exceeds 100 bytes,
    # forcing a GNU/PAX long-name record before its header.
    function tar_block(name, data)
        hdr = zeros(UInt8, 512)
        nb = codeunits(name)
        copyto!(hdr, 1, nb, 1, min(length(nb), 100))
        # size as 11-octal-digit + NUL at offset 124
        oct = string(length(data); base = 8)
        ob = codeunits(lpad(oct, 11, '0'))
        copyto!(hdr, 125, ob, 1, 11)
        hdr[157] = UInt8('0')                       # typeflag: regular file
        copyto!(hdr, 258, codeunits("ustar\0"), 1, 6)
        # checksum: sum of bytes with the checksum field treated as spaces
        for i in 149:156
            hdr[i] = UInt8(' ')
        end
        s = sum(Int, hdr)
        cb = codeunits(string(s; base = 8))
        copyto!(hdr, 149, codeunits(lpad(string(s; base = 8), 6, '0')), 1, 6)
        hdr[155] = 0x00; hdr[156] = UInt8(' ')
        pad = (-length(data)) & 511
        return vcat(hdr, collect(codeunits(String(copy(data)))), zeros(UInt8, pad))
    end

    # GNU long-name ('L') record: payload is the full path; the next header is the file.
    function gnu_longname_block(longpath)
        hdr = zeros(UInt8, 512)
        copyto!(hdr, 1, codeunits("././@LongLink"), 1, 13)
        oct = string(length(longpath) + 1; base = 8)
        copyto!(hdr, 125, codeunits(lpad(oct, 11, '0')), 1, 11)
        hdr[157] = UInt8('L')
        copyto!(hdr, 258, codeunits("ustar "), 1, 6)
        for i in 149:156
            hdr[i] = UInt8(' ')
        end
        copyto!(hdr, 149, codeunits(lpad(string(sum(Int, hdr); base = 8), 6, '0')), 1, 6)
        nameb = vcat(collect(codeunits(longpath)), 0x00)
        pad = (-length(nameb)) & 511
        return vcat(hdr, nameb, zeros(UInt8, pad))
    end

    a = rand(UInt8, 1000)
    b = rand(UInt8, 3000)
    longpath = "TrainingSet/" * repeat("x", 110) * "/cine_lax_ks.mat"
    c = rand(UInt8, 1234)

    tar = UInt8[]
    append!(tar, tar_block("sub/a.mat", a))
    append!(tar, tar_block("sub/b.mat", b))
    append!(tar, gnu_longname_block(longpath))
    append!(tar, tar_block(longpath[1:100], c))   # short name in header; long name overrides
    append!(tar, zeros(UInt8, 1024))               # end-of-archive marker

    members = TarIO.TarMember[]
    ts = TarIO.TarScanner(m -> push!(members, m))
    # feed in small irregular chunks to exercise partial-header buffering
    let i = 1
        while i <= length(tar)
            j = min(i + 91, length(tar))
            TarIO.feed!(ts, view(tar, i:j))
            i = j + 1
        end
    end

    @test length(members) == 3
    byname = Dict(m.path => m for m in members)
    @test haskey(byname, "sub/a.mat") && byname["sub/a.mat"].size == 1000
    @test haskey(byname, "sub/b.mat") && byname["sub/b.mat"].size == 3000
    @test haskey(byname, longpath) && byname[longpath].size == 1234
    # recorded payload offsets point at the exact bytes
    @test tar[(byname["sub/a.mat"].data_offset + 1):(byname["sub/a.mat"].data_offset + 1000)] == a
    @test tar[(byname[longpath].data_offset + 1):(byname[longpath].data_offset + 1234)] == c
end

@testitem "CMRxRecon-300 transparent load — DemoData (network)" tags = [:network] begin
    using MRITestData

    if isempty(get_synapse_token())
        @test_skip "no Synapse token configured"
    else
        mktempdir() do tmp
            old = MRITestData.CACHE_DIR[]
            MRITestData.CACHE_DIR[] = tmp
            try
                es = list_datasets(CMRXRECON300; offline = true)
                # smallest k-space member, fetched via the zran engine + HTTP range requests
                ks = first(sort(filter(e -> endswith(e.id, "_ks"), es); by = e -> e.approx_size_bytes))
                path = download_dataset(ks; progress = false)
                @test filesize(path) == ks.approx_size_bytes
                @test haskey(MRITestData.load_mat(path), "Recon_ks")
                raw = load_raw(ks)
                @test lowercase(get(raw.params, "trajectory", "")) == "cartesian"
                @test !isempty(raw.profiles)
            finally
                MRITestData.CACHE_DIR[] = old
            end
        end
    end
end
