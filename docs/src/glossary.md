# Glossary

One-line definitions of the MRI and dataset terms used across this documentation. See
[Concepts & data model](@ref) for the longer explanation and [Taxonomy](@ref) for the
DICOM anchoring of the catalog field names.

## Acquisition & sampling

| Term | Meaning |
|---|---|
| **k-space** | The spatial Fourier transform of the image; what the scanner actually measures. |
| **Fully sampled** | Every k-space line the field of view requires was acquired → inverse FFT gives a clean image. |
| **Undersampled** | Lines were skipped to shorten the scan → inverse FFT aliases; needs parallel imaging or compressed sensing. |
| **Acceleration `R`** | Undersampling factor; `R = 3` ≈ one third of the lines acquired (`entry.acceleration`). |
| **ACS** | Auto-Calibration Signal — a small fully-sampled block at k-space centre used to estimate coil sensitivities. |
| **k-t sampling** | An undersampling pattern that varies across time frames (used for dynamic/cine imaging). |
| **Partial Fourier** | Acquiring slightly more than half of k-space and exploiting its conjugate symmetry. |
| **Nyquist rate** | The minimum sampling density for alias-free reconstruction of a given field of view. |
| **Trajectory** | The path through k-space the readout follows: Cartesian (grid), radial, spiral, EPI. |
| **Density compensation (DCF)** | Per-sample weights that correct for non-uniform k-space sampling density (non-Cartesian). |
| **Golden-angle radial** | Radial acquisition where successive spokes rotate by ~111.25°, giving near-uniform coverage at any stopping point. |

## Coils & reconstruction

| Term | Meaning |
|---|---|
| **Receive coil / channel** | One element of the scanner's receiver array; each sees the anatomy with a different spatial sensitivity. |
| **Virtual coil** | A linear (e.g. SVD) combination of physical coils used to compress channel count (`entry.coil_data == :derived`). |
| **Coil sensitivity map** | The per-coil complex spatial weighting; needed for parallel-imaging reconstruction. |
| **RSS** | Root-Sum-of-Squares — the simplest magnitude coil combination (no phase, no de-aliasing). |
| **Parallel imaging** | Using multiple coils' spatial information to reconstruct undersampled data (SENSE, GRAPPA). |
| **SENSE** | A parallel-imaging method that solves for the image given coil sensitivity maps. |
| **CG-SENSE** | Iterative (conjugate-gradient) SENSE; MRIReco's `"multiCoil"` reconstruction. |
| **ESPIRiT** | An auto-calibrating method to estimate coil sensitivity maps from an ACS region. |
| **Direct / gridding reconstruction** | Plain (inverse-FFT or NUFFT) reconstruction with no de-aliasing; MRIReco's `"direct"`. |
| **Compressed sensing** | Reconstruction that exploits image sparsity to recover undersampled data. |

## Formats & data model

| Term | Meaning |
|---|---|
| **ISMRMRD / MRD** | ISMRM Raw Data — a vendor-neutral HDF5 container for raw acquisitions + an XML experiment header. |
| **`RawAcquisitionData`** | The type [`load_raw`](@ref) returns: readout profiles + parsed header ([MRIReco.jl docs](https://magneticresonanceimaging.github.io/MRIReco.jl/latest/acquisitionData/#Raw-Data)). |
| **`AcquisitionData`** | The type a reconstruction package consumes; built by the caller from `RawAcquisitionData`. |
| **Profile / acquisition** | One readout line: its complex samples plus an encoding counter (phase-encode line, slice, contrast, …). |
| **fastMRI HDF5 layout** | The `kspace` / `reconstruction_rss` / `ismrmrd_header` HDF5 schema used by fastMRI and M4Raw. |
| **Encoded vs recon matrix** | Encoded = as-acquired size (may include oversampling); recon = target image size. |
| **`.mat` v7.3** | MATLAB's HDF5-based file format; how CMRxRecon distributes k-space. |

## Cardiac imaging

| Term | Meaning |
|---|---|
| **Cine** | A movie of the beating heart across the cardiac cycle; the frame axis is time. |
| **SAX** | Short-axis view — a stack of slices cutting across the left ventricle (base → apex). |
| **LAX** | Long-axis view — slices along the heart's long axis; the slice axis holds 2-/3-/4-chamber views. |
| **LVOT** | Left ventricular outflow tract — a third standard cine view. |
| **SSFP / bSSFP / TrueFISP** | Balanced steady-state free precession — the workhorse cine pulse sequence. |
| **T1 / T2 mapping** | Quantitative imaging: several differently-weighted images fitted per-pixel to a relaxation curve. |
| **MOLLI** | Modified Look-Locker Inversion recovery — the standard T1-mapping acquisition scheme. |
| **Tagging (SPAMM)** | A saturation grid laid over the myocardium; its deformation reveals regional strain. |
| **Black-blood** | A preparation that nulls flowing-blood signal for vessel-wall / morphology imaging. |
| **Flow / phase-contrast** | Velocity encoding: image phase is proportional to through-plane blood velocity. |
| **Retrospective / prospective gating** | Cardiac synchronization: sorting data to the ECG after (retro) or triggering on it before (pro) acquisition. |

## Pulse sequences & contrasts

| Term | Meaning |
|---|---|
| **GRE / FLASH / spoiled gradient echo** | A fast gradient-echo sequence family. |
| **TSE / FSE / turbo (fast) spin echo** | A multi-echo spin-echo sequence; T1/T2/PD weighting by TE/TR choice. |
| **EPI** | Echo-planar imaging — a very fast single-shot trajectory used for diffusion and functional MRI. |
| **FLAIR** | Fluid-Attenuated Inversion Recovery — a TSE variant that nulls CSF signal. |
| **VIBE (stack-of-stars)** | A 3-D spoiled-GRE sequence; the fastMRI breast data uses a radial stack-of-stars VIBE. |
| **PD-weighted** | Proton-density weighting (long TR, short TE); the fastMRI knee contrast. |

## Anatomy & subjects

| Term | Meaning |
|---|---|
| **rtMRI** | Real-time MRI — continuous imaging without cardiac/respiratory gating (USC Speech). |
| **Vocal tract (pharynx/larynx)** | The upper-airway region imaged in speech-production MRI. |
| **Volunteer vs patient** | `entry.cohort` — a healthy research subject vs a clinical patient. |
| **Low-field MRI** | MRI below ~0.5 T (M4Raw is 0.3 T); lower SNR, hence M4Raw's multi-repetition design. |
| **Split (train / val / test)** | The machine-learning corpus partition (`entry.split`); an ML concept, not an imaging one. |
