# ── Browse ────────────────────────────────────────────────────────────────────
# Interactive full-screen dataset browser built on Tachikoma.jl's PagedDataTable.
# Can be used directly from the Julia REPL via `run_browser()`, or installed as
# the standalone shell command `mridata-browser` via Pkg.Apps.

using Tachikoma
using Tachikoma.Paged
# Extended with new methods, so they must be imported by name.
import Tachikoma: view, update!, should_quit, task_queue, pre_render!

# ── Column definitions ────────────────────────────────────────────────────────
#
# The cell *values* and their formatters are cross-source concerns and live in
# `catalog/display.jl` (`_sampling_value`, `_fmt_*`), which has no TTY
# dependency; this file only wires them into the table.

# Column 1 holds the entry's index into the `entries` vector so the selected
# row maps back to a DatasetEntry even after sorting/filtering.
const _COLUMNS = PagedColumn[
    PagedColumn("#"; align = col_right, filterable = false, col_type = :numeric),
    PagedColumn("Source"; col_type = :text),
    PagedColumn("ID"; col_type = :text),
    PagedColumn("Anatomy"; format = _fmt_sym, col_type = :text),
    PagedColumn("Contrast"; format = _fmt_sym, col_type = :text),
    PagedColumn("B₀ [T]"; align = col_right, format = _fmt_b0, col_type = :numeric),
    PagedColumn("Trajectory"; format = _fmt_sym, col_type = :text),
    PagedColumn("Channels"; align = col_right, format = _fmt_channels, col_type = :text),
    PagedColumn("Sampling"; format = _fmt_sampling, col_type = :text),
    PagedColumn("R"; align = col_right, format = _fmt_accel, col_type = :numeric),
    PagedColumn("Frames"; align = col_right, col_type = :numeric),
    PagedColumn("Split"; format = _fmt_sym, col_type = :text),
    PagedColumn("Cached"; col_type = :text),
    PagedColumn("Size"; align = col_right, format = _fmt_size, col_type = :numeric),
]

# The index column carries the entry index; the size column is refreshed in place as
# background prefetches land, so both are looked up by name rather than hard-coded.
const _INDEX_COL = findfirst(c -> c.name == "#", _COLUMNS)::Int
const _SIZE_COL = findfirst(c -> c.name == "Size", _COLUMNS)::Int

# ✓ when the file is already in the Scratch cache — a local check, no network, and the
# single highest-value column for day-to-day use. Guarded because the precompile workload
# builds a BrowserModel before `__init__` has set `CACHE_DIR`.
_fmt_cached(e::DatasetEntry) = isempty(CACHE_DIR[]) ? "" : (is_cached(e) ? "✓" : "")

# Any `extra` value stringified for display; `nothing`/absent reads as "?" like every
# other cross-source cell.
_fmt_extra_value(v) = v === nothing ? "?" : string(v)

# ── Source-adaptive extra columns ──────────────────────────────────────────────
#
# When a browse session covers exactly one source, a couple of that source's most useful
# `extra` keys (see `extra_schema`) are appended as real columns — sortable/filterable
# like any other — instead of being reachable only through the details pane (`d`).
# Sources whose useful metadata is already all in core fields (CMRxRecon300, M4Raw,
# FastMRI) have nothing to add here and keep the base column set.
_browse_highlights(::AbstractSource) = String[]
_browse_highlights(::OCMR) = ["scanner_model"]
_browse_highlights(::CMRxRecon2024) = ["repetition_time_ms", "echo_time_ms"]
_browse_highlights(::USCSpeech) = ["protocol_name"]
_browse_highlights(::MridataOrg) = ["protocol_name"]

# The columns and highlight `extra` keys for a set of entries: the base set, plus that
# source's highlights when every entry comes from the same source (only the keys its
# `extra_schema` actually documents, so a stale hard-coded key can't slip through).
function _source_columns(entries::Vector{DatasetEntry})
    isempty(entries) && return _COLUMNS, String[]
    src = entries[1].source
    all(e -> e.source === src, entries) || return _COLUMNS, String[]
    schema = extra_schema(src)
    keys = filter(k -> haskey(schema, k), _browse_highlights(src))
    isempty(keys) && return _COLUMNS, String[]
    extra_cols = [PagedColumn(k; col_type = :text) for k in keys]
    return vcat(_COLUMNS, extra_cols), keys
end

function _entry_row(i::Int, e::DatasetEntry, highlight_keys::Vector{String} = String[])
    row = Any[
        i,
        source_name(e.source),
        e.id,
        e.anatomy,
        e.contrast,
        e.field_strength,
        e.trajectory,
        e.receiver_channels,
        _sampling_value(e),
        # NaN, not `nothing`: an all-Float64 column lets Tachikoma sort the R column
        # without hitting `isless(::Nothing, ::Float64)`, and NaN already sorts last
        # ascending / first descending under Julia's total order on Float64.
        something(e.acceleration, NaN),
        e.num_frames,
        e.split,
        _fmt_cached(e),
        e.approx_size_bytes,
    ]
    for k in highlight_keys
        push!(row, _fmt_extra_value(get(e.extra, k, nothing)))
    end
    return row
end

