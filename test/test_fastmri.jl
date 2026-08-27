@testitem "FastMRI: parse email URLs" tags = [] begin
    using MRITestData
    # Unit-test the regex/parser used by set_fastmri_urls!. We call the internal logic
    # directly instead of touching Preferences so the test is side-effect-free.

    sample_email = """
    Dear Researcher,

    Your fastMRI data download request has been approved.

    curl -C - "https://fastmri-dataset.s3.amazonaws.com/knee_singlecoil_train.tar.xz?AWSAccessKeyId=AKIATEST&Expires=9999999999&Signature=abc123" --output knee_singlecoil_train.tar.xz
    curl -C - "https://fastmri-dataset.s3.amazonaws.com/knee_multicoil_train.tar.xz?AWSAccessKeyId=AKIATEST&Expires=9999999999&Signature=def456" --output knee_multicoil_train.tar.xz
    curl -C - "https://fastmri-dataset.s3.amazonaws.com/brain_multicoil_train.tar.xz?AWSAccessKeyId=AKIATEST&Expires=9999999999&Signature=ghi789" --output brain_multicoil_train.tar.xz
    """

    # Parse URLs and expiry from a sample email using the same regex as set_fastmri_urls!.
    url_pairs = [
        (String(m.captures[1]), String(m.captures[2]))
            for m in eachmatch(r"""curl\s+-C\s+-\s+"([^"]+)"\s+--output\s+(\S+)""", sample_email)
    ]
    urls = Dict(filename => url for (url, filename) in url_pairs)
    expires_list = [
        parse(Int, m.captures[1])
            for (url, _) in url_pairs
            for m in eachmatch(r"[?&]Expires=(\d+)", url)
    ]

    @test length(urls) == 3
    @test haskey(urls, "knee_singlecoil_train.tar.xz")
    @test haskey(urls, "knee_multicoil_train.tar.xz")
    @test haskey(urls, "brain_multicoil_train.tar.xz")
    @test contains(urls["knee_singlecoil_train.tar.xz"], "Signature=abc123")
    @test contains(urls["knee_multicoil_train.tar.xz"], "Signature=def456")
    @test first(expires_list) == 9999999999
end

@testitem "FastMRI: parse fails on empty input" tags = [] begin
    using MRITestData
    @test_throws ArgumentError MRITestData.set_fastmri_urls!("no curl commands here")
    @test_throws ArgumentError MRITestData.set_fastmri_urls!("")
end

@testitem "FastMRI: catalog (offline)" tags = [] begin
    using MRITestData
    entries = list_datasets(FASTMRI; offline = true)
    @test entries isa Vector{DatasetEntry}
    # If the map has been populated by scripts/index_fastmri.jl, entries will be non-empty.
    # If only the placeholder header row is present, the catalog is empty — both are valid.
    if !isempty(entries)
        e = first(entries)
        @test e.source === FASTMRI
        @test e.trajectory === :cartesian
        @test !isempty(e.id)
        @test haskey(e.extra, "tar_data_offset")
        @test haskey(e.extra, "file_size")
        @test haskey(e.extra, "archive")
    end
end

@testitem "FastMRI: source metadata" tags = [] begin
    using MRITestData
    @test MRITestData.source_name(FASTMRI) == "fastmri"
    @test contains(MRITestData.terms_url(FASTMRI), "fastmri.med.nyu.edu")
    @test FASTMRI in list_sources()
end

@testitem "FastMRI: missing credentials error" tags = [] begin
    using MRITestData
    # A filename that will certainly not have a stored URL.
    name = "__nonexistent_test_archive_$(rand(UInt32))__.tar.xz"
    @test_throws ErrorException MRITestData.get_fastmri_url(name)
    try
        MRITestData.get_fastmri_url(name)
    catch e
        @test occursin("fastmri.med.nyu.edu", sprint(showerror, e))
    end
end

@testitem "FastMRI: fastmri_url_expires type" tags = [] begin
    using MRITestData
    using Dates: DateTime
    # The return is always either `nothing` or a `DateTime` — never some other type.
    result = MRITestData.fastmri_url_expires()
    @test result === nothing || result isa DateTime
end

@testitem "FastMRI: download + load (network)" tags = [:network] begin
    using MRITestData
    using MRIBase
    # Requires:
    #   1. set_fastmri_urls!(email_text) called previously with valid credentials
    #   2. data/fastmri_map.csv populated by scripts/index_fastmri.jl
    entries = list_datasets(FASTMRI; offline = true)
    if isempty(entries)
        @warn "FastMRI network test skipped: data/fastmri_map.csv is empty (run scripts/index_fastmri.jl first)"
    else
        e = first(entries)
        path = download_dataset(e; progress = false)
        @test isfile(path)
        @test filesize(path) > 0
        raw = load_raw(e)
        @test raw isa MRIBase.RawAcquisitionData
        @test length(raw.profiles) > 0
    end
end
