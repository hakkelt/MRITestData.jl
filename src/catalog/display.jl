# Pure formatting helpers for dataset display.
# No TTY, no UI imports — unit-testable offline.

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
