# ── Browse ────────────────────────────────────────────────────────────────────
# Interactive full-screen dataset browser built on Tachikoma.jl's PagedDataTable.
# Can be used directly from the Julia REPL via `run_browser()`, or installed as
# the standalone shell command `mridata-browser` via Pkg.Apps.

using Tachikoma
using Tachikoma.Paged
# Extended with new methods, so they must be imported by name.
import Tachikoma: view, update!, should_quit, task_queue, pre_render!

# ── Column definitions ────────────────────────────────────────────────────────

_fmt_b0(v) = v === nothing ? "?" : string(v, "T")
_fmt_coils(v) = v === nothing ? "?" : v isa AbstractString ? v : string(v, "ch")
_fmt_size(v) = v === nothing ? "?" : _human_bytes(v)
_fmt_sym(v) = (v === nothing || v === :unknown) ? "?" : string(v)
# Sampling column, normalised across sources so the same concept reads the same way,
# using explicit words rather than glyphs:
#   true → "fully sampled", false → "undersampled" (pattern unknown),
#   a String → a named undersampling pattern (e.g. "pseudo-random"), nothing → "?".
_fmt_sampling(v::Bool) = v ? "fully sampled" : "undersampled"
_fmt_sampling(::Nothing) = "?"
_fmt_sampling(v) = string(v)

# Collapse each source's own sampling encoding into the shared representation above.
# OCMR stores verbose strings ("fully sampled" / "pseudo-random undersampled"); mridata
# and CMRxRecon rely on the fully_sampled boolean (CMRxRecon is all FullSample).
function _sampling_value(e::DatasetEntry)
    e.fully_sampled === true && return true
    pat = get(e.extra, "sampling", "")
    if pat isa AbstractString && !isempty(pat) && pat != "full" && pat != "fully sampled"
        return replace(pat, " undersampled" => "")
    end
    return e.fully_sampled
end

# Column 1 holds the entry's index into the `entries` vector so the selected
# row maps back to a DatasetEntry even after sorting/filtering.
const _COLUMNS = PagedColumn[
    PagedColumn("#"; align = col_right, filterable = false, col_type = :numeric),
    PagedColumn("Source"; col_type = :text),
    PagedColumn("ID"; col_type = :text),
    PagedColumn("Anatomy"; format = _fmt_sym, col_type = :text),
    PagedColumn("B₀"; align = col_right, format = _fmt_b0, col_type = :numeric),
    PagedColumn("Trajectory"; format = _fmt_sym, col_type = :text),
    PagedColumn("Coils"; align = col_right, format = _fmt_coils, col_type = :text),
    PagedColumn("Sampling"; format = _fmt_sampling, col_type = :text),
    PagedColumn("Size"; align = col_right, format = _fmt_size, col_type = :numeric),
]

