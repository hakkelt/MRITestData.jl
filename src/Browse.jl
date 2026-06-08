# ── Browse ────────────────────────────────────────────────────────────────────
# Interactive full-screen dataset browser built on Tachikoma.jl's PagedDataTable.
# Can be used directly from the Julia REPL via `run_browser()`, or installed as
# the standalone shell command `mridata-browse` via Pkg.Apps.

using Tachikoma
using Tachikoma.Paged
# Extended with new methods, so they must be imported by name.
import Tachikoma: view, update!, should_quit

# ── Column definitions ────────────────────────────────────────────────────────

_fmt_b0(v) = v === nothing ? "?" : string(v, "T")
_fmt_coils(v) = v === nothing ? "?" : string(v, "ch")
_fmt_sampled(v) = v === true ? "✓" : v === false ? "" : "?"
_fmt_size(v) = v === nothing ? "?" : _human_bytes(v)
_fmt_sym(v) = (v === nothing || v === :unknown) ? "?" : string(v)

# Column 1 holds the entry's index into the `entries` vector so the selected
# row maps back to a DatasetEntry even after sorting/filtering.
const _COLUMNS = PagedColumn[
    PagedColumn("#"; align = col_right, filterable = false, col_type = :numeric),
    PagedColumn("Source"; col_type = :text),
    PagedColumn("ID"; col_type = :text),
    PagedColumn("Anatomy"; format = _fmt_sym, col_type = :text),
    PagedColumn("B₀"; align = col_right, format = _fmt_b0, col_type = :numeric),
    PagedColumn("Trajectory"; format = _fmt_sym, col_type = :text),
    PagedColumn("Coils"; align = col_right, format = _fmt_coils, col_type = :numeric),
    PagedColumn("Fully sampled"; format = _fmt_sampled, col_type = :text),
    PagedColumn("Size"; align = col_right, format = _fmt_size, col_type = :numeric),
]

function _entry_row(i::Int, e::DatasetEntry)
    return Any[
        i,
        source_name(e.source),
        e.id,
        e.anatomy,
        e.field_strength,
        e.trajectory,
        e.coils,
        e.fully_sampled,
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
#   :path     — destination path input overlay
mutable struct BrowserModel <: Model
    entries::Vector{DatasetEntry}
    pdt::PagedDataTable
    stage::Symbol
    selected::Union{Nothing, DatasetEntry}
    path_input::TextInput
    quit::Bool
    # filled in when the user confirms a download; consumed after app() exits
    download::Union{Nothing, Tuple{DatasetEntry, String}}
end

function BrowserModel(entries::Vector{DatasetEntry})
    provider = _build_provider(entries)
    pdt = PagedDataTable(provider; page_size = 20, page_sizes = Int[20, 50, 100])
    return BrowserModel(
        entries,
        pdt,
        :browse,
        nothing,
        TextInput(; label = "Path: ", focused = true),
        false,
        nothing,
    )
end

should_quit(m::BrowserModel) = m.quit

# Map the currently-selected table row back to its DatasetEntry.
function _selected_entry(m::BrowserModel)
    pdt = m.pdt
    (pdt.selected < 1 || pdt.selected > length(pdt.rows)) && return nothing
    idx = pdt.rows[pdt.selected][1]
    idx isa Integer || return nothing
    (idx < 1 || idx > length(m.entries)) && return nothing
    return m.entries[idx]
end

# ── Event handling ────────────────────────────────────────────────────────────

function update!(m::BrowserModel, evt::KeyEvent)
    m.stage === :browse && return _update_browse!(m, evt)
    m.stage === :confirm && return _update_confirm!(m, evt)
    m.stage === :path && return _update_path!(m, evt)
    return nothing
end

function update!(m::BrowserModel, evt::MouseEvent)
    m.stage === :browse && handle_mouse!(m.pdt, evt)
    return nothing
end

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
        m.stage = :path
    elseif evt.key == :escape || (evt.key == :char && (evt.char == 'n' || evt.char == 'N'))
        m.selected = nothing
        m.stage = :browse
    elseif evt.key == :char && (evt.char == 'q' || evt.char == 'Q')
        m.quit = true
    end
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
    m.pdt.block = Block(
        title = "MRI Datasets ($(length(m.entries)))",
        border_style = tstyle(:border),
        title_style = tstyle(:title),
    )
    render(m.pdt, table_area, buf)
    render(_HELP_BAR, bar_area, buf)

    m.stage === :confirm && _render_confirm!(m, area, buf)
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
accept it.

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
            path = download_dataset(e; progress = true)
            path == dest || cp(path, dest; force = true)
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
