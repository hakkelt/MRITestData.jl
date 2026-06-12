# MRITestData.jl

Query and download free, open-access **MRI k-space datasets** and load them into
MRI reconstruction packages, so reconstruction code can be exercised on *real*
scanner data instead of only synthetic phantoms.

Supported sources:

| Source | Contents | Format | Access |
| --- | --- | --- | --- |
| [`MRIDATA`](https://mridata.org) | multi-vendor fully-sampled raw k-space (3D knee, brain, …) | ISMRMRD `.h5` | direct download |
| [`OCMR_SOURCE`](https://ocmr.info) | cardiac multi-coil cine (fully sampled + undersampled) | ISMRMRD `.h5` | direct download |
| [`CMRXRECON2024`](https://cmrxrecon.github.io/2024/) | multi-coil Cartesian cardiac k-space (Cine, Mapping, Aorta, Tagging, Flow, BlackBlood) | MATLAB `.mat` → ISMRMRD | Synapse (token) |
| [`CMRXRECON300`](https://www.synapse.org/Synapse:syn52965326) | undersampled multi-coil cardiac k-space + ACS, 300 volunteers (cine + T1/T2 mapping) | MATLAB `.mat` → ISMRMRD | Synapse (token) |

All sources are exposed through one uniform pipeline — [`list_datasets`](@ref)/[`query`](@ref)
→ [`download_dataset`](@ref) → [`load_raw`](@ref) — yielding `MRIBase.RawAcquisitionData`.
ISMRMRD files are read via [`MRIFiles`](https://github.com/MagneticResonanceImaging/MRIFiles.jl)/`MRIBase`;
the CMRxRecon sources' `.mat` k-space is converted to a cached ISMRMRD file on first load.

## Data sources

- **mridata.org** — a community repository of **fully-sampled** raw k-space, mostly 3D
  Cartesian knee and brain volumes from GE/Siemens/Philips scanners. Per-dataset terms.
  Rich per-acquisition metadata (vendor, channels, matrix size, TE/TR, …) is scraped
  from the site.
- **OCMR** — the Open Cardiac MRI k-space repository: multi-coil **cardiac cine** from
  Siemens scanners (0.55 / 1.5 / 3 T), both fully sampled and pseudo-randomly
  undersampled. Coil counts are not published in OCMR's metadata (they live only inside
  each ISMRMRD file). Requires citing the OCMR paper.
- **CMRxRecon2024** — data from a MICCAI 2024 deep-learning cardiac reconstruction
  challenge. ~2,500 **fully-sampled** multi-coil Cartesian acquisitions (Siemens 3 T)
  spanning six modalities (Cine, Mapping, Aorta, Tagging, Flow2d, BlackBlood) across
  Training / Validation / Test subjects; coils are SVD-compressed to 10 virtual
  channels. The whole dataset is one ~1.2 TB split ZIP on Synapse — this package fetches
  individual `.mat` files via HTTP range requests (no full download), which needs a
  Synapse access token and completed challenge registration. See
  [CMRxRecon data types](@ref) for what each modality and view contains.
- **CMRxRecon-300** — the revised CMRxRecon-2023 k-space dataset: raw multi-coil cardiac
  k-space from 300 healthy volunteers (Siemens 3 T), with cine (long- and short-axis) plus
  T1/T2 mapping per subject. The `_ks` k-space is **undersampled** (regular k-t pattern,
  R≈3) and paired with fully-sampled ACS `_calib` files, so artifact-free reconstruction
  needs parallel imaging (e.g. ESPIRiT/CG-SENSE) rather than a plain inverse FFT. The data
  ships as `.tar.gz`
  archives (Training / Validation / Test) split into 16 GiB fragments on Synapse (≈580 GB
  total, CC-BY, free Synapse account — no challenge registration). A `.tar.gz` is a single
  gzip stream and cannot be range-extracted per file like a ZIP, so this package ships a
  precomputed **zran** (zlib random-access) checkpoint index — one checkpoint placed just
  before each file — that lets it resume decompression immediately before the requested
  `.mat` and pull it with HTTP range requests, streaming essentially just that file rather
  than the whole archive.

!!! warning "Data source terms of use"
    This package's MIT license covers **its code only**. Downloaded **data is
    governed by each provider's own license and terms**. You must review and comply
    with each provider's terms **before** using, redistributing, or publishing
    results derived from the data:

    - **mridata.org** → [http://mridata.org/terms](http://mridata.org/terms)
    - **OCMR** → [https://www.ocmr.info/download/](https://www.ocmr.info/download/)

    See [Licensing & legal](@ref) for full details. Call
    `MRITestData.dismiss_terms_notice!()` to permanently suppress the startup
    reminder once you have reviewed the terms.

## Installation

```julia
pkg> add MRITestData
```

`MRITestData` depends on `MRIFiles`/`MRIBase` (which pull in HDF5).

## Quick start

```julia
using MRITestData

# Discover (the dataset index self-updates from upstream; offline-safe)
entries = list_datasets(OCMR_SOURCE; fully_sampled = true)

# Download (cached) → returns path to the local .h5 file
path = download_dataset(first(entries))

# Load into an MRIBase container
raw = load_raw(path)    # MRIBase.RawAcquisitionData (or pass the entry directly)
```

See [Usage](@ref) for the full workflow, filtering, the interactive browser, and
dynamic-index controls.
