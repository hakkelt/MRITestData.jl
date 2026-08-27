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
| [`USC_SPEECH`](https://sail.usc.edu/span/75speakers/) | 8-channel spiral vocal-tract real-time speech rtMRI (GE 1.5 T), 75 speakers | ISMRMRD `.h5` | figshare (CC-BY) |
| [`M4RAW`](https://github.com/mylyu/M4Raw) | 4-channel fully-sampled Cartesian brain k-space (0.3 T low-field), multi-contrast/repetition, 183 subjects | fastMRI `.h5` → ISMRMRD | Zenodo (CC-BY) |
| [`FASTMRI`](https://fastmri.med.nyu.edu) | knee, brain, prostate, breast multi-coil k-space (NYU/FAIR) | fastMRI `.h5` → ISMRMRD | form-gated (90-day signed URLs) |

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
- **USC Speech (SPAN 75-speaker)** — real-time speech production MRI from the USC Speech
  Production and Articulation kNowledge (SPAN) group: 75 speakers imaged on a GE Signa
  Excite **1.5 T** scanner with a custom **8-channel** upper-airway array, using a
  **13-interleaf spiral-out** spoiled GRE. Only the **2drt** mid-sagittal vocal-tract raw
  k-space is cataloged; it ships already as vendor-agnostic **MRD/ISMRMRD `.h5`** (k-space
  samples plus trajectory and density-compensation tables), so it loads through the default
  `load_raw` path with no conversion. This adds **non-Cartesian (spiral), 1.5 T** raw data
  — a different acquisition regime from the package's other (Cartesian, cardiac) sources.
  The corpus is a single ~570 GB `dataset.zip` on figshare (CC-BY, no account); this package
  pulls one `.h5` member via ZIP range-extraction rather than downloading the whole archive.
- **M4Raw** — a multi-contrast, multi-repetition **low-field brain** k-space dataset acquired
  from 183 volunteers on a **0.3 T** whole-body scanner with a **4-channel** head coil. Each
  member is one *study × contrast × repetition* (T1w / T2w / FLAIR, plus T1 GRE) of
  **fully-sampled Cartesian** k-space in the **fastMRI HDF5** layout
  (`kspace`/`reconstruction_rss`/`ismrmrd_header`), converted to a cached ISMRMRD file on
  first load — so a plain inverse FFT reconstructs it (no parallel imaging needed). This adds
  the package's first **low-field (0.3 T) brain** source. The corpus ships as several multi-GB
  ZIPs on Zenodo (CC-BY, no account); this package pulls one `.h5` member via ZIP
  range-extraction rather than downloading the whole archive.
- **fastMRI** — the NYU / FAIR fastMRI dataset: knee, brain, prostate, and breast multi-coil
  k-space in the **fastMRI HDF5** layout (`kspace`/`reconstruction_rss`/`ismrmrd_header`), the
  same format M4Raw uses (converted to cached ISMRMRD on first load). Scan counts per anatomy
  range from a few hundred to tens of thousands, acquired on clinical Siemens/GE scanners.
  Access is **form-gated**: fill the request form at [fastmri.med.nyu.edu](https://fastmri.med.nyu.edu);
  the confirmation email contains **90-day pre-signed AWS S3 URLs**. Knee and brain ship as
  `.tar.xz`, range-extracted per member via **xz block-level HTTP range requests** (each xz
  block is independently compressed); prostate and breast ship as `.tar.gz`, range-extracted
  via the same **zran** checkpoint approach used for CMRxRecon-300. A pre-built offset map
  (`data/fastmri_map.csv`, plus per-archive checkpoint indices in `data/fastmri_zran/` for the
  `.tar.gz` archives) records member positions; it is generated once by the maintainer scripts
  `scripts/index_fastmri.jl` (xz) and `scripts/index_fastmri_gz.jl` (gz). See
  [fastMRI: form-gated credentials](@ref) in Usage for the credential setup workflow.

!!! warning "Data source terms of use"
    This package's MIT license covers **its code only**. Downloaded **data is
    governed by each provider's own license and terms**. You must review and comply
    with each provider's terms **before** using, redistributing, or publishing
    results derived from the data:

    - **mridata.org** → [http://mridata.org/terms](http://mridata.org/terms)
    - **OCMR** → [https://www.ocmr.info/download/](https://www.ocmr.info/download/)
    - **fastMRI** → [https://fastmri.med.nyu.edu](https://fastmri.med.nyu.edu) (fastMRI Dataset Agreement)

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
