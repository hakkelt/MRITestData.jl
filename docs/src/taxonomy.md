# Taxonomy

`DatasetEntry`'s field names, value vocabularies and units are anchored in the DICOM
standard wherever DICOM has an attribute for the concept. A handful of fields have no
DICOM equivalent; those are documented **extensions**, each with a one-line
justification. This page is the reference for both, plus the ISMRMRD trajectory crosswalk
and the external sources consulted while designing it.

Use [`dicom_tag`](@ref)/[`dicom_keyword`](@ref) to look the mapping up programmatically:

```julia
julia> dicom_tag(:field_strength)
(0x0018, 0x0087, "MagneticFieldStrength")

julia> dicom_keyword(:receiver_channels)  # an extension — no DICOM tag
```

## Core fields → DICOM attributes

| Field | DICOM attribute | Tag |
|---|---|---|
| `name` | Series Description | (0008,103E) |
| `subject_id` | Clinical Trial Subject ID | (0012,0040) |
| `repetition` | Acquisition Number | (0020,0012) |
| `vendor` | Manufacturer | (0008,0070) |
| `scanner_model` | Manufacturer Model Name | (0008,1090) |
| `institution` | Institution Name | (0008,0080) |
| `field_strength` | Magnetic Field Strength (T) | (0018,0087) |
| `coil_data` | Image Type, value 1 | (0008,0008) |
| `anatomy` | Body Part Examined | (0018,0015) |
| `contrast` | Acquisition Contrast | (0008,9209) |
| `orientation` | View Code Sequence | (0054,0220) |
| `sequence` | Pulse Sequence Name | (0018,9005) |
| `echo_type` | Echo Pulse Sequence | (0018,9008) |
| `acquisition_dim` | MR Acquisition Type | (0018,0023) |
| `num_slices` | Number of Frames | (0028,0008) |
| `num_frames` | Cardiac Number of Images | (0018,1090) |
| `num_averages` | Number of Averages | (0018,0083) |
| `fully_sampled` | Percent Sampling `== 100` | (0018,0093) |
| `partial_fourier` | Partial Fourier | (0018,9081) |
| `has_acs` | Parallel Acquisition | (0018,9077) |
| `cardiac_sync` | Cardiac Synchronization Technique | (0018,9037) |
| `phase_contrast` | Phase Contrast | (0018,9014) |
| `blood_signal_nulling` | Blood Signal Nulling | (0018,9022) |
| `fat_suppression` | Spectrally Selected Suppression | (0018,9025) |
| `contrast_agent` | Contrast/Bolus Agent | (0018,0010) |

`source`, `id`, `approx_size_bytes`, `sha256`, `url`, `extra` and `locator` are transport
or identity fields, not imaging metadata, and are not DICOM-anchored.

## `extra` keys → DICOM attributes

Populated per source (see [`extra_schema`](@ref) for what each source actually carries):

| `extra` key | DICOM attribute | Tag |
|---|---|---|
| `repetition_time_ms` | Repetition Time | (0018,0080) |
| `echo_time_ms` | Echo Time | (0018,0081) |
| `flip_angle_deg` | Flip Angle | (0018,1314) |
| `reconstruction_fov_mm` | Reconstruction Field of View | (0018,9317) |
| `acquisition_matrix` | Acquisition Matrix | (0018,1310) |
| `multi_coil_elements` | Multi-Coil Definition Sequence (item count) | (0018,9045) |
| `acquisition_duration_class` | Acquisition Duration | (0018,9073) |
| `partial_fourier_direction` | Partial Fourier Direction | (0018,9036) |
| `protocol_name` | Protocol Name | (0018,1030) |
| `parallel_reduction_factor_in_plane` | Parallel Reduction Factor In-plane | (0018,9069) |

`Modality` (0008,0060) is `MR` for every entry in the package — a constant, stored
nowhere. That is also why the old free-text `modality` key was retired: the name is taken
by DICOM and means something else (see [`TAXONOMY_EXTENSIONS`](@ref) and the per-source
decomposition into `contrast`/`cardiac_sync`/`orientation`/etc.).

