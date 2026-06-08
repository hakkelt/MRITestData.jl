# MRITestData.jl

Query and download free, open-access **MRI k-space datasets** and load them into
MRI reconstruction packages, so reconstruction code can be exercised on *real*
scanner data instead of only synthetic phantoms.

Supported sources:

| Source | Contents | Format |
| --- | --- | --- |
| [`MRIDATA`](https://mridata.org) | multi-vendor raw k-space (knee, brain, …) | ISMRMRD `.h5` |
| [`OCMR_SOURCE`](https://ocmr.info) | cardiac multi-coil cine (fully sampled + undersampled) | ISMRMRD `.h5` |

Both serve ISMRMRD, which is read via
[`MRIFiles`](https://github.com/MagneticResonanceImaging/MRIReco.jl)/`MRIBase`.

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

# Load into MRIBase containers
raw = load_raw(path)    # MRIBase.RawAcquisitionData
acq = load_acq(path)    # MRIBase.AcquisitionData
```

See [Usage](@ref) for the full workflow, filtering, the interactive browser, and
dynamic-index controls.
