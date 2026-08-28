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
# Each source's DatasetEntry now carries a shared cross-source vocabulary directly (see
# taxonomy.jl), so these helpers are purely presentational — no more per-source coercion.

_fmt_b0(v) = v === nothing ? "?" : string(v, "T")
_fmt_channels(v) = v === nothing ? "?" : string(v, "ch")
_fmt_size(v) = v === nothing ? "?" : _human_bytes(v)
_fmt_sym(v) = (v === nothing || v === :unknown) ? "?" : string(v)
_fmt_accel(v) = v === nothing ? "" : string("×", round(v; digits = 1))

# Sampling, using explicit words rather than glyphs:
#   true → "fully sampled",
#   false + a named `undersampling_pattern` → that pattern's name (e.g. "vista"),
#   false alone → "undersampled", nothing → "?".
_fmt_sampling(v::Bool) = v ? "fully sampled" : "undersampled"
_fmt_sampling(::Nothing) = "?"
_fmt_sampling(v::AbstractString) = v   # a named undersampling_pattern, from _sampling_value

"""
    _sampling_value(e::DatasetEntry)

Collapse an entry's sampling metadata into the shared representation `_fmt_sampling`
renders: `true` when fully sampled, the `undersampling_pattern` name (a `String`) when the
entry records one, otherwise the raw `fully_sampled` field (`false` or `nothing`).
"""
function _sampling_value(e::DatasetEntry)
    e.fully_sampled === true && return true
    e.undersampling_pattern === nothing && return e.fully_sampled
    return string(e.undersampling_pattern)
end