## The seven extensions

Each exists because DICOM has no attribute for the concept:

- **`receiver_channels`** — DICOM enumerates coil elements in Multi-Coil Definition
  Sequence (0018,9045) with Multi-Coil Element Used (0018,9048); there is no count
  attribute. Anchored on ISMRMRD `acquisitionSystemInformation/receiverChannels`.
- **`split`** — ML-corpus partition, not an imaging concept.
- **`cohort`** — no DICOM research-subject-class attribute.
- **`undersampling_pattern`** — Parallel Acquisition Technique (0018,9078) names the
  *reconstruction* (SENSE/SMASH/GRAPPA), not the sampling mask. VISTA, kt-Gaussian,
  kt-radial, Poisson-disc have no term.
- **`orientation`** vocabulary — View Code Sequence (0054,0220) is the right container and
  takes SNOMED codes, but DICOM publishes no Context Group for cardiac **MR** views (the
  cardiac view CIDs are echocardiography). Local symbols for now; SNOMED coding is a later
  refinement, and codes must not be invented.
- **`quantitative`** — DICOM's anchor is the Parametric Map Storage SOP class, an object
  type rather than an attribute. BIDS `T1map`/`T2map` suffix is the practical equivalent.
- **`trajectory`** vocabulary — Geometry of k-Space Traversal (0018,9032) offers only
  `RECTILINEAR`/`RADIAL`/`SPIRAL`; EPI lives in Scanning Sequence (`EP`) and golden-angle
  is a radial *ordering* with no term. ISMRMRD's enum is strictly more expressive and is
  the package's output format (crosswalk below).
- **`acceleration`** — Parallel Reduction Factor In-plane (0018,9069) is in-plane and
  parallel-imaging-specific. `acceleration` is *net* R, defined at the source's native
  frame binning; kept in `extra["parallel_reduction_factor_in_plane"]` when the DICOM
  value is separately known.

`fully_sampled` is **not** an extension: it is Percent Sampling (0018,0093) `== 100`. The
boolean is kept for query ergonomics.

## ISMRMRD `trajectoryType` crosswalk

| `DatasetEntry.trajectory` | ISMRMRD `trajectoryType` | DICOM Geometry of k-Space Traversal |
|---|---|---|
| `:cartesian` | `cartesian` | `RECTILINEAR` |
| `:epi` | `epi` | (Scanning Sequence `EP`; no k-space-geometry term) |
| `:radial` | `radial` | `RADIAL` |
| `:goldenangle` | `goldenangle` | `RADIAL` (ordering not representable) |
| `:spiral` | `spiral` | `SPIRAL` |
| `:other` | `other` | — |

## External references consulted

Standards:

- DICOM PS3.3 §C.8.13.3, MR Image Description Macro — Acquisition Contrast (0008,9209)
  defined terms, Complex Image Component (0008,9208).
  <https://dicom.nema.org/medical/dicom/current/output/chtml/part03/sect_C.8.13.3.html>
- DICOM PS3.3 §C.8.13.4, MR Pulse Sequence Module — MR Acquisition Type (0018,0023),
  Echo Pulse Sequence (0018,9008), Phase Contrast (0018,9014), Spectrally Selected
  Suppression (0018,9025), Segmented k-Space Traversal (0018,9033), Coverage of k-Space
  (0018,9094), Geometry of k-Space Traversal (0018,9032).
  <https://dicom.nema.org/medical/dicom/current/output/chtml/part03/sect_C.8.13.4.html>
- DICOM PS3.3 §C.7.6.18, Physiological Synchronization — Cardiac Synchronization
  Technique (0018,9037) defined terms, Cardiac Signal Source (0018,9085).
  <https://dicom.nema.org/medical/dicom/current/output/chtml/part03/sect_C.7.6.18.html>
