# API Reference

```@meta
CurrentModule = MRITestData
```

```@docs
MRITestData
```

## Sources

```@docs
AbstractSource
MridataOrg
OCMR
MRIDATA
OCMR_SOURCE
list_sources
```

## Catalog & discovery

```@docs
DatasetEntry
DatasetHandle
list_datasets
query
search_datasets
dataset
```

## Dataset index (self-updating)

```@docs
refresh_index
index_path
index_age_days
INDEX_TTL_DAYS
```

## Download & cache

```@docs
download_dataset
cache_path
is_cached
clear_cache
```

## Loading

```@docs
load_raw
load_acq
acq_spec
load
load_dataset
```

## Reconstruction

```@docs
recon
```

!!! note
    `load` and `load_dataset` require `MriReconstructionToolbox` to be loaded, and
    `recon` requires `MRIReco` to be loaded — they are implemented in package
    extensions.
