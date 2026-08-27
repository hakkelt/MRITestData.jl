"""
    MRITestData

Query and download free, open-access MRI k-space datasets and load them into
`MRIBase.RawAcquisitionData`.

Supported sources: [`MRIDATA`](@ref) (mridata.org), [`OCMR_SOURCE`](@ref) (the OCMR
cardiac repository), [`CMRXRECON2024`](@ref) (the CMRxRecon2024 challenge data),
[`CMRXRECON300`](@ref) (the CMRxRecon-300 undersampled cardiac dataset),
[`USC_SPEECH`](@ref) (the USC SPAN 75-speaker spiral speech rtMRI dataset),
[`M4RAW`](@ref) (the M4Raw 0.3 T low-field brain dataset), and [`FASTMRI`](@ref)
(the NYU fastMRI knee/brain/prostate/breast k-space dataset). mridata.org, OCMR and
USC Speech serve ISMRMRD `.h5` files (USC Speech range-extracted from a figshare ZIP);
the CMRxRecon sources ship MATLAB `.mat` k-space; M4Raw and fastMRI ship fastMRI-layout
`.h5` files (M4Raw range-extracted from Zenodo ZIPs; fastMRI range-extracted from `.tar.xz`
archives via xz block-level HTTP range requests for knee/brain, and from `.tar.gz` archives
via zran checkpoints for prostate/breast), all converted to a cached ISMRMRD file on first
load. All are read via `MRIFiles`/`MRIBase`.

fastMRI access is gated: fill the form at [https://fastmri.med.nyu.edu](https://fastmri.med.nyu.edu);
the confirmation email contains 90-day pre-signed AWS S3 URLs for all archives. Pass the
email body to [`set_fastmri_urls!`](@ref) once; credentials are persisted across sessions
until they expire.

!!! warning "Data source terms of use"
    This package's MIT license covers **its code only**. Downloaded data is governed
    by each provider's own license and terms. Please review them before using the data:
    - mridata.org: http://mridata.org/terms
    - OCMR: https://www.ocmr.info/download/
    - CMRxRecon2024: https://cmrxrecon.github.io/2024/FAQ.html
    - CMRxRecon-300: https://www.synapse.org/Synapse:syn52965326
    - USC Speech: https://creativecommons.org/licenses/by/4.0/
    - M4Raw: https://creativecommons.org/licenses/by/4.0/
    - fastMRI: https://fastmri.med.nyu.edu (form-gated; see fastMRI Dataset Agreement)

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
using Dates: Dates
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

include("util/zran.jl")
using .Zran: Zran
include("util/tario.jl")
using .TarIO: TarIO
include("util/xz.jl")
using .XzIO: XzIO
include("catalog/sources.jl")
include("catalog/catalog.jl")
include("catalog/query.jl")
include("catalog/index_cache.jl")
include("download/cache.jl")
include("download/fetch.jl")
include("catalog/mridata_catalog.jl")
include("catalog/ocmr_catalog.jl")
include("catalog/cmrxrecon2024_catalog.jl")
include("catalog/cmrxrecon300_catalog.jl")
include("catalog/usc_speech_catalog.jl")
include("catalog/m4raw_catalog.jl")
include("catalog/fastmri_catalog.jl")
include("download/cmrxrecon2024_fetch.jl")
include("download/cmrxrecon300_fetch.jl")
include("download/usc_speech_fetch.jl")
include("download/m4raw_fetch.jl")
include("download/fastmri_fetch.jl")
include("catalog/display.jl")
include("browse.jl")
include("load/ismrmrd.jl")
include("load/mat.jl")
include("load/cmrxrecon_ismrmrd.jl")
include("load/m4raw_ismrmrd.jl")
include("load/fastmri_ismrmrd.jl")
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
          • CMRxRecon-300  →  https://www.synapse.org/Synapse:syn52965326
          • USC Speech     →  https://creativecommons.org/licenses/by/4.0/
          • M4Raw          →  https://creativecommons.org/licenses/by/4.0/
          • fastMRI        →  https://fastmri.med.nyu.edu
        To permanently suppress this notice, call:
          MRITestData.dismiss_terms_notice!()
        """
    end
    return nothing
end

export AbstractSource, MridataOrg, OCMR, CMRxRecon2024, CMRxRecon300, USCSpeech, M4Raw, FastMRI
export MRIDATA, OCMR_SOURCE, CMRXRECON2024, CMRXRECON300, USC_SPEECH, M4RAW, FASTMRI
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
export set_fastmri_urls!, get_fastmri_url, fastmri_url_expires

end # module