"""
    _build_provider(entries, indices = 1:length(entries); visible = nothing)

Build an `InMemoryPagedProvider` over `entries[indices]` (`indices` are positions into
`entries`, not a re-numbered 1:n range — the `"#"` column keeps carrying the *global*
index so [`_selected_entry`](@ref) and the size-prefetch machinery keep mapping back into
`entries` correctly after a query narrows the row set), optionally projected down to the
column names in `visible` (`nothing` = every column). `"#"` is always kept regardless of
`visible`, and always stays column 1.
"""
function _build_provider(
        entries::Vector{DatasetEntry}, indices = 1:length(entries);
        visible::Union{Nothing, Vector{String}} = nothing,
    )
    all_columns, highlight_keys = _source_columns(entries)
    keep_pos = [
        i for (i, c) in enumerate(all_columns)
            if c.name == "#" || visible === nothing || c.name in visible
    ]
    columns = all_columns[keep_pos]
    ncols = length(columns)
    data = [Vector{Any}(undef, length(indices)) for _ in 1:ncols]
    for (row_i, gi) in enumerate(indices)
        row = _entry_row(gi, entries[gi], highlight_keys)
        for (c, pos) in enumerate(keep_pos)
            data[c][row_i] = row[pos]
        end
    end
    return InMemoryPagedProvider(columns, data), columns
end

# A page request for an arbitrary page of `pdt`, carrying its current sort, filters and
# search so a fetched page matches what the user would see on scrolling there.
function _page_request(pdt::PagedDataTable, page::Int)
    return PageRequest(
        page, pdt.page_size, pdt.sort_col, pdt.sort_dir,
        Dict{Int, ColumnFilter}(k => v for (k, v) in pdt.filters if !isempty(v.value)),
        pdt.search_query,
    )
end

_max_page(pdt::PagedDataTable) = max(1, cld(pdt.total_count, pdt.page_size))

# Entry indices carried by the index column of a fetched/displayed page, dropping any row
# whose index is not a valid position in `entries`.
function _row_entry_indices(rows, total::Int)
    return Int[
        row[_INDEX_COL] for row in rows
            if row[_INDEX_COL] isa Integer && 1 <= row[_INDEX_COL] <= total
    ]
end

# ── Model ─────────────────────────────────────────────────────────────────────

# stage:
#   :browse   — the paged table is active
#   :confirm  — download confirmation overlay (y/n)
#   :token    — Synapse PAT input overlay (shown for CMRxRecon2024 when no token is set)
#   :path     — destination path input overlay
#   :details  — every `extra` key of the selected entry, with its extra_schema
#               description and query keyword
"""
    DownloadRequest(entry, dest)

What the browser was asked to do on the way out. The TUI cannot download while it owns the
terminal, so confirming a download quits the event loop and leaves this behind for
[`run_browser`](@ref) to act on; quitting without one leaves `nothing`.
"""
struct DownloadRequest
    entry::DatasetEntry
    dest::String
end

mutable struct BrowserModel <: Model
    entries::Vector{DatasetEntry}
    pdt::PagedDataTable
    columns::Vector{PagedColumn}  # base columns, plus this session's source-adaptive ones
    size_col::Union{Nothing, Int}      # position of "Size" in `columns`; nothing when hidden
    # local-row-index (into `pdt.provider.data`) for each global `entries` index currently
    # shown — recomputed by `_rebuild_provider!` whenever the query/column selection
    # changes, so the size-prefetch patch (below) can still find the right provider row.
    row_index_of::Dict{Int, Int}
    stage::Symbol
    selected::Union{Nothing, DatasetEntry}
    path_input::TextInput
    token_input::TextInput
    quit::Bool
    # Why the loop exited: `nothing` for a plain quit, a request to act on otherwise.
    request::Union{Nothing, DownloadRequest}
    # background size-fetching
    tq::TaskQueue
    last_prefetch_page::Int      # page number for which we last fired a prefetch
    prefetch_generation::Int     # incremented each time we fire; used to discard stale results
    # expression query overlay (`/`)
    active_query::String                       # applied query text; "" = none
    active_query_indices::Union{Nothing, Vector{Int}}  # matching global `entries` indices
    expr_input::TextInput
    query_error::String
    # column-visibility picker (`c`)
    visible_columns::Union{Nothing, Vector{String}}    # nothing = every column shown
    column_cursor::Int
    column_toggle::Vector{Bool}   # working copy while the picker is open
    # Missing-value filter — column name → `:present` (keep only entries that carry a value)
    # or `:missing` (keep only entries that don't). Cycled from the filter modal (`p`);
    # applied by `_rebuild_provider!` alongside the expression query.
    missingness_filters::Dict{String, Symbol}
end

# Persisted browser column selection (the `c` picker). Stored in `LocalPreferences.toml`
# as the list of visible column names; an absent preference means "show every column".
function _load_persisted_columns()::Union{Nothing, Vector{String}}
    v = load_preference(MRITestData, "browser_columns", nothing)
    v === nothing && return nothing
    return String[String(x) for x in v]
end

function _persist_columns(visible::Union{Nothing, Vector{String}})
    set_preferences!(
        MRITestData, "browser_columns" => visible;
        export_prefs = false, force = true,
    )
    return nothing
end

