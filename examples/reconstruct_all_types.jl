#!/usr/bin/env julia
#
# Example / validation: reconstruct a representative sample of every supported data type
# with MRIReco.jl, confirming that the `load_raw` → `AcquisitionData` → `reconstruction`
# pipeline works uniformly across sources, CMRxRecon modalities and the non-Cartesian
# (spiral) USC Speech data. A couple of representative slices/frames from every successful
# reconstruction are written as PNGs under `examples/results/`.
#
# MRIReco is intentionally NOT a dependency of MRITestData (reconstruction is left to the
# caller), so run this in a throw-away environment that has both packages (+ PNGFiles for
# the image export):
#
#   julia -e 'using Pkg; Pkg.activate(temp=true); Pkg.develop(path=".");
#             Pkg.add(["MRIReco","MRICoilSensitivities","MRIBase","PNGFiles"])'
#   SYNAPSE_AUTH_TOKEN=<PAT> julia --project=<that env> examples/reconstruct_all_types.jl
#
# Optional CLI argument: a filter string that selects which data files to reconstruct,
# matched (case-insensitive, ignoring spaces/dashes/underscores/slashes) against each
# candidate's label, source name and entry id. Examples:
#
#   julia ... examples/reconstruct_all_types.jl cmrxrecon-300   # only CMRxRecon-300 entries
#   julia ... examples/reconstruct_all_types.jl usc             # only USC Speech entries
#   julia ... examples/reconstruct_all_types.jl ocmr            # only the OCMR entry
#   julia ... examples/reconstruct_all_types.jl sub001/2drt     # a single USC file by id
#
# With no argument, every candidate below is reconstructed.
#
# The CMRxRecon sources need a Synapse token (set_synapse_token! or SYNAPSE_AUTH_TOKEN);
# CMRxRecon-300 also needs the per-set member maps + zran index committed under data/
# (generate them with scripts/index_cmrxrecon300.jl). Downloads are cached under the
# Scratch space (or $RECON_CACHE if set), so re-runs are fast.

using MRITestData, MRIReco, MRIBase
using MRICoilSensitivities: espirit
using MRIBase: flag_is_set, flag_remove!
using Printf
import PNGFiles

haskey(ENV, "RECON_CACHE") && (MRITestData.CACHE_DIR[] = ENV["RECON_CACHE"])

const RESULTS_DIR = joinpath(@__DIR__, "results")

# Optional CLI filter: match if the (normalised) needle is a substring of any of the
# (normalised) label / source / id. Normalisation drops separators so e.g. "cmrxrecon-300"
# matches the "CMRxRecon300 Cine SAX" label.
_norm(s) = lowercase(replace(String(s), r"[\s\-_/]" => ""))
const FILTER = isempty(ARGS) ? nothing : _norm(ARGS[1])

function selected(label, entry)
    FILTER === nothing && return true
    hay = _norm(string(label, " ", MRITestData.source_name(entry.source), " ", entry.id))
    return occursin(FILTER, hay)
end

# Turn a label into a filesystem-safe filename stem.
_slug(label) = replace(lowercase(String(label)), r"[^a-z0-9]+" => "_")

# Some sources need light massaging before the generic `AcquisitionData` constructor can
# handle them. USC Speech is the package's only non-Cartesian source: a single-slice
# spiral real-time acquisition whose `.h5` holds thousands of frames, each a full set of
# spiral interleaves (here 13, indexed by `kspace_encode_step_1`) acquired in a scrambled
# order, while its `repetition` counter just increments per profile. MRIBase's constructor
# expects the per-frame structure in the encoding counters, so regroup consecutive
# interleaves into frames (as repetitions) and keep a handful.
#
# Crucially, MRIBase assembles the per-frame *trajectory* indexed by `kspace_encode_step_1`
# (interleaf slot, ascending) but fills the matching *k-space data* in profile order; if a
# frame's interleaves are not already in ascending-step order the arms get paired with the
# wrong data and the recon is pure noise. So sort each frame's profiles by encode step.
# Also drop the 3rd trajectory row (normalised readout time, not a k-coordinate) and give
# the zero dwell time a dummy value (only used for off-resonance, irrelevant to the direct
# gridding recon). Cartesian sources pass through untouched.
function prepare_raw!(raw; max_frames = 8)
    occursin("spiral", lowercase(get(raw.params, "trajectory", "cartesian"))) || return raw
    ninter = length(unique(p.head.idx.kspace_encode_step_1 for p in raw.profiles))
    ninter == 0 && return raw
    nframes = min(max_frames, length(raw.profiles) ÷ ninter)
    keep = Profile[]
    for f in 0:(nframes - 1)
        block = raw.profiles[(f * ninter + 1):((f + 1) * ninter)]
        sort!(block; by = p -> p.head.idx.kspace_encode_step_1)
        for p in block
            p.head.idx.repetition = f
            p.head.idx.slice = 0
            p.head.idx.contrast = 0
            p.head.idx.average = 0
            p.head.sample_time_us == 0 && (p.head.sample_time_us = 1.0f0)
            if size(p.traj, 1) > 2
                p.traj = p.traj[1:2, :]
                p.head.trajectory_dimensions = 2
            end
            push!(keep, p)
        end
    end
    raw.profiles = keep
    encSz = get(raw.params, "encodedSize", Int[])
    if length(encSz) >= 3 && encSz[3] == 1
        raw.params["encodedSize"] = encSz[1:2]
        haskey(raw.params, "reconSize") && (raw.params["reconSize"] = raw.params["reconSize"][1:2])
    end
    return raw
