@testitem "Browse: provider + column mapping (offline)" begin
    using MRITestData
    using MRITestData: _build_provider, _entry_row, _COLUMNS
    using Tachikoma.Paged: column_defs, fetch_page, supports_search, supports_filter,
        PageRequest, ColumnFilter, filter_contains, sort_none

    entries = query(; offline = true)
    @test !isempty(entries)
    n = length(entries)

    provider = _build_provider(entries)

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

@testitem "Browse: sampling/header/token modal (offline)" begin
    using MRITestData
    using MRITestData: _sampling_value, _fmt_sampling, _needs_synapse_token, _header_title,
        BrowserModel, _update_token!, DatasetEntry
    using Tachikoma: KeyEvent

    @testset "sampling column renders the same concept the same way" begin
        fully = DatasetEntry(;
            source = OCMR_SOURCE, id = "x", name = "x", fully_sampled = true,
            url = "", extra = Dict{String, Any}("sampling" => "fully sampled"),
        )
        under = DatasetEntry(;
            source = OCMR_SOURCE, id = "y", name = "y", fully_sampled = false,
            url = "", extra = Dict{String, Any}("sampling" => "pseudo-random undersampled"),
        )
        ubool = DatasetEntry(; source = MRIDATA, id = "z", name = "z", fully_sampled = false, url = "")
        unkwn = DatasetEntry(; source = MRIDATA, id = "w", name = "w", url = "")
        @test _fmt_sampling(_sampling_value(fully)) == "fully sampled"   # explicit, no glyphs
        @test _fmt_sampling(_sampling_value(under)) == "pseudo-random"
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
