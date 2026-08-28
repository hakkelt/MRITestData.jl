@testitem "Browse: provider + column mapping (offline)" begin
    using MRITestData
    using MRITestData: _build_provider, _entry_row, _COLUMNS
    using Tachikoma.Paged: column_defs, fetch_page, supports_search, supports_filter,
        PageRequest, ColumnFilter, filter_contains, sort_none

    entries = query(; offline = true)
    @test !isempty(entries)
    n = length(entries)

    provider, columns = _build_provider(entries)

    @testset "column definitions" begin
        cols = column_defs(provider)
        @test length(cols) == length(_COLUMNS)
        @test cols[1].name == "#"
        @test any(c -> c.name == "Size", cols)
        @test supports_search(provider)
        @test supports_filter(provider)
    end

    @testset "row carries source index in column 1" begin
        row = _entry_row(7, entries[7])
        @test row[1] == 7
        @test row[2] == MRITestData.source_name(entries[7].source)
        @test row[3] == entries[7].id
    end

    @testset "fetch_page pages and preserves index column" begin
        req = PageRequest(1, 20, 0, sort_none, Dict{Int, ColumnFilter}(), "")
        result = fetch_page(provider, req)
        @test result.total_count == n
        @test length(result.rows) == min(20, n)
        # column 1 of each row maps back to the correct DatasetEntry id
        for r in result.rows
            idx = r[1]
            @test entries[idx].id == r[3]
        end
    end

    @testset "fetch_page filter narrows results" begin
        # filter the Source column (col 2) to mridata.org
        filters = Dict(2 => ColumnFilter(filter_contains, "mridata"))
        req = PageRequest(1, 1000, 0, sort_none, filters, "")
        result = fetch_page(provider, req)
        @test result.total_count == count(e -> e.source === MRIDATA, entries)
        for r in result.rows
            @test occursin("mridata", lowercase(r[2]))
        end
    end
end

@testitem "Browse: source-adaptive extra columns (offline)" begin
    using MRITestData
    using MRITestData: _build_provider, _source_columns, _browse_highlights, BrowserModel
    using Tachikoma.Paged: column_defs

    # A single-source session gains that source's highlight columns.
    ocmr_only = list_datasets(OCMR_SOURCE; offline = true)
    cols, keys = _source_columns(ocmr_only)
    @test keys == _browse_highlights(OCMR_SOURCE)
    @test all(k -> any(c -> c.name == k, cols), keys)
    @test length(cols) == 14 + length(keys)

    provider, pcols = _build_provider(ocmr_only)
    @test pcols == cols
    @test column_defs(provider) == cols

    m = BrowserModel(ocmr_only)
    @test m.columns == cols
    @test m.size_col == findfirst(c -> c.name == "Size", cols)

    # A multi-source session (or one with no highlights, e.g. CMRxRecon-300) keeps the
    # base 14 columns — no highlight leaks in from a source not actually present.
    base_cols, base_keys = _source_columns(query(; offline = true))
    @test isempty(base_keys)
    @test length(base_cols) == 14
    cmrx300_cols, cmrx300_keys = _source_columns(list_datasets(CMRXRECON300; offline = true))
    @test isempty(cmrx300_keys)
end

@testitem "Browse: details pane (offline)" begin
    using MRITestData
    using MRITestData: BrowserModel, _update_browse!, _update_details!, DatasetEntry
    using Tachikoma: KeyEvent

    ocmr_only = list_datasets(OCMR_SOURCE; offline = true)
    m = BrowserModel(ocmr_only)
    m.pdt.selected = 1   # a valid row so `d` finds an entry to show

    # 'd' from :browse opens the pane on the selected entry.
    _update_browse!(m, KeyEvent('d'))
    @test m.stage === :details
    @test m.selected !== nothing

    # Esc closes it without quitting; 'd' also closes it (toggle).
    _update_details!(m, KeyEvent(:escape))
    @test m.stage === :browse
    @test m.selected === nothing

    m.stage = :details
    m.selected = ocmr_only[1]
    _update_details!(m, KeyEvent('d'))
    @test m.stage === :browse

    # 'q' from :details quits like everywhere else.
    m.stage = :details
    m.selected = ocmr_only[1]
    _update_details!(m, KeyEvent('q'))
    @test m.quit
end

