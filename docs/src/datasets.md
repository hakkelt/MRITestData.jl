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

**Metadata.** The live scrape of `mridata.org/list` carries per-card fields — vendor,
field strength, channel count (→ `entry.receiver_channels`), matrix size
(→ `entry.acquisition_dim`), plus TE/TR, institution, protocol, download count under
`entry.extra`. mridata.org's own anatomy labels go well beyond this package's curated
DICOM Body Part Examined subset (hip, shoulder, spine, phantom scans, …); anything not
recognised becomes `entry.anatomy == :other`. The committed `data/mridata_index.toml` is
a small **curated overlay** used to fill fields the site does not expose (notably
`approx_size_bytes`) and as the offline fallback when the scrape fails entirely.

Any mridata UUID can also be passed to [`dataset`](@ref) directly — a minimal entry is
synthesised from the UUID.

---

## `OCMR_SOURCE` — Open Cardiac MRI k-space

| | |
|---|---|
| Anatomy | **heart** (`entry.anatomy == :heart`; real-time and breath-hold cine) |
| Sampling | **fully sampled** (`fs_*` files) **and** pseudo-random **undersampled** (`us_*` files) |
| Trajectory | Cartesian |
| Vendor | Siemens (MAGNETOM Free.Max 0.55 T, Avanto / Sola 1.5 T, Prisma / Vida 3 T) |
| Field strength | **0.55 T / 1.5 T / 3 T** |
| File format | **ISMRMRD `.h5`** — loads directly |
| Access | direct HTTP from OCMR's S3 bucket; **citation of the OCMR paper required** |

**What a file contains.** One multi-coil cardiac cine acquisition. Coil counts are
**not** in OCMR's metadata — they live only inside the ISMRMRD file — so
`entry.receiver_channels` is `nothing` until the file is loaded.

**Coded metadata.** OCMR's attributes CSV uses short codes. The ones with a DICOM
anchor are decoded onto core fields; the rest stay in `entry.extra` (DICOM-keyword
named — see [`extra_schema`](@ref)`(OCMR_SOURCE)`):

| Core field / `extra` key | Values | Source column |
|---|---|---|
| `entry.fully_sampled` | `true`/`false` | `smp` (`fs`/`pse`), plus the `fs_`/`us_` filename prefix |
| `entry.orientation` | `:short_axis`, `:long_axis` | `viw` (`sax`/`lax`) |
| `entry.partial_fourier` | `true`/`false` | `ech` (`asy`=asymmetric/`sym`=symmetric) |
| `entry.cohort` | `:volunteer`, `:patient` | `sub` |
| `entry.num_slices` | slice count | `slices` |
| `entry.scanner_model` | e.g. `Siemens MAGNETOM Prisma` | `scn` |
| `extra["sampling"]` | `fully sampled`, `pseudo-random undersampled` | `smp` |
| `extra["slice_mode"]` | `individual`, `multiple`, `stack` | `sli` |
| `extra["partial_fourier_direction"]` | `symmetric`, `asymmetric` | `ech` |
| `extra["acquisition_duration_class"]` | `short`, `long` | `dur` |
| `extra["phase_wrap"]` | `no aliasing`, `with aliasing` | `fov` |

Field strength and fully/under-sampled status are also encoded in the file name
(`fs_0001_1_5T.h5`, `us_0014_3T.h5`) and used as a fallback.

**ECG header workaround.** OCMR cine files carry a `<waveformInformation>` (ECG) block
that trips a MRIFiles parser bug; [`load_raw`](@ref) strips it from the cached HDF5
in-place on first load.

---

## `CMRXRECON2024` — MICCAI 2024 cardiac reconstruction challenge

