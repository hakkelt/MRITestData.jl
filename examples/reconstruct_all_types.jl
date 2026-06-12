#!/usr/bin/env julia
#
# Example / validation: reconstruct a representative sample of every supported data type
# with MRIReco.jl, confirming that the `load_raw` → `AcquisitionData` → `reconstruction`
# pipeline works uniformly across sources and CMRxRecon modalities.
#
# MRIReco is intentionally NOT a dependency of MRITestData (reconstruction is left to the
# caller), so run this in a throw-away environment that has both packages:
#
#   julia -e 'using Pkg; Pkg.activate(temp=true);
#             Pkg.develop(path="."); Pkg.add(["MRIReco","MRIBase"])'
#   SYNAPSE_AUTH_TOKEN=<PAT> julia --project=<that env> examples/reconstruct_all_types.jl
#
# The CMRxRecon sources need a Synapse token (set_synapse_token! or SYNAPSE_AUTH_TOKEN);
# CMRxRecon-300 also needs the per-set member maps + zran index committed under data/
# (generate them with scripts/index_cmrxrecon300.jl). Downloads are cached under the
# Scratch space (or $RECON_CACHE if set), so re-runs are fast.

using MRITestData, MRIReco, MRIBase
using Printf

haskey(ENV, "RECON_CACHE") && (MRITestData.CACHE_DIR[] = ENV["RECON_CACHE"])

# Reconstruct one entry with MRIReco's direct method; report a finite, non-trivial image.
function try_recon(label, entry; max_bytes = 1_500_000_000)
    sz = entry.approx_size_bytes
    if sz !== nothing && sz > max_bytes
        return println(@sprintf("%-34s SKIP  (%.0f MB > budget)", label, sz / 1.0e6))
    end
    return try
        raw = load_raw(entry)
        acq = AcquisitionData(raw)
        params = MRIReco.defaultRecoParams()
        params[:reco] = "direct"
        d = Array(MRIReco.reconstruction(acq, params))
        ok = all(isfinite, d) && maximum(abs, d) > 0
        println(@sprintf("%-34s %s  dims=%-26s profiles=%d", label, ok ? "OK " : "BAD", string(size(d)), length(raw.profiles)))
    catch e
        println(@sprintf("%-34s ERROR: %s", label, sprint(showerror, e)[1:min(end, 150)]))
    end
end

# Smallest entry by known size (unknown sizes sort last).
smallest(es) = isempty(es) ? nothing : first(sort(es; by = e -> something(e.approx_size_bytes, typemax(Int))))

println("=== MRIReco reconstruction across data types ===")

# CMRxRecon-300 — Cine SAX/LAX + T1/T2 mapping.
d3 = list_datasets(CMRXRECON300; offline = true)
for (mod, lbl) in (
        ("Cine SAX", "CMRxRecon300 Cine SAX"), ("Cine LAX", "CMRxRecon300 Cine LAX"),
        ("T1map", "CMRxRecon300 T1 map"), ("T2map", "CMRxRecon300 T2 map"),
    )
    e = smallest(filter(x -> get(x.extra, "modality", "") == mod && endswith(x.id, "_ks"), d3))
    e === nothing || try_recon(lbl, e)
end

# CMRxRecon2024 — Cine, Mapping, Aorta, Tagging, Flow2d, BlackBlood.
d2 = list_datasets(CMRXRECON2024; offline = true)
for mod in ("Cine", "Mapping", "Aorta", "Tagging", "Flow2d", "BlackBlood")
    e = smallest(filter(x -> get(x.extra, "modality", "") == mod, d2))
    e === nothing || try_recon("CMRxRecon2024 $mod", e)
end

# mridata.org (3-D Cartesian) + OCMR (cardiac cine).
mr = smallest(filter(e -> e.fully_sampled === true && e.approx_size_bytes !== nothing, list_datasets(MRIDATA; offline = true)))
mr === nothing || try_recon("mridata.org (fully-sampled 3-D)", mr)

oc = first(filter(e -> e.fully_sampled === true, list_datasets(OCMR_SOURCE; offline = true)))
try_recon("OCMR (cardiac cine)", oc)
