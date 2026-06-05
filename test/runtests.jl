using TestItemRunner

# Tag-based gating:
#   :network — live downloads from mridata.org / OCMR; opt in with
#              MRITESTDATA_NETWORK_TESTS=true.
#   :mrt     — MriReconstructionToolbox integration; opt in with
#              MRITESTDATA_MRT_TESTS=true (does not precompile cleanly in a merged env).
# Everything else (catalog, cache, load, :mrireco, :quality/Aqua+JET) runs by default.
const RUN_NETWORK = get(ENV, "MRITESTDATA_NETWORK_TESTS", "false") == "true"
const RUN_MRT = get(ENV, "MRITESTDATA_MRT_TESTS", "false") == "true"

# Optional ARGS-based subset filter: pass tag(s) or test name(s) as a single
# comma-separated string, e.g.
#   julia --project=test test/runtests.jl ":network,:mrireco"
#   julia --project=test test/runtests.jl "OCMR: refresh index + download + reconstruct"
# Tags must be prefixed with ':', names are matched exactly.
const FILTER_PARTS = if length(ARGS) > 0
    @assert length(ARGS) == 1 "Pass at most one comma-separated filter string"
    split(ARGS[1], ",")
else
    String[]
end
const FILTER_TAGS = map(p -> Symbol(p[2:end]), filter(x -> startswith(x, ":"), FILTER_PARTS))
const FILTER_NAMES = filter(x -> !startswith(x, ":"), FILTER_PARTS)

@run_package_tests filter = ti -> begin
    # When an explicit subset filter is given, honour it unconditionally (the
    # caller opts in to whatever they ask for, including :network and :mrt).
    if !isempty(FILTER_PARTS)
        return any(t -> t in ti.tags, FILTER_TAGS) || any(n -> n == ti.name, FILTER_NAMES)
    end
    # Default gating: skip :network and :mrt unless opted in via env vars.
    (:network in ti.tags) && return RUN_NETWORK
    (:mrt in ti.tags) && return RUN_MRT
    return true
end