function BrowserModel(
        entries::Vector{DatasetEntry};
        visible_columns::Union{Nothing, Vector{String}} = nothing,
    )
    provider, columns = _build_provider(entries; visible = visible_columns)
    pdt = PagedDataTable(provider; page_size = 20, page_sizes = Int[20, 30, 50, 100])
    tq = TaskQueue()
    size_col = findfirst(c -> c.name == "Size", columns)
    row_index_of = Dict{Int, Int}(i => i for i in 1:length(entries))
    return BrowserModel(
        entries,
        pdt,
        columns,
        size_col,
        row_index_of,
        :browse,
        nothing,
        TextInput(; label = "Path: ", focused = true),
        TextInput(; label = "Token: ", focused = true),
        false,
        nothing,
        tq,
        0,
        0,
        "",
        nothing,
        TextInput(; label = "Search: ", focused = true),
        "",
        visible_columns,
        1,
        Bool[],
        Dict{String, Symbol}(),
    )
end

# Whether entry `e` carries a real (non-missing) value for the column named `name` — the
# predicate behind the filter modal's `p` cycle. Unknown symbol vocab (`:unknown`) and
# `nothing` both count as missing; identity columns are always present.
function _column_present(e::DatasetEntry, name::AbstractString)
    name == "#" && return true
    name == "Source" && return true
    name == "ID" && return true
    name == "Anatomy" && return e.anatomy !== :unknown
    name == "Contrast" && return e.contrast !== :unknown
    name == "B₀ [T]" && return e.field_strength !== nothing
    name == "Trajectory" && return e.trajectory !== :unknown
    name == "Channels" && return e.receiver_channels !== nothing
    name == "Sampling" && return _sampling_value(e) !== nothing
    name == "R" && return e.acceleration !== nothing
    name == "Frames" && return e.num_frames !== nothing
    name == "Split" && return e.split !== nothing
    name == "Cached" && return true
    name == "Size" && return e.approx_size_bytes !== nothing
    # Any source-adaptive extra column: its name is the `extra` key.
    return get(e.extra, name, nothing) !== nothing
end

# Rebuild `m.pdt`'s provider from the current `active_query_indices` (nothing = every
# entry) and `visible_columns` (nothing = every column) — the single place both the query
# overlay and the column-visibility picker apply their result.
function _rebuild_provider!(m::BrowserModel)
    base = m.active_query_indices === nothing ? (1:length(m.entries)) : m.active_query_indices
    indices = if isempty(m.missingness_filters)
        collect(base)
    else
        [
            i for i in base
                if all(pairs(m.missingness_filters)) do (name, want)
                    present = _column_present(m.entries[i], name)
                    want === :present ? present : !present
            end
        ]
    end
    provider, columns = _build_provider(m.entries, indices; visible = m.visible_columns)
    # Preserve the per-column filter/sort state when the column set is unchanged (only the
    # row set moved) — its keys are column indices, which stay valid. A changed column set
    # has to reset them (`pdt_set_provider!`), since those indices would now be wrong.
    same_columns =
        length(columns) == length(m.pdt.columns) &&
        all(((a, b),) -> a.name == b.name, zip(columns, m.pdt.columns))
    m.columns = columns
    m.size_col = findfirst(c -> c.name == "Size", columns)
    m.row_index_of = Dict{Int, Int}(gi => li for (li, gi) in enumerate(indices))
    if same_columns
        m.pdt.provider = provider
        m.pdt.columns = columns
        m.pdt.page = 1
        pdt_fetch!(m.pdt)
    else
        pdt_set_provider!(m.pdt, provider)
    end
    m.last_prefetch_page = 0
    m.prefetch_generation += 1
    return nothing
end

# Filter modal `p`: cycle the highlighted column's missing-value filter
# (none → present → missing → none), then close the modal and re-filter.
function _cycle_missingness_filter!(m::BrowserModel, col_idx::Int)
    (col_idx < 1 || col_idx > length(m.columns)) && return nothing
    name = m.columns[col_idx].name
    name == "#" && return nothing
    cur = get(m.missingness_filters, name, nothing)
    nxt = cur === nothing ? :present : cur === :present ? :missing : nothing
    nxt === nothing ? delete!(m.missingness_filters, name) : (m.missingness_filters[name] = nxt)
    m.pdt.filter_modal.visible = false
    _rebuild_provider!(m)
    return nothing
end

# Filter modal `x`: drop every active filter — the per-column filters, the missing-value
# restrictions, and the expression query — back to the full catalog.
function _clear_all_filters!(m::BrowserModel)
    empty!(m.pdt.filters)
    empty!(m.missingness_filters)
    m.active_query = ""
    m.active_query_indices = nothing
    m.query_error = ""
    m.pdt.filter_modal.visible = false
    _rebuild_provider!(m)
    return nothing
end

# CMRxRecon (2024 and -300) downloads require a Synapse Personal Access Token. An entry
# needs the token-entry modal when it comes from a Synapse source and none is configured.
_needs_synapse_token(e::DatasetEntry) =
    (e.source isa CMRxRecon2024 || e.source isa CMRxRecon300) && isempty(get_synapse_token())
_needs_synapse_token(::Nothing) = false

should_quit(m::BrowserModel) = m.quit
task_queue(m::BrowserModel) = m.tq

# Leave the event loop, optionally with work for `run_browser` to do once the terminal is
# released. Both exits go through here so "quit" and "quit in order to download" are
# visibly the same decision with different payloads.
function _quit!(m::BrowserModel, request::Union{Nothing, DownloadRequest} = nothing)
    m.request = request
    m.quit = true
    return nothing
end

