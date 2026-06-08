# MRITestData.jl

<a href="https://hakkelt.github.io/MRITestData.jl/stable/"><img src="https://img.shields.io/badge/docs-stable-blue.svg"></a>
<a href="https://hakkelt.github.io/MRITestData.jl/dev/"><img src="https://img.shields.io/badge/docs-dev-blue.svg"></a>
<a href="https://github.com/hakkelt/MRITestData.jl/actions/workflows/CI.yml?query=branch%3Amaster"><img src="https://github.com/hakkelt/MRITestData.jl/actions/workflows/CI.yml/badge.svg?branch=master"></a>
<a href="https://codecov.io/gh/hakkelt/MRITestData.jl"><img src="https://codecov.io/gh/hakkelt/MRITestData.jl/branch/master/graph/badge.svg"></a>
<a href="https://github.com/JuliaTesting/Aqua.jl"><img src="https://img.shields.io/badge/Aqua.jl-%F0%9F%8C%A2-aqua.svg"></a>
<a href="https://github.com/aviatesk/JET.jl"><img src="https://img.shields.io/badge/%F0%9F%9B%A9%EF%B8%8F_tested_with-JET.jl-233f9a"></a>
<a href="https://github.com/fredrikekre/Runic.jl"><img src="https://img.shields.io/badge/code_style-%E1%9A%B1%E1%9A%A2%E1%9A%BE%E1%9B%81%E1%9A%B2-black"></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-brightgreen.svg?style=flat"></a>

Query and download free, open-access **MRI k-space datasets** and load them into
[MRIReco.jl](https://github.com/MagneticResonanceImaging/MRIReco.jl), so
reconstruction code can be exercised on real Cartesian and non-Cartesian scanner
data instead of only synthetic phantoms.

> [!IMPORTANT]
> The MIT license covers **this package's code only**. Datasets you download are
> governed by **each provider's own license and terms** (mridata.org per-dataset
> terms; OCMR's data-use terms and required citation). You are responsible for
> complying with them. See [Licensing & legal](https://hakkelt.github.io/MRITestData.jl/stable/legal/).

Supported sources (v1):

| Source | Contents | Format |
| --- | --- | --- |
| [`MRIDATA`](https://mridata.org) | multi-vendor raw k-space (knee, brain, …) | ISMRMRD `.h5` |
| [`OCMR_SOURCE`](https://ocmr.info) | cardiac multi-coil cine (fully sampled + undersampled) | ISMRMRD `.h5` |

Both sources serve ISMRMRD, which is read via
[`MRIFiles`](https://github.com/MagneticResonanceImaging/MRIReco.jl)/`MRIBase`.

`MRITestData` integrates with **MRIReco** through an optional package extension
that activates automatically when the package is loaded:

| Load this… | …to enable | Entry point |
| --- | --- | --- |
| `MRIReco` | reconstruct directly from the loaded k-space | [`recon`](#reconstruction-with-mrireco) |

## Installation

```julia
pkg> add MRITestData
```

`MRITestData` depends on `MRIFiles`/`MRIBase` (which pull in HDF5) but **not** on
either reconstruction package — those are weak dependencies.

## Discovering datasets (offline)

```julia
using MRITestData

list_sources()                                  # [MRIDATA, OCMR_SOURCE]
list_datasets(OCMR_SOURCE; fully_sampled = true)
list_datasets(MRIDATA; anatomy = :knee, field_strength = 3.0)

# Filters: scalar (==), vector/tuple (membership), or a predicate function
list_datasets(MRIDATA; coils = c -> c !== nothing && c >= 8)
```

## Reconstruction with MRIReco

`recon` reconstructs directly from the downloaded k-space using
[MRIReco.jl](https://github.com/MagneticResonanceImaging/MRIReco.jl). It accepts an
`MRIBase.AcquisitionData`, an ISMRMRD path, or a catalog entry/handle (downloaded if
needed). Keywords are forwarded to MRIReco's `reconstruction`.

```julia
using MRITestData, MRIReco

entry = first(list_datasets(OCMR_SOURCE; fully_sampled = true))
img   = recon(entry; reco = "direct")                 # download + reconstruct

# or stage-by-stage
acq = load_acq(download_dataset(entry; max_bytes = 2_000_000_000))
img = recon(acq; reco = "standard", iterations = 30)  # iterative
img = recon(acq; reco = "multiCoil", senseMaps = smaps)
```

The returned image is MRIReco's `AxisArray` with axes `[x, y, z, echo, coil, rep]`.

Any mridata.org UUID works even if it is not in the curated catalog:

```julia
img = recon(dataset(MRIDATA, "52c2fd53-d233-4444-8bfd-7c454240d314"))
```

## Working with the raw data (no reconstruction package required)

Without `MRIReco` loaded you can still use the `MRIBase` layer:

```julia
using MRITestData
raw  = load_raw(path)        # MRIBase.RawAcquisitionData (profiles + XML header)
acq  = load_acq(path)        # MRIBase.AcquisitionData
spec = acq_spec(path)        # source-agnostic NamedTuple (:cartesian/:noncartesian)
```

## Caching

Downloads are cached in a per-package scratchspace (persists across sessions).
Transfers go to a temporary `.part` file and are renamed atomically on success,
so an interrupted download never poisons the cache. A `.meta.toml` sidecar records
the URL, size and SHA-256.

```julia
cache_path(entry); is_cached(entry)
clear_cache()                       # all sources
clear_cache(; source = OCMR_SOURCE) # one source
```

## Notes / current limitations (v1)

- **Image size** is taken from the ISMRMRD `encodedSize` (no automatic crop to
  `reconSize`; oversampling/partial-Fourier dimensions are preserved).
- **Density compensation** is not estimated — non-Cartesian datasets load with
  `dcf = nothing`. Supply your own DCF if your reconstruction needs it.
- The committed **mridata.org catalog** ([`data/mridata_index.toml`](data/mridata_index.toml))
  is a small curated seed. Add verified UUIDs there, or pass any UUID directly to
  `dataset(MRIDATA, uuid)`.

## Adding datasets

- **mridata.org**: append a `[[dataset]]` block to `data/mridata_index.toml` with
  the UUID from the dataset's mridata.org page and whatever attributes you know.
- **OCMR**: add a row to `data/ocmr_attributes.csv` (the file-name column drives
  the download URL).

## Testing

```julia
pkg> test MRITestData
```

Offline tests synthesise tiny ISMRMRD files on the fly (no committed binaries, no
network) and reconstruct them through the MRIReco extension. Live-download tests
are gated behind an environment variable:

```bash
# live downloads from mridata.org / OCMR
MRITESTDATA_NETWORK_TESTS=true julia --project=test test/runtests.jl
```
