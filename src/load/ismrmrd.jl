# Thin wrappers over the MRIFiles ISMRMRD readers. The heavy lifting
# (HDF5 + XML parsing, profile placement, trajectory assembly) lives in those
# packages; we only re-export it under convenient names.

# MRIFiles.GeneralParameters parses `<waveformName>` as Float64 (bug: it's a
# String in cardiac OCMR files, e.g. "ECG"). Strip waveformInformation blocks
# from the cached HDF5 file before MRIFiles reads it — done in-place once so
# subsequent loads are free.
function _patch_ismrmrd_if_needed!(path::AbstractString)
    HDF5 = MRIFiles.HDF5
    # `h[name]` is typed `Union{Dataset,Datatype,Group}`; `/dataset/xml` is always a
    # Dataset. Assert it so `read` resolves to `read(::Dataset)` (also keeps JET happy).
    xml = HDF5.h5open(path) do h
        read(h["/dataset/xml"]::HDF5.Dataset)[1]::String
    end
    occursin("<waveformInformation>", xml) || return nothing
    patched = replace(xml, r"<waveformInformation>.*?</waveformInformation>"s => "")
    HDF5.h5open(path, "r+") do h
        HDF5.delete_object(h, "/dataset/xml")
        h["/dataset/xml"] = [patched]
    end
    return nothing
end

# Plausible receiver dwell times, in microseconds: 0.1 µs is a 10 MHz receiver, 1 ms a 1 kHz
# one. A value derived from the header outside this range means the header was misread, not
# repaired, so it is discarded rather than written into the profiles.
const _DWELL_TIME_US_RANGE = (0.1, 1000.0)

# `trajectoryDescription` keys carrying the readout duration and the sampling interval, in
# the spellings this catalog has to read. `simplingTime_ns` is the USC Speech exporter's own
# spelling of "sampling time"; the `_ns` suffixes are wrong (see `_fix_zero_sample_time!`).
const _READ_TIME_KEYS = ("readTime_ns", "readTime_us", "readTime")
const _SAMPLING_TIME_KEYS = ("simplingTime_ns", "samplingTime_ns", "samplingTime_us", "samplingTime")

function _first_positive(d::AbstractDict, keys)
    for k in keys
        v = get(d, k, nothing)
        if v isa Real && v > 0
            return Float64(v)
        end
    end
    return nothing
end

# Dwell time in microseconds implied by the sequence's `trajectoryDescription`, or `nothing`
# when the description does not pin it down. The readout duration over the sample count is
# preferred: it is the definition of the dwell time, and it is consistent with the sampling
# interval the same block states.
function _header_dwell_time_us(params::AbstractDict, nsamples::Integer)
    desc = get(params, "trajectoryDescription", nothing)
    desc isa AbstractDict || return nothing
    read_time = _first_positive(desc, _READ_TIME_KEYS)
    sampling_time = _first_positive(desc, _SAMPLING_TIME_KEYS)
    dwell = (read_time === nothing || nsamples < 1) ? sampling_time : read_time / nsamples
    dwell === nothing && return nothing
    if read_time !== nothing && sampling_time !== nothing && !isapprox(dwell, sampling_time; rtol = 0.1)
        @warn "ISMRMRD trajectoryDescription is inconsistent: the readout duration over the " *
            "sample count gives a dwell time of $(dwell) µs, the stated sampling interval is " *
            "$(sampling_time) µs. Using the readout duration." maxlog = 1
    end
    lo, hi = _DWELL_TIME_US_RANGE
    return lo <= dwell <= hi ? Float32(dwell) : nothing
end