# Map the currently-selected table row back to its DatasetEntry.
function _selected_entry(m::BrowserModel)
    pdt = m.pdt
    (pdt.selected < 1 || pdt.selected > length(pdt.rows)) && return nothing
    idx = pdt.rows[pdt.selected][_INDEX_COL]
    idx isa Integer || return nothing
    (idx < 1 || idx > length(m.entries)) && return nothing
    return m.entries[idx]
end

# ── Size prefetch ──────────────────────────────────────────────────────────────

# Entry indices for the window of pages to prefetch: the visible page plus one page on
# each side. The provider is sorted/filtered, so a raw slice of `m.entries` around the
# current page would name entries the user will never scroll to; the adjacent pages are
# fetched through the provider instead, with the table's current sort, filters and search,
# so they are exactly the rows a page up/down would show.
#
# `fetch_page` re-filters and re-sorts the whole catalog, so this runs only on a page
# change (see `_maybe_prefetch!`), never per frame.
function _prefetch_indices(m::BrowserModel)
    pdt = m.pdt
    total = length(m.entries)
    total == 0 && return Int[]

    indices = _row_entry_indices(pdt.rows, total)
    last_page = _max_page(pdt)
    for page in (pdt.page - 1, pdt.page + 1)
        (page < 1 || page > last_page || page == pdt.page) && continue
        result = fetch_page(pdt.provider, _page_request(pdt, page))
        append!(indices, _row_entry_indices(result.rows, total))
    end
    return unique!(indices)
end

# Fire a background fetch_sizes task for the current page window.
function _fire_prefetch!(m::BrowserModel)
    indices = _prefetch_indices(m)
    isempty(indices) && return
    # Only fetch entries that still lack a size.
    to_fetch = [m.entries[i] for i in indices if m.entries[i].approx_size_bytes === nothing]
    isempty(to_fetch) && return
    gen = m.prefetch_generation
    fetch_indices = indices
    return spawn_task!(m.tq, :size_prefetch) do
        sized = fetch_sizes(to_fetch)
        # Build a map uuid→size for the fetched entries
        sizes = Dict{String, Int}()
        for e in sized
            e.approx_size_bytes === nothing && continue
            sizes[e.id] = e.approx_size_bytes
        end
        (gen, fetch_indices, sizes)
    end
end

# Called from pre_render! each frame; detects page changes and triggers prefetch.
function _maybe_prefetch!(m::BrowserModel)
    m.stage === :browse || return
    pdt = m.pdt
    pdt.page == m.last_prefetch_page && return
    m.last_prefetch_page = pdt.page
    m.prefetch_generation += 1
    return _fire_prefetch!(m)
end

pre_render!(m::BrowserModel) = _maybe_prefetch!(m)

# ── Event handling ────────────────────────────────────────────────────────────

function update!(m::BrowserModel, evt::KeyEvent)
    m.stage === :browse && return _update_browse!(m, evt)
    m.stage === :confirm && return _update_confirm!(m, evt)
    m.stage === :token && return _update_token!(m, evt)
    m.stage === :path && return _update_path!(m, evt)
    m.stage === :details && return _update_details!(m, evt)
    m.stage === :query && return _update_query!(m, evt)
    m.stage === :columns && return _update_columns!(m, evt)
    return nothing
end

function update!(m::BrowserModel, evt::MouseEvent)
    m.stage === :browse && handle_mouse!(m.pdt, evt)
    return nothing
end

# Handle size-prefetch results arriving from the background TaskQueue.
function update!(m::BrowserModel, evt::TaskEvent{Tuple{Int, Vector{Int}, Dict{String, Int}}})
    evt.id === :size_prefetch || return
    gen, fetch_indices, sizes = evt.value
    gen == m.prefetch_generation || return   # stale result from an old page
    isempty(sizes) && return

    # Only the Size column changes, so it's patched in place via `row_index_of` (the
    # provider may show a query-filtered subset of `m.entries`, in a different row count
    # and order). Replacing the provider would re-box every cell of every column and reset
    # page/sort/filter/search, which would then have to be saved and restored around it.
    # `m.size_col` is `nothing` when the Size column is currently hidden — `m.entries` is
    # still updated below so a re-shown Size column picks up the fetched value later.
    size_column = m.size_col === nothing ? nothing : m.pdt.provider.data[m.size_col]
    changed = false
    for i in fetch_indices
        (i < 1 || i > length(m.entries)) && continue
        e = m.entries[i]
        e.approx_size_bytes === nothing || continue
        sz = get(sizes, e.id, nothing)
        sz === nothing && continue
        m.entries[i] = _with_size(e, sz)
        if size_column !== nothing
            li = get(m.row_index_of, i, nothing)
            li === nothing || (size_column[li] = sz)
        end
        changed = true
    end

    changed && pdt_fetch!(m.pdt)   # re-derive the visible rows from the patched column
    return nothing
end

# Fallback handler for other TaskEvent types (e.g. errors from the fetch task).
update!(m::BrowserModel, ::TaskEvent) = nothing

