"""
    AbstractSource

Base type for a free MRI dataset repository. Concrete sources are singletons
([`MRIDATA`](@ref), [`OCMR_SOURCE`](@ref)) that know how to enumerate their
catalog ([`list_datasets`](@ref)) and build download URLs.
"""
abstract type AbstractSource end

"""
    MridataOrg <: AbstractSource

The mridata.org repository. Datasets are identified by a UUID and downloaded as
ISMRMRD `.h5` from `https://mridata.org/download/{uuid}`. The shared instance is
[`MRIDATA`](@ref).
"""
struct MridataOrg <: AbstractSource end

"""
    OCMR <: AbstractSource

The Open-access repository for Multi-coil k-space data (cardiac CMR). Files are
ISMRMRD `.h5` served from an S3 bucket. The shared instance is
[`OCMR_SOURCE`](@ref).
"""
struct OCMR <: AbstractSource end

"""
    CMRxRecon2024 <: AbstractSource

The CMRxRecon2024 cardiac MRI challenge dataset, hosted on Synapse as a single
~835 GB archive (`ChallengeData.zip`) split into 210 raw 4 GB byte fragments. Rather
than downloading the whole archive, individual k-space `.mat` files are extracted
over the network with HTTP byte-range requests against a pre-computed offset map
(see `data/cmrxrecon2024_map.csv`). Access requires a Synapse Personal Access Token
(see [`set_synapse_token!`](@ref)). The shared instance is [`CMRXRECON2024`](@ref).
"""
struct CMRxRecon2024 <: AbstractSource end

"""Shared [`MridataOrg`](@ref) source instance."""
const MRIDATA = MridataOrg()

"""Shared [`OCMR`](@ref) source instance."""
const OCMR_SOURCE = OCMR()

"""Shared [`CMRxRecon2024`](@ref) source instance."""
const CMRXRECON2024 = CMRxRecon2024()

"""
    source_name(source) -> String

Short, filesystem-safe name used for the on-disk cache subdirectory.
"""
source_name(::MridataOrg) = "mridata.org"
source_name(::OCMR) = "ocmr"
source_name(::CMRxRecon2024) = "cmrxrecon2024"

"""
    list_sources() -> Vector{AbstractSource}

Return all dataset sources supported in this version.
"""
list_sources() = AbstractSource[MRIDATA, OCMR_SOURCE, CMRXRECON2024]

"""
    terms_url(source) -> String

URL to the terms of use / data-use policy for `source`.
"""
terms_url(::MridataOrg) = "http://mridata.org/terms"
terms_url(::OCMR) = "https://www.ocmr.info/download/"
terms_url(::CMRxRecon2024) = "https://cmrxrecon.github.io/2024/FAQ.html"
