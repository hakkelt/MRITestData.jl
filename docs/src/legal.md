# Licensing & legal

!!! warning "The package license does not license the data"
    MRITestData.jl is released under the MIT license, which covers **the package's
    source code only**. It does **not** grant you any rights to the MRI datasets you
    download through it. Each dataset remains the property of its provider and is
    governed by that provider's own license and terms of use.

!!! note "Review data source terms before use"
    Please visit each provider's terms page **before** downloading or using data:

    - **mridata.org** → [http://mridata.org/terms](http://mridata.org/terms)
    - **OCMR** → [https://www.ocmr.info/download/](https://www.ocmr.info/download/)
    - **CMRxRecon2024** → [https://cmrxrecon.github.io/2024/FAQ.html](https://cmrxrecon.github.io/2024/FAQ.html)
    - **CMRxRecon-300** → [https://www.synapse.org/Synapse:syn52965326](https://www.synapse.org/Synapse:syn52965326)
    - **USC Speech** → [https://creativecommons.org/licenses/by/4.0/](https://creativecommons.org/licenses/by/4.0/)
    - **M4Raw** → [https://creativecommons.org/licenses/by/4.0/](https://creativecommons.org/licenses/by/4.0/)
    - **fastMRI** → [https://fastmri.med.nyu.edu](https://fastmri.med.nyu.edu) (fastMRI Dataset Agreement)

This package is a convenience tool for *accessing* publicly available data. It does
not host, relicense, or redistribute any dataset. When you use it to download data,
you are downloading directly from the provider, and you are responsible for
reviewing and complying with that provider's terms **before** using, redistributing,
or publishing results derived from the data.

## mridata.org

Datasets on [mridata.org](https://mridata.org) are contributed by many groups and
**each dataset may carry its own license and citation/attribution requirements**.
Check the dataset's page on mridata.org for its specific terms and the publication
it should be attributed to. Do not assume a uniform license across datasets.

## OCMR

The [OCMR](https://ocmr.info) cardiac k-space repository is distributed under its own
data-use terms. In particular, use of OCMR data **requires citing the OCMR
publication**:

> Chen C, Liu Y, Schniter P, Tong M, Zareba K, Simonetti O, Potter L, Ahmad R.
> *OCMR (v1.0)—Open-Access Multi-Coil k-Space Dataset for Cardiovascular Magnetic
> Resonance Imaging.* arXiv:2008.03410, 2020.

Review the terms on the OCMR website and in the dataset repository, and comply with
any restrictions on redistribution and use.

## CMRxRecon2024

The [CMRxRecon2024](https://cmrxrecon.github.io/2024/) challenge dataset is hosted on
[Synapse](https://www.synapse.org). Access is gated:

1. Register for a free Synapse account.
2. **Apply to join the challenge** and complete the external team-information form —
   this is mandatory. Until the challenge registration is finalized, a generated
   Personal Access Token (PAT) will **not** have permission to download the data.
3. Create a Synapse PAT with *view* and *download* scopes and provide it to this
   package via [`set_synapse_token!`](@ref) (or the `SYNAPSE_AUTH_TOKEN` environment
   variable).

See the [Task 2 page](https://cmrxrecon.github.io/2024/Task2.html) for technical
context on the random-sampling CMR reconstruction task, and the
[FAQ](https://cmrxrecon.github.io/2024/FAQ.html) for terms and citation requirements.
Cite the CMRxRecon publications as required by the organizers.

## CMRxRecon-300

The [CMRxRecon-300](https://www.synapse.org/Synapse:syn52965326) dataset (the
revised CMRxRecon-2023 dataset) is hosted on
[Synapse](https://www.synapse.org) under the **CC-BY** license. Unlike the 2024
challenge data, access is **not** gated by a challenge application — a free Synapse
account suffices:

1. Register for a free Synapse account.
2. Create a Synapse PAT with *view* and *download* scopes and provide it to this package
   via [`set_synapse_token!`](@ref) (or the `SYNAPSE_AUTH_TOKEN` environment variable).

CC-BY permits redistribution and reuse **with attribution**: cite the CMRxRecon
*Scientific Data* paper (Wang C, Lyu J, Wang S, et al. *CMRxRecon: A publicly available
k-space dataset and benchmark to advance deep learning for cardiac MRI.* Scientific Data,
2024, 11(1): 687) when you use the data.

## USC Speech (SPAN 75-speaker)

The [USC SPAN 75-speaker](https://sail.usc.edu/span/75speakers/) real-time speech
production MRI dataset is hosted on figshare
([13725546](https://doi.org/10.6084/m9.figshare.13725546)) under the
[**Creative Commons Attribution 4.0 (CC BY 4.0)**](https://creativecommons.org/licenses/by/4.0/)
license. No account or registration is required to download it.

CC BY 4.0 permits redistribution and reuse — including commercially — **provided you give
appropriate credit**. Cite the *Scientific Data* data descriptor when you use the data:

> Lim Y, Toutios A, Bliesener Y, et al. *A multispeaker dataset of raw and reconstructed
> speech production real-time MRI video and 3D volumetric images.* Scientific Data, 2021,
> 8(1): 187.

and acknowledge the figshare dataset DOI
([10.6084/m9.figshare.13725546](https://doi.org/10.6084/m9.figshare.13725546)).

## M4Raw

The [M4Raw](https://github.com/mylyu/M4Raw) low-field brain MRI dataset is hosted on
Zenodo ([record 8056074](https://doi.org/10.5281/zenodo.8056074)) under the
[**Creative Commons Attribution 4.0 (CC BY 4.0)**](https://creativecommons.org/licenses/by/4.0/)
license. No account or registration is required to download it.

CC BY 4.0 permits redistribution and reuse — including commercially — **provided you give
appropriate credit**. Cite the *Scientific Data* data descriptor when you use the data:

> Lyu M, Mei L, Huang S, et al. *M4Raw: A multi-contrast, multi-repetition, multi-channel
> MRI k-space dataset for low-field MRI research.* Scientific Data, 2023, 10(1): 264.

and acknowledge the Zenodo record DOI
([10.5281/zenodo.8056074](https://doi.org/10.5281/zenodo.8056074)).

## fastMRI

The [fastMRI](https://fastmri.med.nyu.edu) dataset is a collaborative research project
from NYU and Facebook AI Research (FAIR), providing knee, brain, prostate, and breast
MRI k-space data. Access requires completing the **fastMRI Dataset Agreement** form at
[fastmri.med.nyu.edu](https://fastmri.med.nyu.edu) — submission is required before any
download. The confirmation email contains time-limited (90-day) pre-signed AWS S3 URLs
for the dataset archives.

Key obligations:

- You must complete the Dataset Agreement form for **each** dataset (knee, brain,
  prostate, breast) you wish to use. Approval is typically automatic but requires an
  institutional affiliation.
- Re-request download links after 90 days. Supply new links to MRITestData with
  [`set_fastmri_urls!`](@ref).
- Cite the relevant fastMRI publications for the anatomy or task you use:

  - **fastMRI benchmark dataset (knee + brain)**:
    > Zbontar J, Knoll F, Sriram A, et al. *fastMRI: An Open Dataset and Benchmarks for
    > Accelerated MRI.* arXiv:1811.08839, 2018.

  - **fastMRI+ annotations (knee)**:
    > Zhao R, Yaman B, Zhang Y, et al. *fastMRI+: Clinical Pathology Annotations for
    > Knee and Brain Fully Sampled Multi-Coil MRI Data.* Scientific Data, 2022, 9: 717.

  - **fastMRI prostate**:
    > Tibrewala R, Tamir JI, Sriram A, et al. *fastMRI Prostate: A Publicly Available,
    > Multimodal Dataset for Prostate MRI.* arXiv:2304.09254, 2023.

  - **fastMRI breast**:
    > Steinhardt J, Fabian MS, Liu S, et al. *The fastMRI Breast Dataset.* ISMRM, 2024.
    > (Check fastmri.med.nyu.edu for the current citation.)

Compliance with the Dataset Agreement is your responsibility. The MRITestData.jl
maintainers cannot grant rights to the fastMRI data.

## Your responsibilities

- Verify the license/terms of **each** dataset you download.
- Provide the **attribution/citation** each provider requires in any publication or
  derived work.
- Comply with restrictions on **redistribution** — do not re-host data unless the
  provider's license permits it.
- Note that some datasets may be for **non-commercial or research use only**.

If you are unsure about the terms for a particular dataset, consult the provider
directly. The maintainers of MRITestData.jl cannot grant rights to third-party data.
