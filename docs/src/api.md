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
CMRxRecon2024
CMRxRecon300
MRIDATA
OCMR_SOURCE
CMRXRECON2024
CMRXRECON300
list_sources
```

## Catalog & discovery

```@docs
DatasetEntry
DatasetHandle
list_datasets
query
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
copy_dataset
cache_path
is_cached
clear_cache
```

## Dataset sizes

```@docs
fetch_sizes
sizes_path
read_sizes
write_sizes
```

## Loading

```@docs
load_raw
```

`MRITestData.load_mat` is not exported but is available for direct access to the raw
MATLAB k-space arrays of CMRxRecon2024 files; see [`load_mat`](@ref MRITestData.load_mat).

```@docs
MRITestData.load_mat
```

## Interactive browser

```@docs
run_browser
```

## Persistent settings

```@docs
dismiss_terms_notice!
enable_terms_notice!
set_chunk_size!
get_chunk_size
set_min_file_size!
get_min_file_size
set_refresh_period!
get_refresh_period
set_synapse_token!
get_synapse_token
```

The parallel-download tuning Refs read by the settings above:

```@docs
MRITestData.PARALLEL_CHUNKS
MRITestData.PARALLEL_MIN_BYTES
```
