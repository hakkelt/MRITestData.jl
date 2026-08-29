# MRITestData.jl

Query and download free, open-access **MRI k-space datasets** and load them into MRI
reconstruction packages, so reconstruction code can be exercised on *real* scanner data
instead of only synthetic phantoms.

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

All sources are exposed through one uniform pipeline —
[`list_datasets`](@ref)/[`query`](@ref) → [`download_dataset`](@ref) →
[`load_raw`](@ref) — yielding an `MRIBase.RawAcquisitionData`. ISMRMRD files are read
via [`MRIFiles`](https://github.com/MagneticResonanceImaging/MRIFiles.jl)/`MRIBase`; the
`.mat` and fastMRI-layout sources are converted to a cached ISMRMRD file on first load.

**[Dataset contents](@ref)** is the authoritative per-source breakdown of every data
type — anatomy, contrasts/modalities, sampling, coils, array layout, file counts. This
page does not repeat it.

## Documentation map

| If you want to… | Read |
|---|---|
| understand k-space, ISMRMRD, and what `load_raw` returns | [Concepts & data model](@ref) |
| go from install to a reconstructed image | [Tutorial](@ref) |
| look up a term | [Glossary](@ref) |
| filter, browse, cache, reconstruct | [Usage](@ref) |
| know exactly what a source contains | [Dataset contents](@ref) |
| understand the catalog field names | [Taxonomy](@ref) |
| fix a credential / download / recon problem | [FAQ & troubleshooting](@ref) |
| know how archive range-extraction works, or regenerate an index | [Internals & maintainer notes](@ref) |
| check data licenses and required citations | [Licensing & legal](@ref) |

!!! warning "Data source terms of use"
    This package's MIT license covers **its code only**. Downloaded **data is governed
    by each provider's own license and terms**, which you must review and comply with
    **before** using, redistributing, or publishing results derived from the data. See
    [Licensing & legal](@ref). Call `MRITestData.dismiss_terms_notice!()` to suppress
    the startup reminder once you have reviewed the terms.

## Installation

The package is **not yet registered in the General registry**:

```julia
using Pkg
Pkg.add(url = "https://github.com/hakkelt/MRITestData.jl")
```

`MRITestData` depends on `MRIFiles`/`MRIBase` (which pull in HDF5) but **not** on any
reconstruction package.

## Quick start

```julia
using MRITestData

# Discover (the dataset index self-updates from upstream; offline-safe)
entries = list_datasets(OCMR_SOURCE; fully_sampled = true)

# Download (cached) → returns the path to the local .h5 file
path = download_dataset(first(entries))

# Load into an MRIBase container
raw = load_raw(path)    # MRIBase.RawAcquisitionData (or pass the entry directly)
```

The [Tutorial](@ref) continues from here to a reconstructed image.

## Citing

If MRITestData.jl helped your work, please cite it (see `CITATION.bib` in the
repository) **and** cite each dataset provider as their terms require — see
[Licensing & legal](@ref).