@testitem "Browse: sampling/header/token modal (offline)" begin
    using MRITestData
    using MRITestData: _sampling_value, _fmt_sampling, _needs_synapse_token, _header_title,
        BrowserModel, _update_token!, DatasetEntry
    using Tachikoma: KeyEvent

    @testset "sampling column renders the same concept the same way" begin
        fully = DatasetEntry(; source = OCMR_SOURCE, id = "x", name = "x", fully_sampled = true, url = "")
        under = DatasetEntry(;
            source = OCMR_SOURCE, id = "y", name = "y", fully_sampled = false,
            undersampling_pattern = :pseudo_random, url = "",
        )
        ubool = DatasetEntry(; source = MRIDATA, id = "z", name = "z", fully_sampled = false, url = "")
        unkwn = DatasetEntry(; source = MRIDATA, id = "w", name = "w", url = "")
        @test _fmt_sampling(_sampling_value(fully)) == "fully sampled"   # explicit, no glyphs
        @test _fmt_sampling(_sampling_value(under)) == "pseudo_random"
        @test _fmt_sampling(_sampling_value(ubool)) == "undersampled"
        @test _fmt_sampling(_sampling_value(unkwn)) == "?"
    end

    @testset "header shows filtered count only when narrowed" begin
        @test _header_title(100, 100) == "MRI Datasets (100)"
        @test _header_title(100, 12) == "MRI Datasets (12 / 100)"
    end

    @testset "Synapse-token-needed predicate" begin
        @test _needs_synapse_token(nothing) === false
        ocmr_e = DatasetEntry(; source = OCMR_SOURCE, id = "a", name = "a", url = "")
        @test _needs_synapse_token(ocmr_e) === false
        cmr_e = first(list_datasets(CMRXRECON2024; offline = true))
        # Only CMRxRecon needs a token, and only when none is configured.
        @test _needs_synapse_token(cmr_e) == isempty(get_synapse_token())
    end

    @testset ":token stage accepts input and Esc returns without saving" begin
        m = BrowserModel(list_datasets(CMRXRECON2024; offline = true))
        m.stage = :token
        _update_token!(m, KeyEvent('p'))
        _update_token!(m, KeyEvent('w'))
        @test MRITestData.text(m.token_input) == "pw"
        _update_token!(m, KeyEvent(:escape))      # Esc: back to confirm, no set_synapse_token!
        @test m.stage == :confirm
    end
end

@testitem "browse: size prefetch covers the adjacent pages of the current view" begin
    using MRITestData
    using MRITestData: BrowserModel, _prefetch_indices, _COLUMNS, DatasetEntry
    using Tachikoma.Paged: pdt_fetch!, sort_desc

    # 55 entries over pages of 20: page 2 must prefetch pages 1..3, and those indices must
    # be the ones the provider would actually display — not a raw slice of `entries`,
    # which diverges as soon as a sort or filter is active.
    entries = [
        DatasetEntry(;
                source = OCMR_SOURCE, id = "e$(lpad(i, 2, '0'))", name = "Entry $i",
                anatomy = :heart, url = "",
            ) for i in 1:55
    ]
    m = BrowserModel(entries)
    m.pdt.page = 2
    pdt_fetch!(m.pdt)

    got = sort(_prefetch_indices(m))
    @test got == collect(1:55)   # pages 1..3 of 20, clamped to the 55 rows

    # Sort descending by ID: the window must follow the sorted view, so page 2's
    # neighbourhood is now the *last* 55 entries in reverse.
    m.pdt.sort_col = findfirst(c -> c.name == "ID", _COLUMNS)
    m.pdt.sort_dir = sort_desc
    pdt_fetch!(m.pdt)
    sorted_ids = _prefetch_indices(m)
    @test length(sorted_ids) == 55        # 3 pages of 20, clamped to the 55 rows
    @test sort(sorted_ids) == collect(1:55)

    # With a filter narrowing the view to a single page, only those rows are prefetched.
    m.pdt.sort_col = 0
    m.pdt.search_query = "e01"
    m.pdt.page = 1
    pdt_fetch!(m.pdt)
    @test _prefetch_indices(m) == [1]
end

@testitem "browse: quitting records why" begin
    using MRITestData
    using MRITestData: BrowserModel, DownloadRequest, _quit!, DatasetEntry

    entries = [DatasetEntry(; source = OCMR_SOURCE, id = "x", name = "X", url = "")]

    m = BrowserModel(entries)
    @test m.request === nothing
    _quit!(m)
    @test m.quit
    @test m.request === nothing          # a plain quit leaves no work behind

    m2 = BrowserModel(entries)
    _quit!(m2, DownloadRequest(entries[1], "/tmp/out.h5"))
    @test m2.quit
    @test m2.request isa DownloadRequest
    @test m2.request.dest == "/tmp/out.h5"
    @test m2.request.entry.id == "x"
end

@testitem "browse: app source selection" begin
    using MRITestData
    using MRITestData: _browser_sources

    @test _browser_sources(String[]) == list_sources()
    @test _browser_sources(["--offline"]) == list_sources()
    @test _browser_sources(["--source", "ocmr"]) == [OCMR_SOURCE]
    @test Set(_browser_sources(["--source", "ocmr", "--source", "m4raw"])) ==
        Set([OCMR_SOURCE, M4RAW])
    @test_throws ErrorException _browser_sources(["--source", "nope"])
    # A trailing --source with no value names nothing, so every source is browsed.
    @test _browser_sources(["--source"]) == list_sources()
end
