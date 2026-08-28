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
    PagedColumn("R"; align = col_right, format = _fmt_accel, col_type = :text),
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

function _entry_row(i::Int, e::DatasetEntry)
    return Any[
        i,
        source_name(e.source),
        e.id,
        e.anatomy,
        e.contrast,
        e.field_strength,
        e.trajectory,
        e.receiver_channels,
        _sampling_value(e),
        e.acceleration,
        e.num_frames,
        e.split,
        _fmt_cached(e),
        e.approx_size_bytes,
    ]
end

function _build_provider(entries::Vector{DatasetEntry})
    ncols = length(_COLUMNS)
    data = [Vector{Any}(undef, length(entries)) for _ in 1:ncols]
    for (i, e) in enumerate(entries)
        row = _entry_row(i, e)
        for c in 1:ncols
            data[c][i] = row[c]
        end
    end
    return InMemoryPagedProvider(_COLUMNS, data)
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
end

function BrowserModel(entries::Vector{DatasetEntry})
    provider = _build_provider(entries)
    pdt = PagedDataTable(provider; page_size = 20, page_sizes = Int[20, 30, 50, 100])
    tq = TaskQueue()
    return BrowserModel(
        entries,
        pdt,
        :browse,
        nothing,
        TextInput(; label = "Path: ", focused = true),
        TextInput(; label = "Token: ", focused = true),
        false,
        nothing,
        tq,
        0,
        0,
    )
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

    # Only the Size column changes, and provider rows are in `m.entries` order, so the
    # column is patched in place. Replacing the provider would re-box every cell of every
    # column and reset page/sort/filter/search, which would then have to be saved and
    # restored around it.
    size_column = m.pdt.provider.data[_SIZE_COL]
    changed = false
    for i in fetch_indices
        (i < 1 || i > length(m.entries)) && continue
        e = m.entries[i]
        e.approx_size_bytes === nothing || continue
        sz = get(sizes, e.id, nothing)
        sz === nothing && continue
        m.entries[i] = _with_size(e, sz)
        size_column[i] = sz
        changed = true
    end

    changed && pdt_fetch!(m.pdt)   # re-derive the visible rows from the patched column
    return nothing
end

# Fallback handler for other TaskEvent types (e.g. errors from the fetch task).
update!(m::BrowserModel, ::TaskEvent) = nothing

function _update_browse!(m::BrowserModel, evt::KeyEvent)
    pdt = m.pdt
    # While the table's own sub-inputs are open, delegate everything to it.
    if pdt.search_visible || pdt.filter_modal.visible || pdt.goto_visible
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

    if (evt.key == :char && evt.char == 'q') || evt.key == :escape
        return _quit!(m)
    end

    handle_key!(pdt, evt)
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
            isempty(dest) && (dest = joinpath(pwd(), basename(cache_path(e))))
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
        Span("/ ", tstyle(:accent)),
        Span("search  ", tstyle(:text_dim)),
        Span("f ", tstyle(:accent)),
        Span("filter  ", tstyle(:text_dim)),
        Span("1-9 ", tstyle(:accent)),
        Span("sort  ", tstyle(:text_dim)),
        Span("Enter ", tstyle(:accent)),
        Span("download  ", tstyle(:text_dim)),
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

    m.stage === :confirm && _render_confirm!(m, area, buf)
    m.stage === :token && _render_token!(m, area, buf)
    m.stage === :path && _render_path!(m, area, buf)
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
- `/` global search across all columns
- `f` open the per-column filter modal
- `1`-`9` sort by that column (toggles ascending/descending)
- `Enter` select the highlighted dataset and start the download flow
- `q` / `Esc` quit without downloading

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
    model = BrowserModel(query(; sources = sources, offline = offline))
    app(model; fps = 30)

    request = model.request
    request === nothing && return nothing

    println("\nDownloading to: $(request.dest)")
    try
        copy_dataset(request.entry; dest = request.dest, progress = true)
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
