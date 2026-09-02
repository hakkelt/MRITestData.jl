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
USCSpeech
M4Raw
FastMRI
MRIDATA
OCMR_SOURCE
CMRXRECON2024
CMRXRECON300
USC_SPEECH
M4RAW
FASTMRI
list_sources
terms_url
terms_notice
```

## Catalog & discovery

```@docs
DatasetEntry
DatasetHandle
list_datasets
query
dataset
```

## Taxonomy API

Field names, value vocabularies and units are anchored in the DICOM standard where a term
exists; see [Taxonomy](@ref) for the full mapping, the seven extensions, and the external
references consulted.

```@docs
dicom_tag
dicom_keyword
DICOM_ATTRIBUTES
TAXONOMY_EXTENSIONS
extra_schema
CONTRASTS
TRAJECTORIES
ANATOMIES
CARDIAC_SYNC
FAT_SUPPRESSION
ECHO_TYPES
COIL_DATA
SPLITS
COHORTS
UNDERSAMPLING_PATTERNS
ORIENTATIONS
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
set_download_path!
get_download_path
unset_download_path!
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

### fastMRI credentials

fastMRI access is form-gated; the confirmation email carries 90-day pre-signed S3 URLs.
Register them once with [`set_fastmri_urls!`](@ref) — see
[fastMRI: form-gated credentials](@ref).

```@docs
set_fastmri_urls!
get_fastmri_url
fastmri_url_expires
```

The parallel-download tuning Refs read by the settings above:

```@docs
MRITestData.PARALLEL_CHUNKS
MRITestData.PARALLEL_MIN_BYTES
```
