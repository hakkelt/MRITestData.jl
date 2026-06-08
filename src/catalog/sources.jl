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

"""Shared [`MridataOrg`](@ref) source instance."""
const MRIDATA = MridataOrg()

"""Shared [`OCMR`](@ref) source instance."""
const OCMR_SOURCE = OCMR()

"""
    source_name(source) -> String

Short, filesystem-safe name used for the on-disk cache subdirectory.
"""
source_name(::MridataOrg) = "mridata.org"
source_name(::OCMR) = "ocmr"

"""
    list_sources() -> Vector{AbstractSource}

Return all dataset sources supported in this version.
"""
list_sources() = AbstractSource[MRIDATA, OCMR_SOURCE]

"""
    terms_url(source) -> String

URL to the terms of use / data-use policy for `source`.
"""
terms_url(::MridataOrg) = "http://mridata.org/terms"
terms_url(::OCMR) = "https://www.ocmr.info/download/"