end

# Export a few representative slices/frames of a reconstructed image as grayscale PNGs.
# MRIReco's direct recon returns coil images with layout (x, y, …, contrast, channel,
# repetition); combine coils by root-sum-of-squares, then flatten the remaining axes
# (slices, frames, contrasts) into a stack and save up to `nframes` evenly spaced frames.
# Returns the number written.
function export_pngs(label, d; nchan = 1, nframes = 4)
    cd = Array(d)
    caxis = ndims(cd) - 1
    if nchan > 1 && ndims(cd) >= 3 && size(cd, caxis) == nchan
        cd = sqrt.(sum(abs2, cd; dims = caxis))
    end
    m = abs.(cd)
    nx, ny = size(m, 1), size(m, 2)
    # Crop the readout axis when CMRxRecon-style 2× oversampling leaves an empty border
    # (nx ≫ ny), so the anatomy fills the frame rather than floating in black.
    if nx >= 1.6 * ny
        lo = nx ÷ 4 + 1
        m = m[lo:(lo + nx ÷ 2 - 1), :, ntuple(_ -> Colon(), ndims(m) - 2)...]
        nx = size(m, 1)
    end
    stack = reshape(m, nx, ny, :)
    nf = size(stack, 3)
    idxs = unique(round.(Int, range(1, nf; length = min(nframes, nf))))
    mkpath(RESULTS_DIR)
    stem = _slug(label)
    n = 0
    for i in idxs
        frame = @view stack[:, :, i]
        mx = maximum(frame)
        mx > 0 || continue
        # Normalise to [0,1] and orient so x runs horizontally (transpose the (x,y) frame).
        img = permutedims(Float64.(frame) ./ mx)
        PNGFiles.save(joinpath(RESULTS_DIR, @sprintf("%s_frame%02d.png", stem, i)), img)
        n += 1
    end
    return n
end

# Build the reconstruction parameters for an acquisition. Fully-sampled data reconstructs
# with the cheap direct (gridding) method; undersampled data (CMRxRecon-300, regular k-t
# pattern at R≈3) would alias ~3-fold under a direct recon, so reconstruct it with SENSE
# (`multiCoil`) using ESPIRiT coil sensitivities. CMRxRecon's ISMRMRD carries the ACS
# region as separate `ACQ_IS_PARALLEL_CALIBRATION` profiles, which `AcquisitionData` drops
# from the imaging data; rebuild a calibration-only acquisition (flag cleared) to estimate
# the maps, falling back to self-calibration when no ACS lines are present.
function recon_params(raw, acq; undersampled::Bool)
    params = MRIReco.defaultRecoParams()
    undersampled || return (params, "direct")
    params[:reco] = "multiCoil"
    calib = [p for p in raw.profiles if flag_is_set(p, "ACQ_IS_PARALLEL_CALIBRATION")]
    if !isempty(calib)
        clean = deepcopy(calib)
        for p in clean
            flag_remove!(p, "ACQ_IS_PARALLEL_CALIBRATION")
        end
        acq_calib = AcquisitionData(RawAcquisitionData(raw.params, clean))
        params[:senseMaps] = espirit(acq_calib, (6, 6), 24, eigThresh_1 = 0.02, eigThresh_2 = 0.95)
    else
        params[:senseMaps] = espirit(acq, (6, 6), 24, eigThresh_1 = 0.02, eigThresh_2 = 0.95)
    end
    return (params, "multiCoil")
end