function _update_browse!(m::BrowserModel, evt::KeyEvent)
    pdt = m.pdt
    # While the table's own sub-inputs are open, delegate everything to it — except two
    # extra shortcuts on the filter modal's column-list section (no text entry there, so
    # the plain letters are free): `p` cycles the column's present/missing filter, `x`
    # clears every active filter.
    if pdt.search_visible || pdt.filter_modal.visible || pdt.goto_visible
        if pdt.filter_modal.visible && pdt.filter_modal.section == 1 && evt.key == :char
            if evt.char == 'p' || evt.char == 'P'
                return _cycle_missingness_filter!(m, pdt.filter_modal.col_cursor)
            elseif evt.char == 'x' || evt.char == 'X'
                return _clear_all_filters!(m)
            end
        end
        handle_key!(pdt, evt)
        return nothing
    end

    if evt.key == :enter
        e = _selected_entry(m)
        if e !== nothing
            m.selected = e
            set_text!(m.path_input, joinpath(pwd(), basename(cache_path(e))))
            m.stage = :confirm
        end
        return nothing
    end

    if evt.key == :char && evt.char == 'd'
        e = _selected_entry(m)
        if e !== nothing
            m.selected = e
            m.stage = :details
        end
        return nothing
    end

    # `s` (and `/` as an alias) opens the search / expression-query overlay, intercepted
    # here so `/` never reaches Tachikoma's own substring search in `handle_key!` below.
    if evt.key == :char && (evt.char == 's' || evt.char == 'S' || evt.char == '/')
        set_text!(m.expr_input, m.active_query)
        m.query_error = ""
        m.stage = :query
        return nothing
    end

    if evt.key == :char && evt.char == 'c'
        all_columns, _ = _source_columns(m.entries)
        toggleable = filter(c -> c.name != "#", all_columns)
        m.column_toggle = [
            m.visible_columns === nothing || c.name in m.visible_columns
                for c in toggleable
        ]
        m.column_cursor = 1
        m.stage = :columns
        return nothing
    end

    if (evt.key == :char && evt.char == 'q') || evt.key == :escape
        return _quit!(m)
    end

    handle_key!(pdt, evt)
    return nothing
end

function _update_details!(m::BrowserModel, evt::KeyEvent)
    # `q` closes the pane rather than quitting the app: in a read-only sub-view it reads as
    # "close this", and it isn't advertised as quit (see `_render_details!`).
    if evt.key == :escape || (evt.key == :char && evt.char in ('d', 'q', 'Q'))
        m.selected = nothing
        m.stage = :browse
    end
    return nothing
end

function _update_query!(m::BrowserModel, evt::KeyEvent)
    if evt.key == :escape
        m.query_error = ""
        m.stage = :browse
        return nothing
    end
    if evt.key == :enter
        txt = strip(text(m.expr_input))
        if isempty(txt)
            m.active_query = ""
            m.active_query_indices = nothing
            m.query_error = ""
            _rebuild_provider!(m)
            m.stage = :browse
            return nothing
        end
        try
            pred = _compile_query_expr(parse_query_expr(txt), _query_sources(m))
            m.active_query = String(txt)
            m.active_query_indices = [i for (i, e) in enumerate(m.entries) if pred(e)]
            m.query_error = ""
            _rebuild_provider!(m)
            m.stage = :browse
        catch err
            err isa QueryParseError || rethrow()
            m.query_error = sprint(showerror, err)
        end
        return nothing
    end
    handle_key!(m.expr_input, evt)
    return nothing
end

# The sources actually present among `m.entries` — used to validate/resolve `extra` field
# names in a query the same way `query(text; sources = ...)` would for this session.
_query_sources(m::BrowserModel) = unique(e.source for e in m.entries)

function _update_columns!(m::BrowserModel, evt::KeyEvent)
    n = length(m.column_toggle)
    if evt.key == :escape
        m.stage = :browse
    elseif evt.key == :up
        n > 0 && (m.column_cursor = max(1, m.column_cursor - 1))
    elseif evt.key == :down
        n > 0 && (m.column_cursor = min(n, m.column_cursor + 1))
    elseif evt.key == :char && evt.char == ' '
        if n > 0
            m.column_toggle[m.column_cursor] = !m.column_toggle[m.column_cursor]
        end
    elseif evt.key == :enter
        all_columns, _ = _source_columns(m.entries)
        toggleable = filter(c -> c.name != "#", all_columns)
        shown = [c.name for (c, on) in zip(toggleable, m.column_toggle) if on]
        m.visible_columns = length(shown) == length(toggleable) ? nothing : shown
        _rebuild_provider!(m)
        m.stage = :browse
    end
    return nothing
end

function _update_confirm!(m::BrowserModel, evt::KeyEvent)
    if evt.key == :char && (evt.char == 'y' || evt.char == 'Y')
        # Synapse-backed sources need a PAT first; otherwise go straight to the path.
        m.stage = _needs_synapse_token(m.selected) ? :token : :path
    elseif evt.key == :escape || (evt.key == :char && (evt.char == 'n' || evt.char == 'N'))
        m.selected = nothing
        m.stage = :browse
    elseif evt.key == :char && (evt.char == 'q' || evt.char == 'Q')
        return _quit!(m)
    end
    return nothing
end

function _update_token!(m::BrowserModel, evt::KeyEvent)
    if evt.key == :escape
        m.stage = :confirm
        return nothing
    end
    if evt.key == :enter
        tok = strip(text(m.token_input))
        if !isempty(tok)
            set_synapse_token!(String(tok))
            set_text!(m.token_input, "")
            m.stage = :path
        end
        return nothing
    end
    handle_key!(m.token_input, evt)
    return nothing
end

