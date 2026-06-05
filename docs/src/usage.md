# Usage

## Discovering datasets

```julia
using MRITestData

list_sources()                                    # [MRIDATA, OCMR_SOURCE]
list_datasets(OCMR_SOURCE; fully_sampled = true)
list_datasets(MRIDATA; anatomy = :knee, field_strength = 3.0)
```

Filters match a [`DatasetEntry`](@ref) field by a scalar (`==`), a vector/tuple
(membership), or a predicate function:

```julia
list_datasets(MRIDATA; coils = c -> c !== nothing && c >= 8)
list_datasets(OCMR_SOURCE; field_strength = (1.5, 3.0))
```

### Searching across sources

[`query`](@ref) searches **one or several** sources at once with the same filter
vocabulary. Unknown keywords are matched against each entry's `extra` metadata, and
`text` does a case-insensitive substring (or `Regex`/predicate) search over the
name, id, and string-valued `extra` fields:

```julia
query(; anatomy = :knee, fully_sampled = true)        # both sources
query(; sources = OCMR_SOURCE, field_strength = (1.5, 3.0))
query(; text = "prisma")                              # free-text
query(; subject = "patient")                          # an OCMR `extra` field
```

### Interactive search (TUI)

[`search_datasets`](@ref) opens a terminal menu (built on the stdlib
`REPL.TerminalMenus`) over the same query, lets you refine the free-text filter
live, and returns the selected [`DatasetEntry`](@ref). Pass `multiselect = true` to
return several:

```julia
entry = search_datasets(; anatomy = :knee)
entries = search_datasets(; sources = OCMR_SOURCE, multiselect = true)
```

## The self-updating index

Each source's catalog is backed by an **index** that is fetched from upstream and
cached in a scratchspace:

- **OCMR** — the authoritative `ocmr_data_attributes.csv` from OCMR's S3 bucket.
- **mridata.org** — scraped from `mridata.org/list` (the site has no JSON API).

The index is downloaded on first use, then refreshed automatically once it is older
than [`MRITestData.INDEX_TTL_DAYS`](@ref) (default 30 days). On any network failure
the bundled index that ships with the package is used instead, so discovery always
works offline.

```julia
refresh_index(OCMR_SOURCE)     # force a refresh now (manual trigger)
refresh_index()                # refresh every source
index_age_days(OCMR_SOURCE)    # nothing if never fetched (bundled fallback in use)

# Skip the network entirely (used by CI/offline tests):
list_datasets(OCMR_SOURCE; offline = true)
```

To change the refresh period:

```julia
MRITestData.INDEX_TTL_DAYS[] = 7   # refresh weekly
```

## Downloading and caching

```julia
entry = first(list_datasets(OCMR_SOURCE; fully_sampled = true))
path  = download_dataset(entry)            # ISMRMRD .h5 -> Scratch cache, returns path
```

Downloads stream to a temporary `.part` file and are renamed atomically on success,
so an interrupted transfer never poisons the cache. A `ProgressMeter` bar is shown
by default; pass `progress = false` to opt out. A generous `max_bytes` guard can
prevent accidentally pulling very large files:

```julia
download_dataset(entry; progress = false, max_bytes = 2_000_000_000)
```

Cache management:

```julia
cache_path(entry); is_cached(entry)
clear_cache()                       # all sources
clear_cache(; source = OCMR_SOURCE) # one source
```

## Reconstruction with MRIReco

Load `MRIReco` to enable [`recon`](@ref), which reconstructs directly from the
downloaded k-space. It accepts an `MRIBase.AcquisitionData`, an ISMRMRD path, or a
catalog entry/handle (downloaded if needed). Keywords are forwarded to MRIReco's
`reconstruction`.

```julia
using MRITestData, MRIReco

img = recon(entry; reco = "direct")                    # download + reconstruct
img = recon("scan.h5"; reco = "standard", iterations = 30)
```

The result is MRIReco's `AxisArray` with axes `[x, y, z, echo, coil, rep]`.

## Loading into MriReconstructionToolbox

Load `MriReconstructionToolbox` to convert an ISMRMRD file straight into its
`AcquisitionInfo` containers via [`load`](@ref) / [`load_dataset`](@ref):

```julia
using MRITestData, MriReconstructionToolbox

acq = load_dataset(entry)                       # downloads if needed, then loads
img = reconstruct(acq, Tikhonov(1e-3), CGNR(); maxit = 30)

acq = load("scan.h5"; as = :cartesian, echo = 1, rep = 1)
```

## Working with the raw data (no reconstruction package)

```julia
raw  = load_raw(path)        # MRIBase.RawAcquisitionData (profiles + XML header)
acq  = load_acq(path)        # MRIBase.AcquisitionData
spec = acq_spec(path)        # source-agnostic NamedTuple (:cartesian/:noncartesian)
```
