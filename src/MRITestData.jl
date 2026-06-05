"""
    MRITestData

Query and download free, open-access MRI k-space datasets and load them into
[`MriReconstructionToolbox`](https://github.com/hakkelt/MriReconstructionToolbox)
`AcquisitionInfo` types.

Supported sources (v1): [`MRIDATA`](@ref) (mridata.org) and [`OCMR_SOURCE`](@ref)
(the OCMR cardiac repository). Both serve ISMRMRD `.h5` files, which are read via
`MRIFiles`/`MRIBase` and converted into the toolbox's acquisition containers.

The conversion to `AcquisitionInfo` lives in a package extension that loads only
when `MriReconstructionToolbox` is available, so this package never hard-depends
on the toolbox and the toolbox stays free of file-IO dependencies.

# Quick start
```julia
using MRITestData, MriReconstructionToolbox
entries = list_datasets(OCMR_SOURCE; field_strength = 1.5)
acq = load_dataset(entries[1])          # downloads (cached) then loads
img = reconstruct(acq, (), CGNR(); maxit = 30)
```
"""
module MRITestData

using Scratch: @get_scratch!
using Downloads: Downloads
using SHA: sha256
using TOML: TOML
using DelimitedFiles: readdlm
using NamedDims: NamedDimsArray
using ProgressMeter: ProgressMeter

import MRIFiles
using MRIFiles: ISMRMRDFile
using MRIBase:
    RawAcquisitionData,
    AcquisitionData,
    trajectory,
    kspaceNodes,
    kDataCart,
    isCartesian,
    encodingSize,
    numChannels,
    numSlices,
    numRepetitions

# Lazily-populated cache directory (set in __init__ to the package scratchspace).
const CACHE_DIR = Ref{String}("")

"""
    MRITestData.INDEX_TTL_DAYS

`Ref{Int}` holding how many days a cached dataset index stays fresh before it is
refetched from upstream. Defaults to `30`. Set `MRITestData.INDEX_TTL_DAYS[] = n`
to change the refresh period.
"""
const INDEX_TTL_DAYS = Ref(30)

include("catalog/sources.jl")
include("catalog/catalog.jl")
include("catalog/query.jl")
include("download/cache.jl")
include("download/fetch.jl")
include("catalog/index_cache.jl")
include("catalog/mridata_catalog.jl")
include("catalog/ocmr_catalog.jl")
include("catalog/tui.jl")
include("load/ismrmrd.jl")
include("load/to_acquisition_info.jl")
include("api.jl")

function __init__()
    CACHE_DIR[] = @get_scratch!("datasets")
    return nothing
end

export AbstractSource, MridataOrg, OCMR, MRIDATA, OCMR_SOURCE
export DatasetEntry, DatasetHandle
export list_sources, list_datasets, dataset, query, search_datasets
export download_dataset, cache_path, is_cached, clear_cache
export refresh_index, index_path, index_age_days
export load_raw, load_acq, acq_spec
export load, load_dataset, recon

end # module