function _update_path!(m::BrowserModel, evt::KeyEvent)
    if evt.key == :escape
        m.stage = :confirm
        return nothing
    end
    if evt.key == :enter
        e = m.selected
        if e !== nothing
            dest = strip(text(m.path_input))
            isempty(dest) && (dest = joinpath(pwd(), _cache_basename(e)))
            # Leave the TUI; the download runs once app() releases the terminal.
            _quit!(m, DownloadRequest(e, String(dest)))
        end
        return nothing
    end
    handle_key!(m.path_input, evt)
    return nothing
end

# ── Rendering ─────────────────────────────────────────────────────────────────

# Table title: the full dataset count, or "shown / total" when a filter/search narrows it.
_header_title(total::Int, shown::Int) = shown == total ? "MRI Datasets ($(total))" : "MRI Datasets ($(shown) / $(total))"

const _HELP_BAR = StatusBar(
    left = [
        Span(" ↑↓ ", tstyle(:accent)),
        Span("move  ", tstyle(:text_dim)),
        Span("PgUp/PgDn ", tstyle(:accent)),
        Span("page  ", tstyle(:text_dim)),
        Span("s ", tstyle(:accent)),
        Span("search  ", tstyle(:text_dim)),
        Span("f ", tstyle(:accent)),
        Span("filter  ", tstyle(:text_dim)),
        Span("c ", tstyle(:accent)),
        Span("columns  ", tstyle(:text_dim)),
        Span("1-9 ", tstyle(:accent)),
        Span("sort  ", tstyle(:text_dim)),
        Span("Enter ", tstyle(:accent)),
        Span("download  ", tstyle(:text_dim)),
        Span("d ", tstyle(:accent)),
        Span("details  ", tstyle(:text_dim)),
        Span("q ", tstyle(:accent)),
        Span("quit", tstyle(:text_dim)),
    ],
)

function view(m::BrowserModel, f::Frame)
    buf = f.buffer
    area = f.area
    # Reserve the last row for the help bar.
    table_area = Rect(area.x, area.y, area.width, max(1, area.height - 1))
    bar_area = Rect(area.x, bottom(area), area.width, 1)
    # Show the filtered/searched count vs the full total when any filter is active.
    m.pdt.block = Block(
        title = _header_title(length(m.entries), m.pdt.total_count),
        border_style = tstyle(:border),
        title_style = tstyle(:title),
    )
    render(m.pdt, table_area, buf)
    render(_HELP_BAR, bar_area, buf)

    # Tachikoma owns the filter modal; add the two extra shortcuts as a hint above it.
    if m.pdt.filter_modal.visible && m.pdt.filter_modal.section == 1
        set_string!(
            buf, area.x + 2, area.y + 1,
            "p  cycle present / missing        x  clear all filters",
            tstyle(:text_dim),
        )
    end

    m.stage === :confirm && _render_confirm!(m, area, buf)
    m.stage === :token && _render_token!(m, area, buf)
    m.stage === :path && _render_path!(m, area, buf)
    m.stage === :details && _render_details!(m, area, buf)
    m.stage === :query && _render_query!(m, area, buf)
    m.stage === :columns && _render_columns!(m, area, buf)
    return nothing
end

function _render_confirm!(m::BrowserModel, area::Rect, buf)
    e = m.selected
    e === nothing && return
    size_str = e.approx_size_bytes === nothing ? "unknown" : _human_bytes(e.approx_size_bytes)
    lines = [
        "Download this dataset?",
        "",
        "Name:   $(e.name)",
        "Source: $(source_name(e.source))",
        "Size:   $size_str",
        "",
        "! Review terms of use before downloading:",
        "  $(terms_url(e.source))",
        "",
        "[y] yes   [n] no   [q] quit",
    ]
    _render_modal!(area, buf, " Confirm ", lines)
    return nothing
end

function _render_path!(m::BrowserModel, area::Rect, buf)
    m.selected === nothing && return
    _render_input_modal!(
        area, buf, " Download path ", m.path_input;
        width = 64,
        lines = [("Enter to confirm, Esc to go back:", tstyle(:text_dim))],
    )
    return nothing
end

# Expression query overlay (`/`): a single-line input plus, when the last attempt failed to
# parse, the error message underneath (styled distinctly so a typo is obvious at a glance).
function _render_query!(m::BrowserModel, area::Rect, buf)
    lines = [
        ("e.g.  dataset=fastmri AND R<3   |   id='fs_*'   |   size < 100M   |   R != nothing", tstyle(:text_dim)),
        ("Esc to cancel, Enter to apply", tstyle(:text_dim)),
    ]
    isempty(m.query_error) || push!(lines, (m.query_error, tstyle(:error)))
    _render_input_modal!(area, buf, " Search ", m.expr_input; width = 82, lines = lines)
    return nothing
end

# Column-visibility picker (`c`): a checklist of every column this session could show,
# `"#"` excluded (it's always shown — the internal row/entry key).
function _render_columns!(m::BrowserModel, area::Rect, buf)
    all_columns, _ = _source_columns(m.entries)
    toggleable = filter(c -> c.name != "#", all_columns)
    lines = String[]
    for (i, c) in enumerate(toggleable)
        mark = i <= length(m.column_toggle) && m.column_toggle[i] ? "x" : " "
        cursor = i == m.column_cursor ? "> " : "  "
        push!(lines, "$(cursor)[$(mark)] $(c.name)")
    end
    push!(lines, "")
    push!(lines, "[↑↓] move   [Space] toggle   [Enter] apply   [Esc] cancel")
    _render_modal!(area, buf, " Columns ", lines)
    return nothing