# Some exporters leave the acquisition headers' dwell time at zero. `MRIBase.trajectory`
# builds each profile's sample times as `0:dt:(nsamples - 1) * dt` with
# `dt = sample_time_us * 1e-6`, so a zero dwell time makes anything that asks for the
# trajectory fail with `ArgumentError: range step cannot be zero` — `AcquisitionData(raw)`,
# or MriReconstructionToolbox's `AcquisitionInfo(raw)`.
#
# The USC Speech spiral files (GE/HeartVista exporter) are that case here: every profile has
# `sample_time_us = 0`, yet the sequence's `trajectoryDescription` does record the timing —
# `readTime_ns = 2520` and `simplingTime_ns = 4` for a 630-sample spiral readout. Both are
# microseconds in spite of the `_ns` suffix: the same block gives
# `repetitionTime_ns = 6004` where `<sequenceParameters><TR>` is 6.004 ms, and 630 samples in
# 2.52 µs would be a 250 MHz receiver. So the dwell time is 2520/630 = 4 µs, which the stated
# sampling interval confirms.
function _fix_zero_sample_time!(raw::RawAcquisitionData)
    any(p -> iszero(p.head.sample_time_us), raw.profiles) || return raw
    repaired = false
    for p in raw.profiles
        iszero(p.head.sample_time_us) || continue
        nsamples = max(Int(p.head.number_of_samples), size(p.data, 1))
        dwell = _header_dwell_time_us(raw.params, nsamples)
        dwell === nothing && break
        p.head.sample_time_us = dwell
        repaired = true
    end
    # Only non-Cartesian data is affected: the Cartesian branch of `MRIBase.trajectory` never
    # looks at the sample times, so a zero dwell time there is harmless and common.
    if !repaired && lowercase(get(raw.params, "trajectory", "cartesian")) != "cartesian"
        @warn "This ISMRMRD file records no dwell time (`sample_time_us = 0` in every " *
            "profile) and its header does not imply one, so the sample times stay zero. " *
            "Building an `AcquisitionData` from it will fail with \"range step cannot be " *
            "zero\"; set `profile.head.sample_time_us` yourself to work around it." maxlog = 1
    end
    return raw
end

# Resolve a dataset entry to a local ISMRMRD `.h5` path. OCMR/mridata.org cache files
# are already ISMRMRD, so the default is just the downloaded file; CMRxRecon2024 entries
# are MATLAB k-space (+ a separate mask) and are converted to ISMRMRD on first use.
_ismrmrd_path(::AbstractSource, e::DatasetEntry) = download_dataset(e)
_ismrmrd_path(::CMRxRecon2024, e::DatasetEntry) = _cmrxrecon_ismrmrd_path(e)
# CMRxRecon-300 ships *undersampled* raw k-space (`Recon_ks`, zero-filled to the full
# matrix); derive the true acquired-line mask from the data so the cached ISMRMRD records
# the real sampling rather than claiming it is fully sampled.
_ismrmrd_path(::CMRxRecon300, e::DatasetEntry) = _cmrxrecon_ismrmrd_path(e; derive_mask = true)
# M4Raw members are fastMRI-layout `.h5` (kspace/reconstruction_rss/ismrmrd_header), not
# complete ISMRMRD files; convert the fully-sampled Cartesian k-space on first use.
_ismrmrd_path(::M4Raw, e::DatasetEntry) = _m4raw_ismrmrd_path(e)
# fastMRI members share the same format as M4Raw; same conversion, different field strength.
_ismrmrd_path(::FastMRI, e::DatasetEntry) = _fastmri_ismrmrd_path(e)

"""
    load_raw(path; slice=nothing, repetition=nothing, contrast=nothing) -> RawAcquisitionData
    load_raw(entry_or_handle; kwargs...) -> RawAcquisitionData

Read an ISMRMRD `.h5` file at `path` into a `MRIFiles.RawAcquisitionData` (raw
profiles plus the parsed XML header in `.params`). Optional `slice`, `repetition`
and `contrast` filter which profiles are loaded.

Given a [`DatasetEntry`](@ref) or [`DatasetHandle`](@ref), the dataset is downloaded
(and cached) first; CMRxRecon2024 entries are converted from their MATLAB k-space
(plus the paired undersampling mask) into a cached ISMRMRD file transparently.

Two exporter defects are repaired on the way through: cardiac OCMR files' ECG
`<waveformInformation>` blocks are stripped from the cached HDF5 (MRIFiles misparses
them), and profiles left with `sample_time_us = 0` — every profile of a USC Speech
spiral file — get the dwell time implied by the sequence's `trajectoryDescription`,
without which building a non-Cartesian trajectory throws
`ArgumentError: range step cannot be zero`.

To reconstruct, build an `AcquisitionData` from the result and hand it to a
reconstruction package such as MRIReco.jl — see the "Reconstruction with MRIReco"
section of the documentation.
"""
function load_raw(path::AbstractString; slice = nothing, repetition = nothing, contrast = nothing)
    _patch_ismrmrd_if_needed!(path)
    raw = RawAcquisitionData(ISMRMRDFile(path); slice = slice, repetition = repetition, contrast = contrast)
    return _fix_zero_sample_time!(raw)
end

load_raw(e::DatasetEntry; kwargs...) = load_raw(_ismrmrd_path(e.source, e); kwargs...)
load_raw(h::DatasetHandle; kwargs...) = load_raw(h.entry; kwargs...)
