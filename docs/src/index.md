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
Reconstruction is provided through an optional package extension that activates
automatically when `MRIReco` is loaded:

| Load this… | …to enable | Entry point |
| --- | --- | --- |
| `MRIReco` | reconstruct directly from the loaded k-space | [`recon`](@ref) |

!!! warning "Data licensing"
    This package's MIT license covers **its code only**. Downloaded **data is
    governed by each provider's own license and terms**. See
    [Licensing & legal](@ref) before using or redistributing any dataset.

## Installation

```julia
pkg> add MRITestData
```

`MRITestData` depends on `MRIFiles`/`MRIBase` (which pull in HDF5) but **not** on
either reconstruction package — those are weak dependencies.

## Quick start

```julia
using MRITestData, MRIReco

# Discover (the dataset index self-updates from upstream; offline-safe)
entries = list_datasets(OCMR_SOURCE; fully_sampled = true)

# Download (cached) and reconstruct in one step
img = recon(first(entries); reco = "direct")
```

See [Usage](@ref) for the full workflow and the dynamic-index controls.