| | |
|---|---|
| Anatomy | **heart** (`aorta_*` series: **aorta**), multi-coil, Cartesian |
| Sampling | **fully sampled** ground truth (the challenge's undersampling masks are applied by you, not shipped) |
| Trajectory | Cartesian (the `Uniform`/`ktGaussian`/`ktRadial` labels are *sampling masks*, not trajectories) |
| Vendor / field | Siemens, 3 T (measured per-subject value; nominal 3 T when absent) |
| Coils | **10 virtual channels** (`entry.receiver_channels`, SVD-compressed by the organisers, `entry.coil_data == :derived`); physical element count 30–38 in `entry.extra["multi_coil_elements"]` |
| File format | MATLAB **v7.3 `.mat`** k-space → converted to cached Cartesian ISMRMRD on first load |
| Access | **Synapse token + completed challenge registration**; individual `.mat` files fetched by HTTP range from a ~1.2 TB split ZIP |

**Array layout.** Each `.mat` holds one k-space array shaped `(kx, ky, coils, slices,
frames)` — 4-D `(kx, ky, coils, slices)` when there is no temporal axis (BlackBlood).
Variable name: `kspace_full` (FullSample) or `kus` (undersampled tasks). Access the raw
arrays with `MRITestData.load_mat`.

**Series.** DICOM has no single "modality" attribute for this — see [Taxonomy](@ref) —
so each series decomposes onto several core fields. The file name also encodes the
series (e.g. `cine_sax`, `t1map`, `aorta_tra`):

| Series | Files | `contrast` | `orientation` | `sequence` | `quantitative` | `cardiac_sync` / other flags |
|---|---|---|---|---|---|---|
| **Cine** | `cine_sax`, `cine_lax`, `cine_lvot` | `:mixed` | `:short_axis`/`:long_axis`/`:lvot` | `"balanced steady-state free precession"` (TrueFISP) | `false` | `:retrospective` |
| **Mapping** | `T1map`, `T2map` | `:t1`/`:t2` | `:short_axis` | MOLLI-FLASH / T2-prepared FLASH ¹ | `true` | `:none` |
| **Tagging** | `tagging` | `:tagging` | `:short_axis` | `"tagged cine (SPAMM)"` | `false` | `:retrospective` |
| **Aorta** | `aorta_sag`, `aorta_tra` | `:mixed` | `:sagittal`/`:axial` | — | `false` | `:none` — `anatomy == :aorta` |
| **Flow2d** | `flow2d` | `:flow_encoded` | — | — | `false` | `phase_contrast == true` |
| **BlackBlood** | `blackblood` | `:unknown` ² | `:short_axis` | `"turbo spin echo"` | `false` | `blood_signal_nulling == true` |

¹ `entry.sequence`: `"modified Look-Locker inversion recovery (fast low angle shot
readout)"` for T1map, `"T2-prepared fast low angle shot"` for T2map — confirmed against
Wang et al. 2025 (see [Taxonomy](@ref) references): "the modified Look-Locker inversion
recovery-fast low angle shot sequence was used for T1 mapping" / "the T2-prepared-fast
low angle shot sequence was used for T2 mapping", both "with SAX view". T2 mapping is
FLASH-based (spoiled gradient echo), not balanced SSFP.

² Sequence and view are confirmed the same way ("the turbo spin-echo sequence was used
for black-blood under breath hold", "black-blood with SAX view"); the paper does not
state a T1 vs T2 weighting for it (no TE/TR given), so `contrast` stays genuinely
`:unknown` — that is a gap in the source, not an unverified guess.

**Views.** **SAX** (short-axis) — a stack of parallel slices across the left ventricle
(base → apex on the slice axis). **LAX** (long-axis) — the slice axis instead holds the
2-chamber / 3-chamber / 4-chamber views. LVOT (left ventricular outflow tract,
`orientation == :lvot`) is the third cine view.

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
published upstream, so `entry.extra["reconstruction_fov_mm"]`, `["acquisition_matrix"]`,
`["repetition_time_ms"]`, `["echo_time_ms"]` and `["flip_angle_deg"]` are populated only
for the Training subjects.)

---

## `CMRXRECON300` — revised CMRxRecon-2023 k-space

| | |
|---|---|
| Anatomy | **heart**, multi-coil, Cartesian, **300 healthy volunteers** (`entry.cohort == :volunteer`) |
| Sampling | **`_ks` k-space is UNDERSAMPLED** — regular k-t pattern, R≈3 (`entry.acceleration == 3.0`, `entry.undersampling_pattern == :uniform`) — paired with **fully-sampled ACS `_calib`** files (`entry.has_acs == true`) |
| Trajectory | Cartesian |
| Vendor / field | Siemens, 3 T |
| Coils | **30 physical channels retained** (no SVD compression); `entry.receiver_channels == 30` |
| File format | MATLAB **v7.3 `.mat`** (variable `Recon_ks` for imaging, `Calib` for ACS) → converted to cached Cartesian ISMRMRD on first load |
| Access | **free Synapse account** (no challenge registration); split `.tar.gz` archives, one continuous gzip stream, random-access via a committed **zran** checkpoint index |

**Reconstruction implication.** `load_raw` reads the true acquired-line pattern from the
zero-fill pattern of `Recon_ks`, so the resulting `RawAcquisitionData` is correctly
marked undersampled. A plain inverse FFT **aliases**; an artifact-free image needs
parallel imaging (ESPIRiT / CG-SENSE) using the paired ACS. The ACS lines are written
into the same ISMRMRD file, flagged `ACQ_IS_PARALLEL_CALIBRATION` and centred in the
phase-encode extent; the calib file's coordinates are in `entry.locator["calib_path"]`
(a transport detail, not DICOM metadata — kept out of `entry.extra`).

**Series** — every subject has all four:

| `modality` column | `contrast` | `orientation` | `quantitative` | Contents |
|---|---|---|---|---|
| Cine SAX (`cine_sax_ks` + `_calib`) | `:mixed` | `:short_axis` | `false` | short-axis balanced-SSFP cine stack |
| Cine LAX (`cine_lax_ks` + `_calib`) | `:mixed` | `:long_axis` | `false` | long-axis cine (2ch/3ch/4ch on the slice axis) |
| T1map (`t1map_ks` + `_calib`) | `:t1` | `:short_axis` | `true` | inversion-time series → per-pixel T1 |
| T2map (`t2map_ks` + `_calib`) | `:t2` | `:short_axis` | `true` | T2-prep echo-time series → per-pixel T2 |

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
| Anatomy | **pharynx/larynx** (`entry.anatomy == :pharynx_larynx`, "vocal tract"), sagittal (`entry.orientation == :sagittal`), real-time speech production |
| Sampling | non-Cartesian; the raw file holds all **13 spiral interleaves**, which together fulfil the Nyquist rate (Lim et al. 2021) — `entry.fully_sampled == true` |
| Trajectory | **spiral** — 13-interleaf spiral-out spoiled GRE (`entry.trajectory == :spiral`) |
| Vendor / field | **GE Signa Excite, 1.5 T**, custom **8-channel** upper-airway array (`entry.receiver_channels == 8`) |
| File format | **MRD / ISMRMRD `.h5`** already — loads directly, **no conversion**. Stores spiral k-space samples **plus the k-space trajectory and density-compensation tables** |
| Access | figshare `dataset.zip` (~570 GB, CC-BY, no account); one `.h5` member pulled by ZIP range request |

**Reconstruction implication.** Because the trajectory is non-Cartesian, the loaded
`RawAcquisitionData`'s `params["trajectory"]` is **not** `"cartesian"`. Build a
non-Cartesian `AcquisitionData` (with the trajectory + density compensation) — an
inverse FFT is not applicable.

**What is cataloged.** Only the **`2drt`** (2-D real-time) sagittal pharynx/larynx raw
k-space. Each entry is one *subject × stimulus × repetition* (`entry.subject_id`,
`entry.repetition`); ids look like `sub001/2drt/01_vcv1_r1`. Committed map:
`data/usc_speech_map.csv`, **75 subjects**, 2371 files.

**Stimuli** (`entry.extra["protocol_name"]`) — 21 per subject:

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
| Vendor / field | **"Oper-0.3" (Ningbo Xingaoyi), 0.3 T** whole-body scanner, **4-channel** head coil, **183 volunteers** |
| File format | **fastMRI HDF5 layout** (`kspace` / `reconstruction_rss` / `ismrmrd_header`) → converted to cached Cartesian ISMRMRD on first load |
| Access | Zenodo ZIPs (CC-BY, no account); one `.h5` member pulled by ZIP range request |

**Array layout.** `kspace` on disk is `(slices, coils, freq, phase)`; HDF5.jl reads it
reversed and the loader permutes to canonical `(kx, ky, coils, slices, 1)`.
`reconstruction_rss` is the per-repetition RSS magnitude ground truth (not used by the
converter). Multi-repetition data is the point of M4Raw: averaging or learning across
repetitions to overcome the low SNR of 0.3 T.

**Contrasts** (`entry.contrast`/`entry.sequence`, with `entry.repetition` `1`, `2`, …) and
file counts in the committed map (`data/m4raw_map.csv`, 2030 files):

| Contrast | Files | `entry.contrast` | `entry.sequence` |
|---|--:|---|---|
| T1w (TSE) | 624 | `:t1` | `"turbo spin echo"` |
| T2w (TSE) | 624 | `:t2` | `"turbo spin echo"` |
| FLAIR | 416 | `:fluid_attenuated` | `"turbo spin echo (inversion-recovery prepared)"` |
| T1 GRE ¹ | 366 | `:t1` | `"spoiled gradient echo"`; separate archive (`M4RawV1.5_gre_data.zip`) |

¹ GRE was added in the M4RawV1.5 release, after the original Scientific Data paper (which
describes only T1w/T2w TSE and FLAIR); its T1-weighting is confirmed by the M4RawV1.5
release notes and dataset card ("T1w Gradient echo (GRE) data") on
[github.com/mylyu/M4Raw](https://github.com/mylyu/M4Raw) and Zenodo record 8056074.

**Sets** (`entry.split`): `:train` (1024), `:val` (240), `:test` (400); the GRE archive
carries no train/val/test split (`entry.split === nothing`). All splits are fully
sampled.

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

The map's `series_variant` column is the archive filename's middle token — never a coil
count: `singlecoil`/`multicoil` for knee/brain (→ `entry.coil_data`), or the sequence
type `T2`/`DIFF` for prostate (→ `entry.contrast`/`entry.sequence`).

| Anatomy | Coil format | Trajectory | Field | Fully sampled | Notes |
|---|---|---|---|---|---|
| **knee** | singlecoil **and** multicoil; `entry.receiver_channels` unset (varies per file), `entry.coil_data == :derived` for the emulated singlecoil files | Cartesian | 3 T nominal (exact value in ISMRMRD header) | train/val yes, **test masked** | `entry.contrast == :proton_density`, `entry.orientation == :coronal`, `entry.sequence == "fast spin echo"`, `entry.vendor == :siemens` |
| **brain** | multicoil | Cartesian | header | train/val yes, **test masked** | `entry.orientation == :axial`; `entry.contrast` from the file name (`AXT1`/`AXT1PRE` → `:t1` `contrast_agent=false`, `AXT1POST` → `:t1` `contrast_agent=true`, `AXT2` → `:t2`, `AXFLAIR` → `:fluid_attenuated`) |
| **prostate** | multicoil | Cartesian | 3 T | **no** (highly accelerated / aliased; `entry.fully_sampled == false` regardless of split) | `entry.contrast`/`entry.sequence`: T2 → `:t2`/`"turbo spin echo"`, DIFF → `:diffusion`/`"echo-planar imaging"` |
| **breast** | multicoil, `entry.receiver_channels == 16` | **golden-angle radial** (`entry.trajectory == :goldenangle`, `entry.acceleration ≈ 2.8`) | 3 T, `entry.scanner_model == "Siemens MAGNETOM TimTrio"` | **no** | `entry.acquisition_dim == 3`; stored `(slices, coils, kx, ky, 2)` real/imag Float64; large (~4.5 GB per file); `entry.sequence == "radial VIBE (stack-of-stars)"`, `entry.partial_fourier == true` |

**Test-split sampling (bug fix).** Knee and brain `test`-split files are prospectively
undersampled for the challenge (they ship a `mask`); only train/val is genuinely fully
sampled. `entry.fully_sampled` reflects this per-file (`split !== :test`), not just
per-anatomy — a change from the pre-refactor catalog, which incorrectly marked every
knee/brain `test` entry as fully sampled regardless of split.

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
| `OCMR_SOURCE` | heart, cine | full **+** undersampled | Cartesian | 0.55 / 1.5 / 3 | ISMRMRD | direct (fs) / PI (us) |
| `CMRXRECON2024` | heart / aorta (6 series) | full | Cartesian | 3 | `.mat` → ISMRMRD | direct FFT |
| `CMRXRECON300` | heart (cine + T1/T2 map) | **undersampled** + ACS | Cartesian | 3 | `.mat` → ISMRMRD | **parallel imaging** |
| `USC_SPEECH` | pharynx/larynx (rt speech) | non-Cartesian, fully sampled | **spiral** | 1.5 | MRD/ISMRMRD | non-Cartesian |
| `M4RAW` | brain (multi-contrast/rep) | full | Cartesian | **0.3** | fastMRI `.h5` → ISMRMRD | direct FFT |
| `FASTMRI` | knee / brain / prostate / breast | full for train/val; test/prostate/breast: no | Cartesian (breast: golden-angle radial) | 1.5 / 3 | fastMRI `.h5` → ISMRMRD | direct FFT / PI |
