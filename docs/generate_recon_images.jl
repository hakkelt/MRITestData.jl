#!/usr/bin/env julia
#
# Maintainer tool — render the representative reconstructed slices shown in the docs'
# "Reconstruction with MRIReco" section (docs/src/assets/recon/*.png).
#
# These are pre-generated and committed rather than built live, because reconstruction
# needs MRIReco plus real data downloads from Synapse/OCMR/mridata (a token and several GB)
# — unsuitable for a `@example` block in the Documenter build. Run this once in an
# environment that has MRITestData + MRIReco + MIRTjim + Plots (see
# examples/reconstruct_all_types.jl for env setup), with a Synapse token configured:
#
#   SYNAPSE_AUTH_TOKEN=<PAT> julia --project=<env> docs/generate_recon_images.jl
#
# Downloads are cached (set $RECON_CACHE to reuse a cache across runs).

ENV["GKSwstype"] = "100"   # headless GR
using MRITestData, MRIReco, MRIBase, MIRTjim, Plots

haskey(ENV, "RECON_CACHE") && (MRITestData.CACHE_DIR[] = ENV["RECON_CACHE"])
outdir = normpath(joinpath(@__DIR__, "src", "assets", "recon"))
mkpath(outdir)

# Direct reconstruction → coil-combined magnitude, axes [x, y, z, echo, rep].
function recon_sos(entry)
    raw = load_raw(entry)
    acq = AcquisitionData(raw)
    params = MRIReco.defaultRecoParams(); params[:reco] = "direct"
    d = Array(MRIReco.reconstruction(acq, params))               # [x,y,z,echo,coil,rep]
    return sqrt.(dropdims(sum(abs2, d; dims = 5); dims = 5))      # [x,y,z,echo,rep]
end

smallest(es) = first(sort(es; by = e -> something(e.approx_size_bytes, typemax(Int))))
pick(src, pred) = smallest(filter(pred, list_datasets(src; offline = true)))

using Statistics: quantile

function save_montage(vol3d, file, title)
    # Crop the readout (1st) axis when it is ~2× oversampled, as CMRxRecon acquires it —
    # this drops the empty oversampled border so the heart fills the frame.
    nx, ny = size(vol3d, 1), size(vol3d, 2)
    if nx >= 1.6 * ny
        lo = nx ÷ 4 + 1
        vol3d = vol3d[lo:(lo + nx ÷ 2 - 1), :, :]
    end
    # Robust window: clip a handful of hot pixels so the anatomy is not crushed to black.
    hi = quantile(vec(vol3d), 0.995)
    n = size(vol3d, 3)
    ncol = n == 1 ? 1 : (n <= 3 ? n : 3)
    jim(vol3d; title = title, color = :grays, clim = (0, hi), ncol = ncol)
    savefig(joinpath(outdir, file))
    return println("wrote ", file, "  ", size(vol3d))
end

# CMRxRecon-300 Cine (short-axis): slice stack at one cardiac frame. NOTE the `_ks` data is
# k-t undersampled (R≈3), so this direct recon aliases — it illustrates the undersampling.
sax = recon_sos(pick(CMRXRECON300, e -> get(e.extra, "modality", "") == "Cine SAX" && endswith(e.id, "_ks")))
save_montage(sax[:, :, :, cld(size(sax, 4), 2), 1], "cmrxrecon300_cine_sax.png", "CMRxRecon-300 Cine (R≈3 undersampled — direct recon aliases)")

# CMRxRecon2024 BlackBlood: dark-blood anatomical slices (single contrast).
bb = recon_sos(smallest(filter(e -> get(e.extra, "modality", "") == "BlackBlood", list_datasets(CMRXRECON2024; offline = true))))
save_montage(bb[:, :, :, 1, 1], "cmrxrecon2024_blackblood.png", "CMRxRecon2024 BlackBlood (slices)")

# mridata.org: slices through the fully-sampled 3-D volume (subsampled for display).
mr = recon_sos(pick(MRIDATA, e -> e.fully_sampled === true && e.approx_size_bytes !== nothing))
zk = range(1, size(mr, 3); length = 6) .|> round .|> Int
save_montage(mr[:, :, zk, 1, 1], "mridata_3d.png", "mridata.org (3-D volume slices)")

# OCMR: one cardiac cine frame.
oc = recon_sos(first(filter(e -> e.fully_sampled === true, list_datasets(OCMR_SOURCE; offline = true))))
save_montage(oc[:, :, 1:1, 1, 1], "ocmr_cine.png", "OCMR (cardiac cine frame)")

println("done → ", outdir)
