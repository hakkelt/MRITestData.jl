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

## Loading

```@docs
load_raw
load_acq
acq_spec
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
```
