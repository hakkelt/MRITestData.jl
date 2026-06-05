# Interactive terminal UI for browsing/selecting datasets, built on the stdlib
# `REPL.TerminalMenus` (no extra dependency, works over SSH). The pure formatting
# helpers (`_tui_row`, `_tui_rows`) are kept separate from the interactive loop so
# they can be unit-tested without a TTY.

using REPL.TerminalMenus: RadioMenu, MultiSelectMenu, request

"""
    search_datasets(; sources = list_sources(), text = nothing, offline = false,
                      multiselect = false, filters...)
        -> Union{DatasetEntry, Vector{DatasetEntry}, Nothing}

Open an interactive terminal menu to browse the datasets matching the given
[`query`](@ref) (same `sources`/`text`/`offline`/`filters` keywords) and pick one.

The initial result set is computed with [`query`](@ref). Each entry is shown on one
line (source, id, anatomy, field strength, trajectory, coils, approximate size). From
the menu you can:

- select a dataset (returns its [`DatasetEntry`](@ref)), or
- choose *"Refine free-text filter…"* to type a new substring and re-run the query, or
- choose *"Quit"* to abort (returns `nothing`).

Pass `multiselect = true` to return a `Vector{DatasetEntry}` instead (toggle rows with
space, confirm with enter).

Requires an interactive terminal; in a non-interactive context use [`query`](@ref)
directly.

# Examples
```julia
entry = search_datasets(; anatomy = :knee)
entries = search_datasets(; sources = OCMR_SOURCE, multiselect = true)
```
"""
function search_datasets(;
        sources = list_sources(),
        text::Union{Nothing, AbstractString, Regex, Function} = nothing,
        offline::Bool = false,
        multiselect::Bool = false,
        kwargs...,
    )
    cur_text = text
    while true
        entries = query(; sources = sources, text = cur_text, offline = offline, kwargs...)
        multiselect && return _tui_multiselect(entries)

        rows = _tui_rows(entries)
        header = _tui_header(entries, cur_text)
        options = vcat(rows, ["── Refine free-text filter…", "── Quit"])
        menu = RadioMenu(options; pagesize = min(20, length(options)))
        choice = request(header, menu)

        if choice == -1 || choice == length(options)          # Ctrl-C / Quit
            return nothing
        elseif choice == length(options) - 1                  # Refine
            print("New free-text filter (blank clears): ")
            line = strip(readline())
            cur_text = isempty(line) ? nothing : String(line)
        else
            return entries[choice]
        end
    end
    return
end

function _tui_multiselect(entries::Vector{DatasetEntry})
    isempty(entries) && return DatasetEntry[]
    menu = MultiSelectMenu(_tui_rows(entries); pagesize = min(20, length(entries)))
    picks = request("Select datasets (space toggles, enter confirms):", menu)
    return DatasetEntry[entries[i] for i in sort!(collect(picks))]
end

_tui_header(entries, text) = string(
    length(entries), " dataset(s)",
    text === nothing ? "" : " matching \"$(text)\"",
    " — ↑↓ move, enter select:",
)

# One display row per entry. Pure: takes an entry, returns a String.
function _tui_rows(entries::Vector{DatasetEntry})
    isempty(entries) && return ["(no matches)"]
    return [_tui_row(e) for e in entries]
end

function _tui_row(e::DatasetEntry)
    parts = String[rpad(source_name(e.source), 11), rpad(e.id, 38)]
    e.anatomy === :unknown || push!(parts, String(rpad(e.anatomy, 8)))
    e.field_strength === nothing || push!(parts, string(e.field_strength, "T"))
    e.trajectory === :unknown || push!(parts, String(e.trajectory))
    e.coils === nothing || push!(parts, "$(e.coils)ch")
    e.fully_sampled === true && push!(parts, "fs")
    e.approx_size_bytes === nothing || push!(parts, _human_bytes(e.approx_size_bytes))
    return join(parts, "  ")
end

function _human_bytes(n::Integer)
    n < 0 && return string(n, "B")
    units = ("B", "KB", "MB", "GB", "TB")
    f = float(n)
    i = 1
    while f >= 1024 && i < length(units)
        f /= 1024
        i += 1
    end
    return i == 1 ? string(Int(f), units[i]) : string(round(f; digits = 1), units[i])
end
