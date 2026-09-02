# Tutorial

A complete, copy-pasteable walk-through: from a cold Julia session to a reconstructed
cardiac image. It uses **OCMR** because it is the smallest source and needs **no
account or token** — every file is a direct HTTP download of a few tens of MB.

If a term is unfamiliar, see [Concepts & data model](@ref) and the [Glossary](@ref).

## 1. Install

```julia
using Pkg
Pkg.add(url = "https://github.com/hakkelt/MRITestData.jl")   # not yet in the General registry
```

`MRITestData` pulls in `MRIFiles` (and HDF5) but **no** reconstruction
package. For the reconstruction step below you also need:

```julia
Pkg.add(["MRIReco", "MRICoilSensitivities"])
```

## 2. Find a dataset

```julia
using MRITestData

# Every source:
list_sources()
# 7-element Vector{AbstractSource}: MRIDATA, OCMR_SOURCE, CMRXRECON2024, …

# Fully-sampled OCMR cine acquisitions at 1.5 T:
entries = list_datasets(OCMR_SOURCE; fully_sampled = true, field_strength = 1.5)
entry   = first(entries)
```

`entry` is a [`DatasetEntry`](@ref). Inspect it:

```julia
julia> entry.id
"fs_0001_1_5T"

julia> entry.anatomy, entry.orientation, entry.field_strength
(:heart, :short_axis, 1.5)

julia> entry.receiver_channels        # nothing — OCMR doesn't publish coil counts;
nothing                               #   it's inside the file, known after load_raw

julia> entry.extra["scanner_model"]
"Siemens MAGNETOM Avanto"
```

Filters accept a scalar (`==`), a tuple/vector (membership) or a predicate:

```julia
list_datasets(OCMR_SOURCE; field_strength = (1.5, 3.0))
list_datasets(OCMR_SOURCE; fully_sampled = e -> e == true)
```

To search *across* sources, or on `extra` keys, or by free text, use [`query`](@ref)
instead — see [Searching across sources](@ref).

## 3. Download

Pick a download destination once — it is persisted across sessions, and nothing
downloads until it is set:

```julia
MRITestData.set_download_path!(:cache)          # the per-package Scratch cache
# MRITestData.set_download_path!("/data/mri")   # …or a directory of your choice
```

```julia
path = download_dataset(entry)
# progress bar …
# "/…/scratchspaces/…/ocmr/fs_0001_1_5T.h5"
```

The file lands in the configured location and is **not re-downloaded** next time.
Transfers stream to a `.part` file and are renamed atomically, so an interrupted
download never corrupts the cache. `is_cached(entry)` / `cache_path(entry)` query it;
`clear_cache()` empties it.

You can skip this step — [`load_raw`](@ref) downloads on demand.

## 4. Load the raw data

```julia
raw = load_raw(entry)          # or load_raw(path)
```

`raw` is a
[`RawAcquisitionData`](https://magneticresonanceimaging.github.io/MRIReco.jl/latest/acquisitionData/#Raw-Data):

```julia
julia> length(raw.profiles)               # readout lines
5808

julia> size(raw.profiles[1].data)         # samples × channels
(384, 18)                                  # 18-channel coil array

julia> raw.params["encodedSize"]
3-element Vector{Int64}: [384, 176, 1]

julia> raw.params["trajectory"]
"cartesian"
```

See [What `load_raw` returns](@ref) for the full structure. The temporal cine frames
are on the ISMRMRD **contrast** axis.

## 5. Reconstruct (fully sampled → direct)

`MRITestData` stops at raw data. Hand it to [MRIReco.jl](https://github.com/MagneticResonanceImaging/MRIReco.jl):

```julia
using MRIReco

acq = AcquisitionData(raw)                 # re-exported by MRIReco

params = MRIReco.defaultRecoParams()
params[:reco] = "direct"                    # inverse FFT — correct for fully-sampled data
img = MRIReco.reconstruction(acq, params)   # AxisArray [x, y, z, echo, coil, rep]

julia> size(img)
(384, 176, 1, 25, 18, 1)                    # 25 cine frames, 18 coils
```

Combine coils (root-sum-of-squares) and view the first frame:

```julia
using MRIReco: AxisArrays
mag = sqrt.(sum(abs2, img.data; dims = 5))[:, :, 1, 1, 1, 1]

# (optional) drop the 2× readout oversampling
mag = mag[(size(mag, 1) ÷ 4 + 1):(3 * size(mag, 1) ÷ 4), :]

using PNGFiles
PNGFiles.save("ocmr_frame01.png", permutedims(mag ./ maximum(mag)))
```

That is a clean cardiac cine frame:

![OCMR cardiac cine](assets/recon/ocmr_cine.png)

## 6. Reconstruct undersampled data (parallel imaging)

`OCMR`'s `us_*` files, all of `CMRXRECON300`, and fastMRI test/prostate/breast are
**undersampled** — a direct recon aliases. Use CG-SENSE (`"multiCoil"`) with coil
sensitivity maps from an ESPIRiT calibration. Full runnable example:
[Reconstructing undersampled data](@ref).

```julia
using MRITestData, MRIReco, MRICoilSensitivities
using MRIReco: flag_is_set, flag_remove!

entry = first(list_datasets(CMRXRECON300; offline = true))   # R ≈ 3, ships ACS
raw   = load_raw(entry)
acq   = AcquisitionData(raw)

# CMRxRecon-300 writes the ACS lines into the same file, flagged
# ACQ_IS_PARALLEL_CALIBRATION. AcquisitionData drops them from the imaging data;
# rebuild a calibration-only acquisition (flag cleared) to estimate the maps.
calib = [p for p in raw.profiles if flag_is_set(p, "ACQ_IS_PARALLEL_CALIBRATION")]
for p in calib; flag_remove!(p, "ACQ_IS_PARALLEL_CALIBRATION"); end
acq_calib = AcquisitionData(RawAcquisitionData(raw.params, calib))

params = MRIReco.defaultRecoParams()
params[:reco] = "multiCoil"
params[:senseMaps] = espirit(acq_calib, (6, 6), 24; eigThresh_1 = 0.02, eigThresh_2 = 0.95)
img = MRIReco.reconstruction(acq, params)   # de-aliased, coil-combined
```

The same direct recon on this data would show ~3-fold aliasing:

![CMRxRecon-300 direct recon aliases](assets/recon/cmrxrecon300_cine_sax.png)

## Next steps

- [Usage](@ref) — filtering, the interactive browser, the self-updating index, caching.
- [Dataset contents](@ref) — exactly what each of the seven sources contains.
- [Reconstruction with MRIReco](@ref) — every source and modality, with example
  output dimensions and the reconstruction-method references.
- [FAQ & troubleshooting](@ref) — Synapse tokens, fastMRI credentials, disk footprint,
  network failures.
