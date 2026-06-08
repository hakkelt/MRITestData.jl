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
