# Concepts & data model

This page is the background a newcomer needs before the [Tutorial](@ref) and
[Usage](@ref). It explains what the package hands you and the MRI terms the catalog
uses. If you already work with raw k-space and ISMRMRD, skip to [Usage](@ref).

See the [Glossary](@ref) for one-line definitions of the acronyms (SAX, ACS, SSFP,
MOLLI, …).

## k-space, briefly

An MRI scanner does not measure an image directly. It measures the image's 2-D (or
3-D) **spatial Fourier transform**, sample by sample, along a trajectory through
frequency space. That raw measurement is **k-space**. An image is recovered by an
inverse Fourier transform — *if* k-space was sampled densely enough (the Nyquist
criterion).

- **Fully sampled** — every k-space line the field of view requires was acquired. A
  plain inverse FFT gives an artifact-free image. Most `MRIDATA`, `M4RAW`, fully-sampled
  `OCMR`, `CMRXRECON2024`, and the fastMRI train/val splits are like this.
- **Undersampled** — lines were deliberately skipped to shorten the scan. An inverse FFT
  then **aliases** (the anatomy folds onto itself). Recovering a clean image needs
  *parallel imaging* (multiple receive coils + a calibration region) or compressed
  sensing. `CMRXRECON300`, the `us_*` `OCMR` files, fastMRI test/prostate/breast are
  undersampled.
- **ACS / calibration** — a small block of fully-sampled lines at the centre of k-space,
  used to estimate coil sensitivities for parallel-imaging reconstruction.
  `CMRXRECON300` ships these as paired `_calib` files.

The undersampling factor is the **acceleration** `R` (`entry.acceleration`): `R = 2`
means half the lines were acquired.

### Multi-coil data

Modern scanners receive with an array of coils (`entry.receiver_channels`), each with a
different spatial sensitivity. Every k-space dataset here is therefore a stack of
per-coil k-spaces. Coil images are combined either by a root-sum-of-squares (magnitude
only) or, in parallel imaging, by a sensitivity-weighted solve that also removes
aliasing.

`CMRXRECON2024` compresses its physical coils to 10 **virtual** channels by SVD
(`entry.coil_data == :derived`); the others keep the physical channels.

### Trajectory

- **Cartesian** (`:cartesian`) — k-space sampled on a rectilinear grid; inverse FFT
  applies directly. All sources except USC Speech.
- **Non-Cartesian** — samples lie off-grid (spiral, radial). Reconstruction needs
  *gridding* or a non-uniform FFT plus a **density-compensation** weighting.
  `USC_SPEECH` is 13-interleaf spiral and ships its trajectory + density-compensation
  tables inside the file.

## ISMRMRD

[ISMRMRD](https://ismrmrd.readthedocs.io/) (ISMRM Raw Data) is a vendor-neutral HDF5
container for raw MR acquisitions: a flat list of **acquisitions** (readout lines, a.k.a.
*profiles*), each carrying its raw complex samples plus an *encoding counter*
(which phase-encode line, slice, contrast, repetition, …), and one **XML header**
describing the experiment (encoded/recon matrix, field of view, TE/TR, receiver-channel
count, trajectory type, …).

`MRIDATA`, `OCMR` and `USC_SPEECH` are distributed as ISMRMRD `.h5` and load directly.
`CMRXRECON2024`, `CMRXRECON300`, `M4RAW` and `FASTMRI` ship other layouts (MATLAB `.mat`
k-space, or the fastMRI HDF5 layout) and are converted to a **cached** ISMRMRD file the
first time you load them — so every source behaves the same downstream.

## What `load_raw` returns

[`load_raw`](@ref) always returns a
[`RawAcquisitionData`](https://magneticresonanceimaging.github.io/MRIReco.jl/latest/acquisitionData/#Raw-Data):

```julia
raw = load_raw(entry)

raw.params      # Dict — the parsed ISMRMRD header:
                #   "encodedSize", "reconSize", "encodedFOV", "trajectory",
                #   "receiverChannels", "TE", "TR", "H1resonanceFrequency_Hz", …
raw.profiles    # Vector{Profile} — one readout line each:
raw.profiles[1].head           # EncodingCounters: kspace_encode_step_1 (phase-encode
                               #   line), slice, contrast, repetition, set, flags, …
raw.profiles[1].data           # Matrix{ComplexF32} (samples × channels)
raw.profiles[1].traj           # Matrix (k-space coordinates) — non-Cartesian only
```

Axis conventions used throughout this package when converting a source to ISMRMRD:

| Physical axis | ISMRMRD counter |
|---|---|
| phase-encode line | `kspace_encode_step_1` |
| slice / partition | `slice` |
| temporal frame (cine) **or** parametric weighting (T1/T2 mapping) | `contrast` |
| signal average / repeat acquisition | `repetition` |

So a cine's frame index and a mapping series' inversion-time index both land on
**contrast**. `repetition` stays `0` unless the source is genuinely multi-repetition
(`M4RAW`).

`RawAcquisitionData` is *raw data*, not an image and not yet a reconstruction problem.
To reconstruct you build an `AcquisitionData` from it and hand that to a
reconstruction package — see [Reconstruction with MRIReco](@ref). This package
deliberately stops at the raw-data boundary.

## The catalog vocabulary

Datasets are described by a [`DatasetEntry`](@ref) whose field names, value sets and
units follow the **DICOM** standard wherever DICOM has an attribute for the concept
(`anatomy` is Body Part Examined, `contrast` is Acquisition Contrast, `field_strength`
is Magnetic Field Strength in tesla, …). Seven fields with no DICOM equivalent are
documented extensions. The full mapping, the extensions and the standards consulted are
in [Taxonomy](@ref).

Two practical rules:

- **`nothing` is an honest value, not a wildcard.** When a source does not record a
  field, that field is `nothing`, and a filter `field = nothing` matches exactly those
  unknown entries. To *not* filter on a field, omit it or pass `missing`.
- **Optional detail lives in `entry.extra`** — a `Dict` of source-specific metadata
  (scanner model, TE/TR, protocol name, …), keyed by DICOM keyword where one exists. Use
  [`extra_schema`](@ref)`(source)` to see what a given source carries.
