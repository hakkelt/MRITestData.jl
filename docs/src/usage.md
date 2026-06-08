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

### Interactive browser

MRITestData ships a full-screen terminal browser built on
[Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl)'s `PagedDataTable`.
Call it directly from the Julia REPL:

```julia
using MRITestData
run_browser()                            # browse all sources
run_browser(; sources = OCMR_SOURCE)    # one source only
run_browser(; offline = true)           # skip the network
```

Inside the browser:
- **↑ ↓** — move the selection; **PgUp/PgDn**, **Home/End** — change page.
- **`/`** — global text search across all columns.
- **`f`** — open the filter modal (per-column typed filters).
- **`1`-`9`** — sort by that column (toggles ascending/descending).
- **Enter** — select the highlighted dataset and start the download flow.
- **`q` / Esc** — quit without downloading.

After selecting a dataset you are asked to confirm the download (`y`/`n`) and to
choose a destination path. The default is `<current directory>/<id>.h5`; press
Enter to accept it.

**Standalone shell command (optional)**

MRITestData can also be installed as a standalone `mridata-browse` command
(adds it to `~/.julia/bin`):

```julia
using Pkg
Pkg.Apps.add("MRITestData")          # from the registry
# or, from a local clone:
Pkg.Apps.develop(path = "/path/to/MRITestData")
```

Make sure `~/.julia/bin` is on your `PATH`, then launch:

```sh
mridata-browse            # browse all sources
mridata-browse --offline  # use the bundled index without hitting the network
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

## Working with the raw data (no reconstruction package)

```julia
raw  = load_raw(path)        # MRIBase.RawAcquisitionData (profiles + XML header)
acq  = load_acq(path)        # MRIBase.AcquisitionData
spec = acq_spec(path)        # source-agnostic NamedTuple (:cartesian/:noncartesian)
```