# Reconstruct one entry, report a finite, non-trivial image and export representative PNGs.
function try_recon(label, entry; max_bytes = 1_500_000_000)
    sz = entry.approx_size_bytes
    if sz !== nothing && sz > max_bytes
        return println(@sprintf("%-34s SKIP  (%.0f MB > budget)", label, sz / 1.0e6))
    end
    return try
        raw = load_raw(entry)
        prepare_raw!(raw)
        acq = AcquisitionData(raw)
        params, reco = recon_params(raw, acq; undersampled = entry.fully_sampled === false)
        d = Array(MRIReco.reconstruction(acq, params))
        ok = all(isfinite, d) && maximum(abs, d) > 0
        # SENSE already combines coils (one image, channel axis = 1); a direct recon keeps
        # per-coil images, so tell the PNG export how many coils to root-sum-of-square.
        nchan = reco == "multiCoil" ? 1 : MRIBase.numChannels(acq)
        npng = ok ? export_pngs(label, d; nchan = nchan) : 0
        println(@sprintf("%-34s %s  dims=%-26s profiles=%-6d pngs=%d", label, ok ? "OK " : "BAD", string(size(d)), length(raw.profiles), npng))
    catch e
        println(@sprintf("%-34s ERROR: %s", label, sprint(showerror, e)[1:min(end, 150)]))
    end
end

# Smallest entry by known size (unknown sizes sort last).
smallest(es) = isempty(es) ? nothing : first(sort(es; by = e -> something(e.approx_size_bytes, typemax(Int))))

# Gather every candidate (label, entry) up front, then reconstruct those matching the
# optional CLI filter. Each `nothing` entry (modality absent from the offline catalog) is
# dropped.
candidates = Pair{String, DatasetEntry}[]
add!(label, e) = (e === nothing || push!(candidates, label => e))

# CMRxRecon-300 — Cine SAX/LAX + T1/T2 mapping.
let d3 = list_datasets(CMRXRECON300; offline = true)
    for (mod, lbl) in (
            ("Cine SAX", "CMRxRecon300 Cine SAX"), ("Cine LAX", "CMRxRecon300 Cine LAX"),
            ("T1map", "CMRxRecon300 T1 map"), ("T2map", "CMRxRecon300 T2 map"),
        )
        add!(lbl, smallest(filter(x -> get(x.extra, "modality", "") == mod, d3)))
    end
end

# CMRxRecon2024 — Cine, Mapping, Aorta, Tagging, Flow2d, BlackBlood.
let d2 = list_datasets(CMRXRECON2024; offline = true)
    for mod in ("Cine", "Mapping", "Aorta", "Tagging", "Flow2d", "BlackBlood")
        add!("CMRxRecon2024 $mod", smallest(filter(x -> get(x.extra, "modality", "") == mod, d2)))
    end
end

# mridata.org (3-D Cartesian) + OCMR (cardiac cine).
# Pin a known-good 2-D Cartesian multi-slice volume (1.3 GB): the size-only "smallest"
# otherwise selects degenerate calibration/spectroscopy scans that MRIReco cannot grid.
let mr = filter(e -> e.id == "9270505a-8d77-4e43-ac43-0d9910b81510", list_datasets(MRIDATA; offline = true))
    add!("mridata.org (fully-sampled 3-D)", isempty(mr) ? nothing : first(mr))
end
let ocs = filter(e -> e.fully_sampled === true, list_datasets(OCMR_SOURCE; offline = true))
    add!("OCMR (cardiac cine)", isempty(ocs) ? nothing : first(ocs))
end

# USC Speech — non-Cartesian (spiral) vocal-tract rtMRI. Reconstruct a couple of
# representative sub001 utterances (smallest first to keep the range-extract cheap).
let usc = sort(
        filter(e -> get(e.extra, "subject", "") == "sub001", list_datasets(USC_SPEECH; offline = true));
        by = e -> something(e.approx_size_bytes, typemax(Int)),
    )
    for e in first(usc, min(2, length(usc)))
        add!("USC Speech $(last(split(e.id, '/')))", e)
    end
end

println("=== MRIReco reconstruction across data types ===")
FILTER === nothing || println("filter: $(repr(ARGS[1]))")
println("results → $(RESULTS_DIR)")

ran = 0
for (label, e) in candidates
    selected(label, e) || continue
    global ran += 1
    try_recon(label, e)
end
ran == 0 && println(FILTER === nothing ? "(no candidates available)" : "(no candidates matched filter $(repr(ARGS[1])))")