function _entry_row(i::Int, e::DatasetEntry)
    sampling = _sampling_value(e)
    # Coil count: exact if known; "multi"/"single" label for CMRxRecon MultiCoil entries.
    coils_val = if e.coils !== nothing
        e.coils
    elseif get(e.extra, "coil_type", "") == "multi"
        "multi"
    else
        nothing
    end
    return Any[
        i,
        source_name(e.source),
        e.id,
        e.anatomy,
        e.field_strength,
        e.trajectory,
        coils_val,
        sampling,
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

# ── Model ─────────────────────────────────────────────────────────────────────

# stage:
#   :browse   — the paged table is active
#   :confirm  — download confirmation overlay (y/n)
#   :token    — Synapse PAT input overlay (shown for CMRxRecon2024 when no token is set)
#   :path     — destination path input overlay
mutable struct BrowserModel <: Model
    entries::Vector{DatasetEntry}
    pdt::PagedDataTable
    stage::Symbol
    selected::Union{Nothing, DatasetEntry}
    path_input::TextInput
    token_input::TextInput
    quit::Bool
    # filled in when the user confirms a download; consumed after app() exits
    download::Union{Nothing, Tuple{DatasetEntry, String}}
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

# CMRxRecon2024 downloads require a Synapse Personal Access Token. An entry needs the
# token-entry modal when it comes from that source and none is currently configured.
_needs_synapse_token(e::DatasetEntry) = e.source isa CMRxRecon2024 && isempty(get_synapse_token())
_needs_synapse_token(::Nothing) = false

should_quit(m::BrowserModel) = m.quit
task_queue(m::BrowserModel) = m.tq

# Map the currently-selected table row back to its DatasetEntry.
function _selected_entry(m::BrowserModel)
    pdt = m.pdt
    (pdt.selected < 1 || pdt.selected > length(pdt.rows)) && return nothing
    idx = pdt.rows[pdt.selected][1]
    idx isa Integer || return nothing
    (idx < 1 || idx > length(m.entries)) && return nothing
    return m.entries[idx]
end

# ── Size prefetch ──────────────────────────────────────────────────────────────

# Indices (into m.entries) for the window of pages to prefetch.
# Covers the visible page plus one page on each side, clamped to valid range.
function _prefetch_indices(m::BrowserModel)
    pdt = m.pdt
    total = length(m.entries)
    total == 0 && return Int[]
    ps = pdt.page_size
    # Visible page range in the *sorted/filtered* view maps back to original
    # indices via pdt.rows[*][1]. We collect entry indices from those rows plus
    # the provider's adjacent pages (prev + next) via direct slice of m.entries.
    # Since the provider may be filtered/sorted, we use the raw entries window
    # for adjacent pages and the actual displayed rows for the current page.
    current_page_indices = Int[
        row[1] for row in pdt.rows if row[1] isa Integer && 1 <= row[1] <= total
    ]
    prev_start = max(1, (pdt.page - 2) * ps + 1)
    next_end = min(total, (pdt.page + 1) * ps)
    adjacent = collect(prev_start:next_end)
    return unique(vcat(current_page_indices, adjacent))
end

# Fire a background fetch_sizes task for the current page window.
function _fire_prefetch!(m::BrowserModel)
    indices = _prefetch_indices(m)
    isempty(indices) && return
    # Only fetch entries that still lack a size.
    to_fetch = [m.entries[i] for i in indices if m.entries[i].approx_size_bytes === nothing]
    isempty(to_fetch) && return
    gen = m.prefetch_generation
    entries_snapshot = copy(m.entries)   # snapshot so the task closure is self-contained
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

    changed = false
    for i in fetch_indices
        (i < 1 || i > length(m.entries)) && continue
        e = m.entries[i]
        e.approx_size_bytes === nothing || continue
        sz = get(sizes, e.id, nothing)
        sz === nothing && continue
        m.entries[i] = DatasetEntry(;
            source = e.source,
            id = e.id,
            name = e.name,
            anatomy = e.anatomy,
            vendor = e.vendor,
            field_strength = e.field_strength,
            trajectory = e.trajectory,
            coils = e.coils,
            fully_sampled = e.fully_sampled,
            is3D = e.is3D,
            approx_size_bytes = sz,
            sha256 = e.sha256,
            url = e.url,
            extra = e.extra,
        )
        changed = true
    end

    if changed
        # Rebuild provider so the Size column reflects the new data.
        # pdt_set_provider! resets page/sort/filter, so we preserve current state.
        pdt = m.pdt
        saved_page = pdt.page
        saved_sort_col = pdt.sort_col
        saved_sort_dir = pdt.sort_dir
        saved_filters = copy(pdt.filters)
        saved_search = pdt.search_query
        saved_selected = pdt.selected
        pdt_set_provider!(pdt, _build_provider(m.entries))
        pdt.page = saved_page
        pdt.sort_col = saved_sort_col
        pdt.sort_dir = saved_sort_dir
        pdt.filters = saved_filters
        pdt.search_query = saved_search
        pdt_fetch!(pdt)
        pdt.selected = clamp(saved_selected, 1, max(1, length(pdt.rows)))
    end
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
        m.quit = true
        return nothing
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
        m.quit = true
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
            m.download = (e, String(dest))
            m.quit = true   # leave the TUI; download runs after app() returns
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
    e = m.selected
    e === nothing && return
    w = min(64, area.width - 4)
    h = 7
    rect = center(area, w, h)
    block = Block(
        title = " Download path ", border_style = tstyle(:accent),
        title_style = tstyle(:title, bold = true)
    )
    _clear_rect!(buf, rect)
    render(block, rect, buf)
    body = inner(rect)
    set_string!(buf, body.x, body.y, "Enter to confirm, Esc to go back:", tstyle(:text_dim))
    render(m.path_input, Rect(body.x, body.y + 2, body.width, 1), buf)
    return nothing
end

function _render_token!(m::BrowserModel, area::Rect, buf)
    w = min(72, area.width - 4)
    h = 9
    rect = center(area, w, h)
    block = Block(
        title = " Synapse access token ", border_style = tstyle(:accent),
        title_style = tstyle(:title, bold = true)
    )
    _clear_rect!(buf, rect)
    render(block, rect, buf)
    body = inner(rect)
    set_string!(buf, body.x, body.y, "CMRxRecon2024 downloads need a Synapse Personal Access Token.", tstyle(:text))
    set_string!(buf, body.x, body.y + 1, "Paste it below (stored in LocalPreferences.toml for reuse).", tstyle(:text_dim))
    set_string!(buf, body.x, body.y + 4, "Enter to save & continue, Esc to go back:", tstyle(:text_dim))
    render(m.token_input, Rect(body.x, body.y + 6, body.width, 1), buf)
    return nothing
end

function _render_modal!(area::Rect, buf, title::String, lines::Vector{String})
    w = min(maximum(length, lines) + 4, area.width - 4)
    h = length(lines) + 2
    rect = center(area, w, h)
    block = Block(
        title = title, border_style = tstyle(:accent),
        title_style = tstyle(:title, bold = true)
    )
    _clear_rect!(buf, rect)
    render(block, rect, buf)
    body = inner(rect)
    for (i, ln) in enumerate(lines)
        set_string!(buf, body.x, body.y + i - 1, ln, tstyle(:text))
    end
    return nothing
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
accept it. CMRxRecon2024 downloads need a Synapse access token; if none is
configured you are prompted for one (saved to `LocalPreferences.toml` for reuse).

Dataset sizes (the Size column) are fetched in the background via HTTP HEAD
requests as you browse. Sizes for the current page and the adjacent pages are
prefetched automatically; previously fetched sizes are reused.

```julia
using MRITestData
run_browser()                             # browse all sources
run_browser(; sources = OCMR_SOURCE)     # one source only
run_browser(; offline = true)            # skip the network
```
"""
function run_browser(; sources = list_sources(), offline::Bool = false)
    entries = query(; sources = sources, offline = offline)
    model = BrowserModel(entries)
    app(model; fps = 30)

    if model.download !== nothing
        e, dest = model.download
        println("\nDownloading to: $dest")
        try
            copy_dataset(e; dest = dest, progress = true)
            println("Done — file at $dest")
        catch err
            println("Download failed: $err")
        end
    end
    return nothing
end

function (@main)(ARGS)
    offline = "--offline" in ARGS
    run_browser(; offline = offline)
    return 0
end
