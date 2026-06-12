# Usage

!!! warning "Data source terms of use"
    MRITestData downloads files from external repositories. Each source has its own
    terms of use that you must agree to **before** using the data in your work:

    - **mridata.org** → [http://mridata.org/terms](http://mridata.org/terms)
    - **OCMR** → [https://www.ocmr.info/download/](https://www.ocmr.info/download/)

    Call `MRITestData.dismiss_terms_notice!()` to permanently suppress the startup
    reminder once you have reviewed the terms.

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

## Working with the raw data

`load_raw`, `load_acq` and `acq_spec` accept an ISMRMRD file path **or** a
[`DatasetEntry`](@ref)/[`DatasetHandle`](@ref) directly — the dataset is downloaded
(and cached) on first use:

```julia
raw  = load_raw(entry)       # MRIBase.RawAcquisitionData (profiles + XML header)
acq  = load_acq(entry)       # MRIBase.AcquisitionData
spec = acq_spec(entry)       # source-agnostic NamedTuple (:cartesian/:noncartesian)
```

This works uniformly for every source. OCMR and mridata.org files are already
ISMRMRD; CMRxRecon2024 files are MATLAB k-space and are converted to a cached ISMRMRD
file transparently (see below).

### CMRxRecon2024: k-space, masks, and ISMRMRD

CMRxRecon2024 distributes each acquisition as a MATLAB `.mat` k-space array plus, for
undersampled scans, a **separate mask file**. MRITestData pairs them automatically and
builds a valid ISMRMRD file the first time you load an entry, so CMRxRecon flows through
the same `load_acq`/`acq_spec` pipeline as every other source:

```julia
entry = first(list_datasets(CMRXRECON2024; offline = true))
spec  = acq_spec(entry)              # downloads k-space (+ paired mask), converts, loads
```

- All CMRxRecon data is Cartesian k-space — Uniform/ktUniform/ktGaussian and
  (pseudo-)ktRadial are *sampling masks*, not non-Cartesian trajectories — so it loads
  as `spec.kind == :cartesian` with a `spec.subsampling` mask (`nothing` for FullSample).
  Each phase-encode frame maps to an ISMRMRD contrast, selected via the `echo` keyword.
- ktRadial masks have gaps *within* a readout line; the k-space data preserves them
  exactly (unsampled points are zero), but the line-level `subsampling` mask may read as
  fully sampled. For the exact 2D pattern, load the paired mask with `load_mat`.
- CMRxRecon does not ship a field of view; a placeholder (matrix size in mm) is written.

If you need the raw MATLAB arrays instead of ISMRMRD, `MRITestData.load_mat`
returns the `.mat` contents as a `Dict`:

```julia
d = MRITestData.load_mat(entry)     # e.g. d["kus"] or d["kspace_full"]
```

### Copying a dataset to a custom location

[`copy_dataset`](@ref) ensures the file is available at a destination path of your
choice. If the file is already in the Scratch cache and unmodified, only a local
copy is made — no HTTP request is issued:

```julia
copy_dataset(entry; dest = "/data/my_scan.h5")
```

## Reconstruction with MRIReco

MRITestData provides the data loading pipeline. Reconstruction is left to a
dedicated package such as [MRIReco.jl](https://github.com/MagneticResonanceImaging/MRIReco.jl).
A typical workflow:

```julia
using MRITestData, MRIReco

# 1. Download and load
entry = first(list_datasets(OCMR_SOURCE; fully_sampled = true))
acq   = load_acq(download_dataset(entry))

# 2. Reconstruct using MRIReco directly
params = MRIReco.defaultRecoParams()
params[:reco] = "direct"
img = MRIReco.reconstruction(acq, params)
```

The result is MRIReco's `AxisArray` with axes `[x, y, z, echo, coil, rep]`.

## Persistent settings

Several tunable parameters can be persisted across Julia sessions via
`LocalPreferences.toml`:

```julia
# Terms-of-use notice
MRITestData.dismiss_terms_notice!()   # suppress startup warning (after reviewing terms)
MRITestData.enable_terms_notice!()    # re-enable it

# Parallel download chunks (default: 4; set to 1 to disable)
MRITestData.set_chunk_size!(8)

# Minimum file size for parallel chunking (default: 8 MiB)
MRITestData.set_min_file_size!(4 * 1024 * 1024)

# Dataset-index TTL in days (default: 30)
MRITestData.set_refresh_period!(7)
```
