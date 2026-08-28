# Dataset contents

This page documents, source by source, **what kind of data each dataset actually
contains** — anatomy, contrasts/modalities, sampling, coil configuration, field
strength, the on-disk file format and array layout, and how many files of each kind
the catalog exposes.

For the download/credential workflow and the reconstruction pipeline see [Usage](@ref);
for licensing see [Licensing & legal](@ref).

!!! note "Where the numbers come from"
    `MRIDATA` and `OCMR_SOURCE` are backed by a **self-updating upstream index** — the
    live catalog is larger than the committed offline fallback, and counts drift as the
    upstreams grow. The other five sources (`CMRXRECON2024`, `CMRXRECON300`, `USC_SPEECH`,
    `M4RAW`, `FASTMRI`) are backed by **static committed offset maps** (`data/*_map.csv`),
    so the file counts below are exact for the shipped package.

Every source is normalised to an `MRIBase.RawAcquisitionData` by [`load_raw`](@ref).
The temporal / parametric axis (cine frames, mapping weightings, …) is always mapped to
ISMRMRD **contrasts**; the slice axis to ISMRMRD **slices**; `repetition` stays 0 unless
noted.

---

## `MRIDATA` — mridata.org

| | |
|---|---|
| Anatomy | mostly **3-D Cartesian knee**, plus brain/body volumes |
| Sampling | **fully sampled** raw k-space |
| Trajectory | Cartesian (3-D and 2-D) |
| Vendors | GE / Siemens / Philips |
| Field strength | 1.5 T / 3 T |
| File format | **ISMRMRD `.h5`** — loads directly, no conversion |
| Access | direct HTTP download (`http://mridata.org/download/<uuid>`), per-dataset terms |

**What a file contains.** One complete raw acquisition in ISMRMRD form: the readout
profiles plus the scanner's XML header (encoding/recon matrix, FOV, TE/TR, receiver
channel count, …). The 3-D FSE knee volumes are the workhorse: a single fully-sampled
Cartesian volume, typically 8–15 coils, tens of phase-encode partitions.

**Metadata.** The live scrape of `mridata.org/list` carries per-card fields (vendor,
field strength, channel count, matrix size, TE/TR, institution, protocol, download
count) — all surfaced under `entry.extra`. The committed `data/mridata_index.toml` is a
small **curated overlay** used to fill fields the site does not expose (notably
`approx_size_bytes`) and as the offline fallback when the scrape fails entirely.

Any mridata UUID can also be passed to [`dataset`](@ref) directly — a minimal entry is
synthesised from the UUID.

---

## `OCMR_SOURCE` — Open Cardiac MRI k-space

| | |
|---|---|
| Anatomy | **cardiac** (real-time and breath-hold cine) |
| Sampling | **fully sampled** (`fs_*` files) **and** pseudo-random **undersampled** (`us_*` files) |
| Trajectory | Cartesian |
| Vendor | Siemens (MAGNETOM Free.Max 0.55 T, Avanto / Sola 1.5 T, Prisma / Vida 3 T) |
| Field strength | **0.55 T / 1.5 T / 3 T** |
| File format | **ISMRMRD `.h5`** — loads directly |
| Access | direct HTTP from OCMR's S3 bucket; **citation of the OCMR paper required** |

**What a file contains.** One multi-coil cardiac cine acquisition. Coil counts are
**not** in OCMR's metadata — they live only inside the ISMRMRD file — so `entry.coils`
is `nothing` until the file is loaded.

**Coded metadata.** OCMR's attributes CSV uses short codes, decoded into `entry.extra`:

| `extra` key | Values |
|---|---|
| `sampling` | `fully sampled`, `pseudo-random undersampled` |
| `view` | `sax` (short-axis), `lax` (long-axis), … |
| `slice_mode` | `individual`, `stack` (unmapped upstream codes such as `mul` = multi-slice pass through verbatim) |
| `echo` | `symmetric`, `asymmetric` (partial-Fourier readout) |
| `duration` | `short`, `long` (scan length) |
| `fov` | `no aliasing`, `with aliasing` |
| `subject` | `volunteer`, `patient` |
| `slices` | slice count |
| `scanner_model` | e.g. `Siemens MAGNETOM Prisma` |

Field strength and fully/under-sampled status are also encoded in the file name
(`fs_0001_1_5T.h5`, `us_0014_3T.h5`) and used as a fallback.

**ECG header workaround.** OCMR cine files carry a `<waveformInformation>` (ECG) block
that trips a MRIFiles parser bug; [`load_raw`](@ref) strips it from the cached HDF5
in-place on first load.

---

## `CMRXRECON2024` — MICCAI 2024 cardiac reconstruction challenge

| | |
|---|---|
| Anatomy | **cardiac**, multi-coil, Cartesian |
| Sampling | **fully sampled** ground truth (the challenge's undersampling masks are applied by you, not shipped) |
| Trajectory | Cartesian (the `Uniform`/`ktGaussian`/`ktRadial` labels are *sampling masks*, not trajectories) |
| Vendor / field | Siemens, 3 T (measured value per subject in `entry.extra["field_strength"]`) |
| Coils | **10 virtual channels** (SVD-compressed by the organisers); physical element count 30–38 in `entry.extra["hardware_coils"]` |
| File format | MATLAB **v7.3 `.mat`** k-space → converted to cached Cartesian ISMRMRD on first load |
| Access | **Synapse token + completed challenge registration**; individual `.mat` files fetched by HTTP range from a ~1.2 TB split ZIP |

**Array layout.** Each `.mat` holds one k-space array shaped `(kx, ky, coils, slices,
frames)` — 4-D `(kx, ky, coils, slices)` when there is no temporal axis (BlackBlood).
Variable name: `kspace_full` (FullSample) or `kus` (undersampled tasks). Access the raw
arrays with `MRITestData.load_mat`.

**Modalities** (`entry.extra["modality"]`; the file name also encodes it):

| Modality | Files | Contents | Temporal axis |
|---|---|---|---|
| **Cine** | `cine_sax`, `cine_lax`, `cine_lvot` | balanced-SSFP movie of the beating heart | cardiac phase (time) |
| **Mapping** | `T1map`, `T2map` | series of differently *weighted* images to fit a per-pixel relaxation map (T1: inversion times / MOLLI; T2: T2-prep echo times) | weighting index (not time) |
| **Tagging** | `tagging` | cine with a saturation tag grid → regional strain | cardiac phase |
| **Aorta** | `aorta_sag`, `aorta_tra` | cine of the aorta (sagittal / transverse) | cardiac phase |
| **Flow2d** | `flow2d` | 2-D phase-contrast through-plane velocity mapping | cardiac phase |
| **BlackBlood** | `blackblood` | dark-blood-prepared *anatomical* scan (blood nulled), vessel wall / morphology | **none** (4-D → single contrast) |

**Views.** **SAX** (short-axis) — a stack of parallel slices across the left ventricle
(base → apex on the slice axis). **LAX** (long-axis) — the slice axis instead holds the
2-chamber / 3-chamber / 4-chamber views. `cine_lvot` is the left-ventricular
outflow-tract view.

**File counts in the committed map** (`data/cmrxrecon2024_map.csv`, all MultiCoil):

| Modality | Training | Validation | Test |
|---|--:|--:|--:|
| Cine | 566 | 178 | 203 |
| Mapping | 386 | 120 | 137 |
| Aorta | 301 | 90 | 96 |
| Tagging | 143 | 49 | 46 |
| Flow2d | — | 58 | 67 |
| BlackBlood | — | 57 | 67 |

(Validation/Test acquisition parameters — FOV, TR/TE, flip angle, matrix — are not
published upstream, so `entry.extra` carries them only for the Training subjects.)

---

## `CMRXRECON300` — revised CMRxRecon-2023 k-space

| | |
|---|---|
| Anatomy | **cardiac**, multi-coil, Cartesian, **300 healthy volunteers** |
| Sampling | **`_ks` k-space is UNDERSAMPLED** — regular k-t pattern, R≈3 — paired with **fully-sampled ACS `_calib`** files |
| Trajectory | Cartesian |
| Vendor / field | Siemens, 3 T |
| Coils | **30 physical channels retained** (no SVD compression); `entry.coils` is `nothing`, the count comes from the data |
| File format | MATLAB **v7.3 `.mat`** (variable `Recon_ks` for imaging, `Calib` for ACS) → converted to cached Cartesian ISMRMRD on first load |
| Access | **free Synapse account** (no challenge registration); split `.tar.gz` archives, one continuous gzip stream, random-access via a committed **zran** checkpoint index |

**Reconstruction implication.** `load_raw` reads the true acquired-line pattern from the
zero-fill pattern of `Recon_ks`, so the resulting `RawAcquisitionData` is correctly
marked undersampled. A plain inverse FFT **aliases**; an artifact-free image needs
parallel imaging (ESPIRiT / CG-SENSE) using the paired ACS. The ACS lines are written
into the same ISMRMRD file, flagged `ACQ_IS_PARALLEL_CALIBRATION` and centred in the
phase-encode extent; the calib file id is in `entry.extra["calib_id"]` /
`entry.extra["calib_path"]`.

**Modalities** — every subject has all four:

| `entry.extra["modality"]` | Files | Contents |
|---|---|---|
| Cine SAX | `cine_sax_ks` + `cine_sax_calib` | short-axis balanced-SSFP cine stack |
| Cine LAX | `cine_lax_ks` + `cine_lax_calib` | long-axis cine (2ch/3ch/4ch on the slice axis) |
| T1map | `t1map_ks` + `t1map_calib` | inversion-time series → per-pixel T1 |
| T2map | `t2map_ks` + `t2map_calib` | T2-prep echo-time series → per-pixel T2 |

**Sets** (committed member maps `data/cmrxrecon300_<set>_map.csv`; each catalog entry
pairs one `_ks` file with its `_calib` file). Counts below are **entries** (i.e.
subject × modality):

| Set | Subjects | Cine SAX | Cine LAX | T1map | T2map |
|---|--:|--:|--:|--:|--:|
| Training | 120 | 119 | 120 | 120 | 120 |
| Validation | 60 | 60 | 60 | 60 | 60 |
| Test | 120 | 90 | 83 | 119 | 119 |
| Demo | 1 | 1 | 1 | 1 | 1 |

(A few Test subjects are missing a modality, hence the uneven counts.)

CMRxRecon-300 has **no upstream index**: its catalog is built from the committed per-set
member maps, so `refresh_index` has nothing to fetch and simply reports them.

---

## `USC_SPEECH` — USC SPAN 75-speaker real-time speech rtMRI

| | |
|---|---|
| Anatomy | **vocal tract** (mid-sagittal), real-time speech production |
| Sampling | non-Cartesian; a single spiral frame is undersampled, the raw file holds the full time series (`entry.fully_sampled` is left unasserted) |
| Trajectory | **spiral** — 13-interleaf spiral-out spoiled GRE (`entry.trajectory == :spiral`) |
| Vendor / field | **GE Signa Excite, 1.5 T**, custom **8-channel** upper-airway array |
| File format | **MRD / ISMRMRD `.h5`** already — loads directly, **no conversion**. Stores spiral k-space samples **plus the k-space trajectory and density-compensation tables** |
| Access | figshare `dataset.zip` (~570 GB, CC-BY, no account); one `.h5` member pulled by ZIP range request |

**Reconstruction implication.** Because the trajectory is non-Cartesian, the loaded
`RawAcquisitionData`'s `params["trajectory"]` is **not** `"cartesian"`. Build a
non-Cartesian `AcquisitionData` (with the trajectory + density compensation) — an
inverse FFT is not applicable.

**What is cataloged.** Only the **`2drt`** (2-D real-time) mid-sagittal vocal-tract raw
k-space. Each entry is one *subject × stimulus × repetition*; ids look like
`sub001/2drt/01_vcv1_r1`. Committed map: `data/usc_speech_map.csv`, **75 subjects**,
2371 files.

**Stimuli** (`entry.extra["stimulus"]`) — 21 per subject:

| Stimulus | Content |
|---|---|
| `01_vcv1`–`03_vcv3` | vowel–consonant–vowel sequences |
| `04_bvt` | /bVt/ token set |
| `05_shibboleth` | shibboleth sentences |
| `06_rainbow` | "Rainbow" passage |
| `07_grandfather1/2` | "Grandfather" passage |
| `09_northwind1/2` | "North Wind and the Sun" passage |
| `11_postures` | held articulatory postures |
| `12_picture1`–`16_picture5` | picture-description spontaneous speech |
| `17_topic1`–`21_topic5` | free spontaneous speech by topic |

---

## `M4RAW` — low-field brain, multi-contrast, multi-repetition

| | |
|---|---|
| Anatomy | **brain** |
| Sampling | **fully-sampled Cartesian** (one repetition per file) → plain inverse FFT reconstructs it, no parallel imaging needed |
| Trajectory | Cartesian |
| Vendor / field | unnamed **0.3 T** whole-body scanner, **4-channel** head coil, **183 volunteers** |
| File format | **fastMRI HDF5 layout** (`kspace` / `reconstruction_rss` / `ismrmrd_header`) → converted to cached Cartesian ISMRMRD on first load |
| Access | Zenodo ZIPs (CC-BY, no account); one `.h5` member pulled by ZIP range request |

**Array layout.** `kspace` on disk is `(slices, coils, freq, phase)`; HDF5.jl reads it
reversed and the loader permutes to canonical `(kx, ky, coils, slices, 1)`.
`reconstruction_rss` is the per-repetition RSS magnitude ground truth (not used by the
converter). Multi-repetition data is the point of M4Raw: averaging or learning across
repetitions to overcome the low SNR of 0.3 T.

**Contrasts** (`entry.extra["contrast"]`, with `repetition` `01`, `02`, …) and file
counts in the committed map (`data/m4raw_map.csv`, 2030 files):

| Contrast | Files | Notes |
|---|--:|---|
| T1w (TSE) | 624 | `contrast == "T1"` |
| T2w (TSE) | 624 | `contrast == "T2"` |
| FLAIR | 416 | `contrast == "FLAIR"` |
| T1 GRE | 366 | `contrast == "GRE"`; separate archive (`M4RawV1.5_gre_data.zip`) |

Up to six repetitions per study × contrast (`entry.extra["repetition"]` `1`–`6`).

**Sets** (`entry.extra["set"]`): `multicoil_train` (1024), `multicoil_val` (240),
`multicoil_test` (400), `gre` (366). All splits are fully sampled.

---

## `FASTMRI` — NYU / FAIR fastMRI

| | |
|---|---|
| Anatomy | **knee, brain, prostate, breast** |
| File format | **fastMRI HDF5 layout** (`kspace` / optional `mask` / `ismrmrd_header`) → converted to cached ISMRMRD on first load (same converter as M4Raw) |
| Access | **form-gated** — request at [fastmri.med.nyu.edu](https://fastmri.med.nyu.edu); the email carries **90-day pre-signed AWS S3 URLs**. Register them with [`set_fastmri_urls!`](@ref) |
| Archives | knee & brain: `.tar.xz` (xz block-level range extraction); prostate & breast: `.tar.gz` (zran checkpoint index in `data/fastmri_zran/`) |

Individual scans are extracted from the archives without downloading them whole. Until
the maintainer populates `data/fastmri_map.csv`, `list_datasets(FASTMRI)` is empty — see
[fastMRI: form-gated credentials](@ref).

**Array layout.** `kspace` on disk is `(slices, coils, kx, ky)` (multicoil) or
`(slices, kx, ky)` (knee singlecoil); prostate is 5-D `(slices, coils, kx, ky,
averages)` and the averages (interleaved shots) are summed. A 1-D `mask` (0/1 over ky)
is present for **test-split** data (prospectively undersampled for the challenge) and
absent for fully-sampled train/val data; when absent, acquired lines are detected from
non-zero k-space energy.

### Per-anatomy contents (committed map `data/fastmri_map.csv`)

| Anatomy | Coil format | Trajectory | Field | Fully sampled | Notes |
|---|---|---|---|---|---|
| **knee** | singlecoil **and** multicoil (~15 coils) | Cartesian | 1.5 T / 3 T (in ISMRMRD header) | train/val yes, test masked | coronal PD and PD-fat-sat, per fastMRI protocol; the singlecoil files are emulated from the multicoil ones — same scans |
| **brain** | multicoil (~4–20 coils) | Cartesian | header | train/val yes, test masked | axial T1 / T1-pre / T1-post / T2 / FLAIR (contrast in the file name, e.g. `file_brain_AXT1POST_…`) |
| **prostate** | multicoil | Cartesian | 3 T | **no** (highly accelerated / aliased) | two sequence types in `entry.extra["sequence"]`: **T2** and **DIFF** (diffusion); `entry.fully_sampled == false` |
| **breast** | multicoil | **radial** (`entry.trajectory == :radial`, golden-angle) | 3 T | — | `entry.is3D == true`; stored `(slices, coils, kx, ky, 2)` real/imag Float64; large (~4.5 GB per file) |

**File counts:**

| Anatomy · coils · split | Files |
|---|--:|
| knee · singlecoil · train / val / test | 973 / 199 / 108 |
| knee · multicoil · train / val / test | 973 / 199 / 118 |
| brain · multicoil · train / val / test | 4469 / 1378 / 1116 |
| prostate · T2 · train | 126 |
| prostate · DIFF · train | 60 |
| breast · multicoil · train | 100 |

(fastMRI ships only train/val publicly for prostate and breast; the brain/knee `test`
splits are prospectively undersampled, and brain additionally ships `*_test_full`
fully-sampled archives.)

---

## Quick cross-source summary

| Source | Anatomy | Sampling | Trajectory | Field (T) | Native format | Recon |
|---|---|---|---|---|---|---|
| `MRIDATA` | knee / brain (3-D) | full | Cartesian | 1.5 / 3 | ISMRMRD | direct FFT |
| `OCMR_SOURCE` | cardiac cine | full **+** undersampled | Cartesian | 0.55 / 1.5 / 3 | ISMRMRD | direct (fs) / PI (us) |
| `CMRXRECON2024` | cardiac (6 modalities) | full | Cartesian | 3 | `.mat` → ISMRMRD | direct FFT |
| `CMRXRECON300` | cardiac (cine + T1/T2 map) | **undersampled** + ACS | Cartesian | 3 | `.mat` → ISMRMRD | **parallel imaging** |
| `USC_SPEECH` | vocal tract (rt speech) | non-Cartesian | **spiral** | 1.5 | MRD/ISMRMRD | non-Cartesian |
| `M4RAW` | brain (multi-contrast/rep) | full | Cartesian | **0.3** | fastMRI `.h5` → ISMRMRD | direct FFT |
| `FASTMRI` | knee / brain / prostate / breast | full (prostate: no) | Cartesian (breast: radial) | 1.5 / 3 | fastMRI `.h5` → ISMRMRD | direct FFT / PI |
