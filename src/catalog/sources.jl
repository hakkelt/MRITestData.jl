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

"""
    CMRxRecon300 <: AbstractSource

The CMRxRecon-300 dataset (revised CMRxRecon-2023 challenge dataset): raw cardiac k-space
from 300 healthy volunteers (cine + T1/T2 mapping). The `_ks` files are **undersampled**
(regular k-t pattern, R≈3) with separate fully-sampled ACS `_calib` files; hosted on
Synapse (`syn52965326`) as
`.tar.gz` archives split into raw 16 GiB byte fragments. A `.tar.gz` cannot be
range-extracted per member, so individual `.mat` files are recovered with a pre-built
zran checkpoint index (see `scripts/index_cmrxrecon300.jl`) plus HTTP range requests.
Access requires a free Synapse account / Personal Access Token (see
[`set_synapse_token!`](@ref)); the data is CC-BY (no challenge registration). The shared
instance is [`CMRXRECON300`](@ref).
"""
struct CMRxRecon300 <: AbstractSource end

"""
    USCSpeech <: AbstractSource

The USC SPAN 75-speaker speech-production real-time MRI dataset (figshare
`13725546`, CC BY 4.0). Provides 2D sagittal-view **raw spiral k-space** of the
vocal tract acquired on a GE Signa Excite 1.5 T scanner (13-interleaf spiral-out
GRE, custom 8-channel upper-airway array) in vendor-agnostic MRD/ISMRMRD `.h5`.
The whole corpus is a single ~570 GB `dataset.zip`; individual `.h5` files are
extracted over the network with HTTP byte-range requests against a pre-computed
offset map (see `data/usc_speech_map.csv`). The data is public CC-BY — no account
or token is required. The shared instance is [`USC_SPEECH`](@ref).
"""
struct USCSpeech <: AbstractSource end

"""
    M4Raw <: AbstractSource

The M4Raw low-field brain MRI dataset (Zenodo record `8056074`, CC BY 4.0). Provides
multi-contrast (T1w/T2w/FLAIR + T1 GRE), multi-repetition, multi-slice raw **Cartesian
k-space** acquired on a 0.3 T whole-body scanner with a 4-channel head coil. Each `.h5`
member follows the fastMRI layout (`kspace`, `reconstruction_rss`, `ismrmrd_header`) and
is converted to a cached ISMRMRD file on first load. The corpus ships as several multi-GB
Zenodo ZIPs; individual `.h5` files are extracted over the network with HTTP byte-range
requests against a pre-computed offset map (see `data/m4raw_map.csv`). The data is public
CC-BY — no account or token is required. The shared instance is [`M4RAW`](@ref).
"""
struct M4Raw <: AbstractSource end

"""
    FastMRI <: AbstractSource

The fastMRI dataset (NYU / Facebook AI Research): knee, brain, prostate, and breast
MRI k-space acquired on clinical Siemens/GE scanners and stored in the fastMRI HDF5
layout (`kspace`, `reconstruction_rss`, `ismrmrd_header`). Knee and brain are hosted as
`.tar.xz` archives on AWS S3; prostate and breast as `.tar.gz`.

**Access is gated**: fill the request form at [https://fastmri.med.nyu.edu](https://fastmri.med.nyu.edu);
the confirmation email contains time-limited (90-day) AWS pre-signed download URLs. Provide
them to this package via [`set_fastmri_urls!`](@ref).

The catalog is a static offset map committed under `data/fastmri_map.csv`, built by the
maintainer scripts `scripts/index_fastmri.jl` (`.tar.xz`) and `scripts/index_fastmri_gz.jl`
(`.tar.gz`). Individual `.h5` members are range-extracted from the `.tar.xz` archives via
xz-block-level HTTP range requests (one block per member), and from the `.tar.gz` archives
via zran checkpoints (`data/fastmri_zran/`) seeded into a raw-inflate decoder. Like
[`M4Raw`](@ref), the extracted files are in fastMRI layout and are converted to cached
Cartesian ISMRMRD on first load. The shared instance is [`FASTMRI`](@ref).
"""
struct FastMRI <: AbstractSource end

# ── Shared source instances ───────────────────────────────────────────────────────
# One singleton per source type above; keep new sources appended to both this block and
# `list_sources` below.

"""Shared [`MridataOrg`](@ref) source instance."""
const MRIDATA = MridataOrg()

"""Shared [`OCMR`](@ref) source instance."""
const OCMR_SOURCE = OCMR()

"""Shared [`CMRxRecon2024`](@ref) source instance."""
const CMRXRECON2024 = CMRxRecon2024()

"""Shared [`CMRxRecon300`](@ref) source instance."""
const CMRXRECON300 = CMRxRecon300()

"""Shared [`USCSpeech`](@ref) source instance."""
const USC_SPEECH = USCSpeech()

"""Shared [`M4Raw`](@ref) source instance."""
const M4RAW = M4Raw()

"""Shared [`FastMRI`](@ref) source instance."""
const FASTMRI = FastMRI()

"""
    source_name(source) -> String

Short, filesystem-safe name used for the on-disk cache subdirectory.
"""
source_name(::MridataOrg) = "mridata.org"
source_name(::OCMR) = "ocmr"
source_name(::CMRxRecon2024) = "cmrxrecon2024"
source_name(::CMRxRecon300) = "cmrxrecon300"
source_name(::USCSpeech) = "usc_speech"
source_name(::M4Raw) = "m4raw"
source_name(::FastMRI) = "fastmri"

"""
    list_sources() -> Vector{AbstractSource}

Return all dataset sources supported in this version.
"""
list_sources() = AbstractSource[MRIDATA, OCMR_SOURCE, CMRXRECON2024, CMRXRECON300, USC_SPEECH, M4RAW, FASTMRI]

"""
    terms_url(source) -> String

URL to the terms of use / data-use policy for `source`.
"""
terms_url(::MridataOrg) = "http://mridata.org/terms"
terms_url(::OCMR) = "https://www.ocmr.info/download/"
terms_url(::CMRxRecon2024) = "https://cmrxrecon.github.io/2024/FAQ.html"
terms_url(::CMRxRecon300) = "https://www.synapse.org/Synapse:syn52965326"
terms_url(::USCSpeech) = "https://creativecommons.org/licenses/by/4.0/"
terms_url(::M4Raw) = "https://creativecommons.org/licenses/by/4.0/"
terms_url(::FastMRI) = "https://fastmri.med.nyu.edu"

"""
    terms_notice() -> String

The data-source terms-of-use notice, one `source_name` → [`terms_url`](@ref) line per
entry of [`list_sources`](@ref). Generated rather than written out, so a new source cannot
be added to the package while staying invisible in the startup warning.
"""
function terms_notice()
    width = maximum(length ∘ source_name, list_sources())
    return join(("  • $(rpad(source_name(s), width))  →  $(terms_url(s))" for s in list_sources()), "\n")
end
