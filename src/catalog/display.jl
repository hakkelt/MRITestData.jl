# Pure formatting helpers for dataset display.
# No TTY, no UI imports — unit-testable offline.

# Binary prefixes: sizes here come from HTTP Content-Length and `filesize`, and are compared
# against on-disk footprints, so the 1024-based units (and their IEC names) are the ones
# that match what the user sees in a file manager.
const _BYTE_UNITS = ("B", "KiB", "MiB", "GiB", "TiB")

function _human_bytes(n::Integer)
    n < 0 && return string(n, "B")
    f = float(n)
    i = 1
    while f >= 1024 && i < length(_BYTE_UNITS)
        f /= 1024
        i += 1
    end
    return i == 1 ? string(Int(f), _BYTE_UNITS[i]) : string(round(f; digits = 1), _BYTE_UNITS[i])
end

# ── Cross-source entry formatting ─────────────────────────────────────────────────
# Each source records sampling and coil counts in its own vocabulary. These helpers map
# those onto one shared representation for display, so the browser (and any other
# presentation layer) never has to know which source an entry came from. They live here,
# not in `browse.jl`, because the normalisation is a catalog concern and is testable
# without a terminal.

_fmt_b0(v) = v === nothing ? "?" : string(v, "T")
_fmt_coils(v) = v === nothing ? "?" : v isa AbstractString ? v : string(v, "ch")
_fmt_size(v) = v === nothing ? "?" : _human_bytes(v)
_fmt_sym(v) = (v === nothing || v === :unknown) ? "?" : string(v)

# Sampling, using explicit words rather than glyphs:
#   true → "fully sampled", false → "undersampled" (pattern unknown),
#   a String → a named undersampling pattern (e.g. "pseudo-random"), nothing → "?".
_fmt_sampling(v::Bool) = v ? "fully sampled" : "undersampled"
_fmt_sampling(::Nothing) = "?"
_fmt_sampling(v) = string(v)

# `extra["sampling"]` values that mean "fully sampled" rather than naming an undersampling
# pattern. Each source keeps its own spelling in `extra` (OCMR decodes its `smp` column to
# prose, CMRxRecon2024 stores the map's "full" tag); the boolean `fully_sampled` field is
# the cross-source answer, so these are recognised and discarded here.
const _FULL_SAMPLING_WORDS = ("full", "fully sampled")

"""
    _sampling_value(e::DatasetEntry)

Collapse an entry's sampling metadata into the shared representation `_fmt_sampling`
renders: `true` when fully sampled, a `String` naming the undersampling pattern when the
source records one, otherwise the raw `fully_sampled` field (`false` or `nothing`).
"""
function _sampling_value(e::DatasetEntry)
    e.fully_sampled === true && return true
    pat = get(e.extra, "sampling", "")
    pat isa AbstractString || return e.fully_sampled
    (isempty(pat) || pat in _FULL_SAMPLING_WORDS) && return e.fully_sampled
    # OCMR spells its patterns "<name> undersampled"; the qualifier is already carried by
    # `fully_sampled`, so the column shows just the name.
    return replace(pat, " undersampled" => "")
end

"""
    _coils_value(e::DatasetEntry)

Coil count for display: the exact number when the catalog records one, else the
`coil_type` label CMRxRecon2024 carries ("multi"/"single"), else `nothing`.
"""
function _coils_value(e::DatasetEntry)
    e.coils === nothing || return e.coils
    label = get(e.extra, "coil_type", "")
    return label isa AbstractString && !isempty(label) ? label : nothing
end
