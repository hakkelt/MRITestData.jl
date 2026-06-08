"""
    MRITestData

Query and download free, open-access MRI k-space datasets and load them into
`MRIBase` acquisition containers.

Supported sources (v1): [`MRIDATA`](@ref) (mridata.org) and [`OCMR_SOURCE`](@ref)
(the OCMR cardiac repository). Both serve ISMRMRD `.h5` files, which are read via
`MRIFiles`/`MRIBase`.

Reconstruction via `MRIReco` lives in a package extension that loads only when
`MRIReco` is available, so this package never hard-depends on a reconstruction
package.

# Quick start
```julia
using MRITestData, MRIReco
entries = list_datasets(OCMR_SOURCE; field_strength = 1.5)
img = recon(entries[1]; maxit = 30)     # downloads (cached), loads, reconstructs
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
include("catalog/display.jl")
include("Browse.jl")
include("load/ismrmrd.jl")
include("load/acq_spec.jl")
include("api.jl")

function __init__()
    CACHE_DIR[] = @get_scratch!("datasets")
    return nothing
end

export AbstractSource, MridataOrg, OCMR, MRIDATA, OCMR_SOURCE
export DatasetEntry, DatasetHandle
export list_sources, list_datasets, dataset, query
export download_dataset, cache_path, is_cached, clear_cache
export refresh_index, index_path, index_age_days
export load_raw, load_acq, acq_spec
export recon
export run_browser

end # module
