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
using MRITestData, MRIReco, MRICoilSensitivities, MRIBase, MIRTjim, Plots
import MRIFiles

haskey(ENV, "RECON_CACHE") && (MRITestData.CACHE_DIR[] = ENV["RECON_CACHE"])
outdir = normpath(joinpath(@__DIR__, "src", "assets", "recon"))
mkpath(outdir)

function recon_sos(entry; reco = "direct")
    raw = load_raw(entry)

    # Extract calibration profiles if any
    calib_profiles = [p for p in raw.profiles if (p.head.flags & MRIFiles.ACQ_IS_PARALLEL_CALIBRATION) != 0]

    # AcquisitionData(raw) drops the calib profiles because they are marked with ACQ_IS_PARALLEL_CALIBRATION.
    # This is desired so that the main imaging data (with different phase) does not contain them.
    acq = AcquisitionData(raw)

    params = MRIReco.defaultRecoParams()
    params[:reco] = reco

    if reco == "multiCoil"
        if !isempty(calib_profiles)
            # Create a new raw object with JUST the calibration profiles
            # and clear the flag so AcquisitionData KEEPS them for espirit.
            calib_profiles_clean = deepcopy(calib_profiles)
            for p in calib_profiles_clean
                p.head.flags &= ~MRIFiles.ACQ_IS_PARALLEL_CALIBRATION
            end
            raw_calib = RawAcquisitionData(raw.params, calib_profiles_clean)
            acq_calib = AcquisitionData(raw_calib)
            params[:senseMaps] = espirit(acq_calib, (6, 6), 24, eigThresh_1 = 0.02, eigThresh_2 = 0.95)
        else
            params[:senseMaps] = espirit(acq, (6, 6), 24, eigThresh_1 = 0.02, eigThresh_2 = 0.95)
        end
    end

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
    # Filter out NaNs/Infs to prevent quantile from returning NaN, which causes a segfault in GR.
    valid = filter(isfinite, vec(vol3d))
    hi = isempty(valid) ? 1.0 : quantile(valid, 0.995)
    # Prevent clim=(0,0) which can also cause plotting issues.
    hi = max(hi, 1.0e-6)
    n = size(vol3d, 3)
    ncol = n == 1 ? 1 : (n <= 3 ? n : 3)
    jim(vol3d; title = title, color = :grays, clim = (0, hi), ncol = ncol)
    savefig(joinpath(outdir, file))
    return println("wrote ", file, "  ", size(vol3d))
end

# CMRxRecon-300 Cine (short-axis): slice stack at one cardiac frame. NOTE the `_ks` data is
# k-t undersampled (R≈3), so we use SENSE (multiCoil) to reconstruct without aliasing.
sax = recon_sos(pick(CMRXRECON300, e -> get(e.extra, "modality", "") == "Cine SAX"); reco = "multiCoil")
save_montage(sax[:, :, :, cld(size(sax, 4), 2), 1], "cmrxrecon300_cine_sax.png", "CMRxRecon-300 Cine (R≈3 undersampled — SENSE recon)")

# CMRxRecon2024 BlackBlood: dark-blood anatomical slices (single contrast).
bb = recon_sos(smallest(filter(e -> get(e.extra, "modality", "") == "BlackBlood", list_datasets(CMRXRECON2024; offline = true))))
save_montage(bb[:, :, :, 1, 1], "cmrxrecon2024_blackblood.png", "CMRxRecon2024 BlackBlood (slices)")

# mridata.org: slices through the fully-sampled volume (subsampled for display).
# We explicitly select a known-good 2D Cartesian multi-slice dataset (1.3 GB) because
# the live index scrape can fetch small spectroscopy datasets that fail in MRIReco.
mr_entry = first(filter(e -> e.id == "9270505a-8d77-4e43-ac43-0d9910b81510", list_datasets(MRIDATA; offline = true)))
mr = recon_sos(mr_entry)
zk = range(1, size(mr, 3); length = 6) .|> round .|> Int
save_montage(mr[:, :, zk, 1, 1], "mridata_3d.png", "mridata.org (3-D volume slices)")

# OCMR: one cardiac cine frame.
oc = recon_sos(first(filter(e -> e.fully_sampled === true, list_datasets(OCMR_SOURCE; offline = true))))
save_montage(oc[:, :, 1:1, 1, 1], "ocmr_cine.png", "OCMR (cardiac cine frame)")

println("done → ", outdir)