end

# Greedy word-wrap `s` to lines no wider than `width` (a word longer than `width` still
# gets its own over-long line rather than being split mid-word).
function _wrap_text(s::AbstractString, width::Int)
    width <= 0 && return [String(s)]
    words = split(s)
    isempty(words) && return [""]
    out = String[]
    cur = ""
    for w in words
        cand = isempty(cur) ? String(w) : "$cur $w"
        if isempty(cur) || textwidth(cand) <= width
            cur = cand
        else
            push!(out, cur)
            cur = String(w)
        end
    end
    push!(out, cur)
    return out
end

# Every `extra` key of the selected entry, with its `extra_schema` description and its
# query keyword (`extra` keys and query keywords are the same string — see `query`) — the
# details pane that makes `extra` filtering stop being guess-and-check.
function _render_details!(m::BrowserModel, area::Rect, buf)
    e = m.selected
    e === nothing && return
    schema = extra_schema(e.source)
    lines = String[
        "Name:   $(e.name)",
        "Source: $(source_name(e.source))",
        "ID:     $(e.id)",
        "",
    ]
    if isempty(schema)
        push!(lines, "(this source has no extra metadata beyond the core fields)")
    else
        keys_sorted = sort!(collect(keys(schema)))
        vals = Dict(k => _fmt_extra_value(get(e.extra, k, nothing)) for k in keys_sorted)
        # Fit `keyword │ value │ description` into the modal: the table line width is capped
        # so `_render_modal!` never draws past the frame; value gets at most a third of the
        # leftover, description takes the rest and wraps.
        line_w = clamp(area.width - 8, 40, 108)
        wk = min(max(maximum(textwidth, keys_sorted; init = 0), textwidth("query keyword")), line_w ÷ 2)
        wv = clamp(maximum(textwidth, values(vals); init = 0), textwidth("value"), max(8, (line_w - wk - 6) ÷ 3))
        wd = max(16, line_w - wk - wv - 6)
        push!(lines, "$(rpad("query keyword", wk)) │ $(rpad("value", wv)) │ $(rpad("description", wd))")
        push!(lines, "$(rpad("", wk, '─'))─┼─$(rpad("", wv, '─'))─┼─$(rpad("", wd, '─'))")
        for k in keys_sorted
            dsegs = _wrap_text(schema[k], wd)
            vsegs = _wrap_text(vals[k], wv)
            for j in 1:max(length(dsegs), length(vsegs))
                kcell = j == 1 ? rpad(k, wk) : " "^wk
                vcell = rpad(j <= length(vsegs) ? vsegs[j] : "", wv)
                dcell = j <= length(dsegs) ? dsegs[j] : ""
                push!(lines, "$kcell │ $vcell │ $dcell")
            end
        end
    end
    push!(lines, "")
    push!(lines, "[Esc / d] back")
    _render_modal!(area, buf, " Details ", lines)
    return nothing
end

function _render_token!(m::BrowserModel, area::Rect, buf)
    _render_input_modal!(
        area, buf, " Synapse access token ", m.token_input;
        width = 72,
        lines = [
            ("CMRxRecon downloads need a Synapse Personal Access Token.", tstyle(:text)),
            ("Paste it below (stored in LocalPreferences.toml for reuse).", tstyle(:text_dim)),
            ("", tstyle(:text_dim)),
            ("", tstyle(:text_dim)),
            ("Enter to save & continue, Esc to go back:", tstyle(:text_dim)),
        ],
    )
    return nothing
end

# A centred modal whose body is `lines` (each with its own style) followed by a blank row
# and one `TextInput`. Shared by the path and token overlays, which differ only in width,
# title, prompt text and which input they drive.
function _render_input_modal!(area::Rect, buf, title::String, input; width::Int, lines)
    rect = _open_modal!(area, buf, title, min(width, area.width - 4), length(lines) + 4)
    body = inner(rect)
    for (i, (ln, style)) in enumerate(lines)
        isempty(ln) || set_string!(buf, body.x, body.y + i - 1, ln, style)
    end
    render(input, Rect(body.x, body.y + length(lines) + 1, body.width, 1), buf)
    return nothing
end

function _render_modal!(area::Rect, buf, title::String, lines::Vector{String})
    rect = _open_modal!(area, buf, title, min(maximum(length, lines) + 4, area.width - 4), length(lines) + 2)
    body = inner(rect)
    for (i, ln) in enumerate(lines)
        set_string!(buf, body.x, body.y + i - 1, ln, tstyle(:text))
    end
    return nothing
end

# Clear a centred `w`×`h` region and draw the modal border; returns the outer rect.
function _open_modal!(area::Rect, buf, title::String, w::Int, h::Int)
    rect = center(area, w, h)
    _clear_rect!(buf, rect)
    render(
        Block(
            title = title, border_style = tstyle(:accent),
            title_style = tstyle(:title, bold = true),
        ), rect, buf
    )
    return rect
end

function _clear_rect!(buf, rect::Rect)
    bg = tstyle(:text)
    for ry in rect.y:bottom(rect), rx in rect.x:right(rect)
        set_char!(buf, rx, ry, ' ', bg)
    end
    return nothing