- DICOM PS3.16 Annex L, Correspondence of Anatomic Region Codes and Body Part Examined —
  verified terms `HEART`, `AORTA`, `BRAIN`, `KNEE`, `BREAST`, `PROSTATE`,
  `PHARYNXLARYNX`, `LARYNX`, `TONGUE`, `NECK`.
  <https://dicom.nema.org/medical/dicom/current/output/chtml/part16/chapter_L.html>
- DICOM Standard Browser (Innolitics), Acquisition Contrast (0008,9209).
  <https://dicom.innolitics.com/ciods/enhanced-mr-image/enhanced-mr-image/00089209>
- DICOM Standard Browser (Innolitics), Percent Sampling (0018,0093) — "the fraction of
  acquisition matrix lines acquired, expressed as a percent"; the anchor for
  `fully_sampled`. <https://dicom.innolitics.com/ciods/mr-image/mr-image/00180093>
- DICOM Standard Browser (Innolitics), MR Receive Coil Sequence (0018,9042) and
  Multi-Coil Definition Sequence (0018,9045) — confirms there is no channel-count
  attribute, only element enumeration.
  <https://dicom.innolitics.com/ciods/enhanced-mr-color-image/enhanced-mr-color-image-multi-frame-functional-groups/52009229/00189042>
- BIDS, Magnetic Resonance Imaging data — suffixes `T1w`/`T2w`/`PDw`/`FLAIR`/`dwi`,
  parametric `T1map`/`T2map`, entities `acq-`/`ce-`/`echo-`/`flip-`/`inv-`/`part-`.
  <https://bids-specification.readthedocs.io/en/stable/modality-specific-files/magnetic-resonance-imaging-data.html>
- BIDS BEP001 — the community DICOM crosswalk for Parallel Acquisition Technique
  (0018,9078) and Parallel Reduction Factor In-plane (0018,9069).
  <https://github.com/bids-standard/bep001/blob/master/src/04-modality-specific-files/01-magnetic-resonance-imaging-data.md>
- ISMRMRD schema `ismrmrd.xsd` — `trajectoryType` enumeration (`cartesian`, `epi`,
  `radial`, `goldenangle`, `spiral`, `other`), `sequenceParameters`,
  `acquisitionSystemInformation`, `measurementInformation`.
  <https://raw.githubusercontent.com/ismrmrd/ismrmrd/master/schema/ismrmrd.xsd>

Dataset publications (source of the per-source protocol facts — field strength, coil
counts, sequence names, sampling — that are not present in any committed CSV):

- fastMRI Breast — 288 spokes, base readout matrix 512, 83 partitions → 192 slices,
  16-channel breast coil, 3 T MAGNETOM TimTrio, golden-angle radial VIBE, partial
  Fourier 6/8. Nyquist spokes ≈ (π/2)·512 ≈ 804, hence net R ≈ 2.8.
  <https://pmc.ncbi.nlm.nih.gov/articles/PMC11791504/> ·
  <https://arxiv.org/abs/2406.05270>
- USC 75-speaker speech rtMRI (Lim et al., *Scientific Data* 2021) — "The 13 spiral
  interleaves, when collected together, fulfil the Nyquist sampling rate"; TR 6.004 ms,
  TE 0.8 ms, FOV 200×200 mm, slice 6 mm, matrix 84×84, flip angle 15°, 8-channel
  upper-airway array, 1.5 T GE Signa Excite.
  <https://www.nature.com/articles/s41597-021-00976-x>
- M4Raw (Lyu et al., *Scientific Data* 2023) — 0.3 T Oper-0.3 (Ningbo Xingaoyi),
  four-channel head coil, 18 axial slices, 5 mm thick, 0.94×1.23 mm in-plane, T1w/T2w
  TSE and FLAIR, 183 volunteers.
  <https://www.nature.com/articles/s41597-023-02181-4>

Three values are carried over from the pre-refactor labels and are **not** independently
confirmed against the challenge protocol / paper sequence tables: the CMRxRecon mapping
series' orientation, the CMRxRecon BlackBlood contrast weighting, and M4Raw's "T1 GRE"
label. Verify before relying on them for anything beyond cataloging.
