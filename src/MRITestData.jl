"""
    MRITestData

Query and download free, open-access MRI k-space datasets and load them into
`MRIBase.RawAcquisitionData`.

Supported sources: [`MRIDATA`](@ref) (mridata.org), [`OCMR_SOURCE`](@ref) (the OCMR
cardiac repository), and [`CMRXRECON2024`](@ref) (the CMRxRecon2024 challenge data).
mridata.org and OCMR serve ISMRMRD `.h5` files; CMRxRecon2024 ships MATLAB `.mat`
k-space that is converted to a cached ISMRMRD file on first load. All are read via
`MRIFiles`/`MRIBase`.

!!! warning "Data source terms of use"
    This package's MIT license covers **its code only**. Downloaded data is governed
    by each provider's own license and terms. Please review them before using the data:
    - mridata.org: http://mridata.org/terms
    - OCMR: https://www.ocmr.info/download/
    - CMRxRecon2024: https://cmrxrecon.github.io/2024/FAQ.html

    Call `MRITestData.dismiss_terms_notice!()` to permanently suppress the startup
    notice once you have reviewed the terms.

# Quick start
```julia
using MRITestData
entries = list_datasets(OCMR_SOURCE; field_strength = 1.5)
path = download_dataset(entries[1])     # downloads (cached), returns path
raw  = load_raw(path)                   # MRIBase.RawAcquisitionData
```
"""
module MRITestData

using Scratch: @get_scratch!
using Downloads: Downloads
using SHA: sha256
using TOML: TOML
using DelimitedFiles: readdlm
using ProgressMeter: ProgressMeter
using Preferences: load_preference, set_preferences!
using PrecompileTools: @compile_workload

import MRIFiles
import MAT
import CodecZlib
using MRIFiles: ISMRMRDFile
using FileIO: save
using MRIBase:
    RawAcquisitionData,
    Profile,
    AcquisitionHeader,
    EncodingCounters

# Lazily-populated cache directory (set in __init__ to the package scratchspace).
const CACHE_DIR = Ref{String}("")

"""
    MRITestData.INDEX_TTL_DAYS

`Ref{Int}` holding how many days a cached dataset index stays fresh before it is
refetched from upstream. Defaults to `30`. Set `MRITestData.INDEX_TTL_DAYS[] = n`
to change the refresh period. Use [`MRITestData.set_refresh_period!`](@ref) to
persist the value across sessions.
"""
const INDEX_TTL_DAYS = Ref(30)

include("catalog/sources.jl")
include("catalog/catalog.jl")
include("catalog/query.jl")
include("catalog/index_cache.jl")
include("download/cache.jl")
include("download/fetch.jl")
include("catalog/mridata_catalog.jl")
include("catalog/ocmr_catalog.jl")
include("catalog/cmrxrecon2024_catalog.jl")
include("download/cmrxrecon2024_fetch.jl")
include("catalog/display.jl")
include("browse.jl")
include("load/ismrmrd.jl")
include("load/mat.jl")
include("load/cmrxrecon_ismrmrd.jl")
include("api.jl")
include("settings.jl")
include("precompile.jl")

function __init__()
    CACHE_DIR[] = @get_scratch!("datasets")
    # Apply persisted preferences to the runtime Refs.
    INDEX_TTL_DAYS[] = get_refresh_period()
    PARALLEL_CHUNKS[] = get_chunk_size()
    PARALLEL_MIN_BYTES[] = get_min_file_size()
    if !_terms_accepted()
        @warn """
        MRITestData downloads data from external sources that have their own terms of use.
        Please review the terms before using downloaded data:
          • mridata.org    →  http://mridata.org/terms
          • OCMR           →  https://www.ocmr.info/download/
          • CMRxRecon2024  →  https://cmrxrecon.github.io/2024/FAQ.html
        To permanently suppress this notice, call:
          MRITestData.dismiss_terms_notice!()
        """
    end
    return nothing
end

export AbstractSource, MridataOrg, OCMR, CMRxRecon2024, MRIDATA, OCMR_SOURCE, CMRXRECON2024
export DatasetEntry, DatasetHandle
export list_sources, list_datasets, dataset, query
export download_dataset, copy_dataset, cache_path, is_cached, clear_cache
export fetch_sizes
export refresh_index, index_path, index_age_days, sizes_path, read_sizes, write_sizes
export load_raw
export run_browser
export dismiss_terms_notice!, enable_terms_notice!
export set_chunk_size!, get_chunk_size
export set_min_file_size!, get_min_file_size
export set_refresh_period!, get_refresh_period
export set_synapse_token!, get_synapse_token

end # module