end

# ── Entry point ───────────────────────────────────────────────────────────────

"""
    run_browser(; sources=list_sources(), offline=false)

Open a full-screen interactive browser for MRI datasets.

Launches a [Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl) `PagedDataTable`
that lets you search, filter, sort, and select a dataset for download — all from the
terminal, including from within the Julia REPL.

**Keys**
- `↑ ↓` move selection; `PgUp/PgDn` change page
- `s` (or `/`) open the search / expression-query overlay (see below); Enter applies,
  Esc cancels
- `f` open the per-column filter modal (single-column, typed filters). On its column
  list: `p` cycles the highlighted column's missing-value filter (none → present →
  missing → none), `x` clears every active filter (per-column, missing-value, and the
  expression query)
- `c` open the column-visibility picker — `Space` toggles the highlighted column,
  `Enter` applies, `Esc` cancels; `"#"` (the row index) is always shown. The applied
  selection is persisted in `LocalPreferences.toml` and restored on the next launch
- `1`-`9` sort by that column (toggles ascending/descending)
- `d` open the details pane for the highlighted dataset — a `keyword │ value │ description`
  table of every `extra` key it carries (the keyword is also its `query`/`list_datasets`
  filter name; the description column wraps). `Esc`/`d`/`q` closes it — no download quit
- `Enter` select the highlighted dataset and start the download flow
- `q` / `Esc` quit without downloading

When `sources` narrows the session to a single source, a couple of that source's most
useful `extra` fields (e.g. OCMR's `scanner_model`) are added as real columns —
sortable/filterable like any other — on top of the base column set; they're also
toggleable from the column picker and queryable by their `extra_schema` key.

**Search / expression queries (`s`)** use the same boolean language as the string form of
[`query`](@ref) — `AND`/`OR` (AND binds tighter), parentheses, `=`/`!=`/`<`/`<=`/`>`/`>=`,
quoted or bare values, `*` wildcards for string matches, `K`/`M`/`G` size suffixes on
numbers, and `nothing` for "no value":
```
(dataset=fastmri AND R<3) OR id='fs_*'
anatomy=knee AND fully_sampled=true
size < 100M
R != nothing
```
Field names accept any [`DatasetEntry`](@ref) field, the friendly aliases matching the
table's column headers (`dataset`/`source`, `r`, `b0`, `channels`, `frames`, `size`,
`sampling`), or a per-source `extra` key. Changing the visible columns resets the
per-column filter/sort state (column indices move underneath it); an expression query
keeps it.

After selecting a dataset you are asked to confirm (`y`/`n`) and to choose a
destination path. The default is `<current directory>/<id>.h5`; press Enter to
accept it. CMRxRecon downloads need a Synapse access token; if none is
configured you are prompted for one (saved to `LocalPreferences.toml` for reuse).

Dataset sizes (the Size column) are fetched in the background via HTTP HEAD
requests as you browse. Sizes for the current page and the adjacent pages are
prefetched automatically; previously fetched sizes are reused.

Returns the path of the downloaded file, or `nothing` if you quit without downloading.
A failed download is reported and then rethrown, so the cause reaches the REPL.

```julia
using MRITestData
run_browser()                             # browse all sources
run_browser(; sources = OCMR_SOURCE)     # one source only
run_browser(; offline = true)            # skip the network
```
"""
function run_browser(; sources = list_sources(), offline::Bool = false)
    model = BrowserModel(
        query(; sources = sources, offline = offline);
        visible_columns = _load_persisted_columns(),
    )
    app(model; fps = 30)

    # Remember the column selection for the next launch.
    try
        _persist_columns(model.visible_columns)
    catch
    end

    request = model.request
    request === nothing && return nothing

    println("\nDownloading to: $(request.dest)")
    try
        # The browser always names an explicit destination, so it downloads via `path=`
        # (which works even when no default download path has been configured) and then
        # renames to the exact file name the user asked for.
        dir = dirname(request.dest)
        isempty(dir) && (dir = pwd())
        got = download_dataset(request.entry; path = dir, progress = true)
        if abspath(got) != abspath(request.dest)
            mkpath(dirname(request.dest))
            mv(got, request.dest; force = true)
        end
    catch err
        # A one-line summary for the terminal, then rethrow: an expired credential, a
        # missing token or a stale offset map all need the actual exception to diagnose.
        println("Download failed: $(sprint(showerror, err))")
        rethrow()
    end
    println("Done — file at $(request.dest)")
    return request.dest
end

# Resolve `--source NAME` (repeatable) against `source_name`; no flag means every source.
function _browser_sources(args::AbstractVector{<:AbstractString})
    wanted = [args[i + 1] for i in eachindex(args) if args[i] == "--source" && i < lastindex(args)]
    isempty(wanted) && return list_sources()
    selected = filter(s -> source_name(s) in wanted, list_sources())
    isempty(selected) && error(
        "unknown source(s) $(join(wanted, ", ")); available: " *
            join(source_name.(list_sources()), ", "),
    )
    return selected
end

@static if VERSION >= v"1.11"
    function (@main)(ARGS)
        try
            run_browser(; sources = _browser_sources(ARGS), offline = "--offline" in ARGS)
        catch err
            println(stderr, sprint(showerror, err))
            return 1
        end
        return 0
    end
end
