# Refactor plan: DICOM-anchored dataset taxonomy

Status: proposed, not started.
Scope: `src/catalog/`, `src/download/`, `src/load/`, `src/browse.jl`, `data/*.csv`
headers, `test/`, `docs/`.

This document is **not** part of the Documenter build (it lives outside `docs/src/`).

---

## 1. Goal

Give `DatasetEntry` a single cross-source vocabulary whose field names, value
vocabularies and units are anchored in the DICOM standard, with a small, documented
set of extensions where DICOM has no term. Source-specific metadata stays queryable
but is named after its DICOM attribute keyword, and transport coordinates (byte
offsets, archive names) move out of the user-facing namespace entirely.

Three concrete payoffs beyond tidiness:

1. Cross-source queries stop silently lying (`subject` currently means two different
   things; `query(; subject = "patient")` is documented in `docs/src/usage.md` and is
   wrong for four of the seven sources).
2. The synthesized ISMRMRD headers in `src/load/cmrxrecon_ismrmrd.jl`,
   `m4raw_ismrmrd.jl` and `fastmri_ismrmrd.jl` can be populated from the catalog entry
   through one mapping table instead of per-converter hand-rolled XML.
3. Roughly 20 fields per entry that are currently `nothing` become populated from data
   already committed in `data/*.csv` or from each dataset's own publication.

## 2. Non-goals

- No change to the download engines' byte-level behaviour (zran, xz block index, ZIP
  range extraction). Only the *names* they read change.
- No re-indexing of any archive. Every new value is derived from committed map columns,
  from file paths already in those maps, or is a per-source constant from the dataset's
  publication. This matters: re-running `scripts/index_fastmri.jl` would require live
  fastMRI pre-signed URLs, which expire after 90 days.
- No reconstruction API. The package still stops at `RawAcquisitionData`.
- No SNOMED coding of `orientation` (see §4.6); local symbols only, for now.

## 3. Breaking changes

The package is unreleased, so no deprecation shims are planned.

| Removed / renamed | Replacement |
|---|---|
| `is3D::Union{Bool,Nothing}` | `acquisition_dim::Int` ∈ {1,2,3} (DICOM MR Acquisition Type) |
| `coils::Union{Int,Nothing}` | `receiver_channels::Union{Int,Nothing}` |
| `anatomy = :cardiac` | `anatomy = :heart` (DICOM Body Part Examined) |
| `anatomy = :vocal_tract` | `anatomy = :pharynx_larynx` (DICOM `PHARYNXLARYNX`) |
| `trajectory = :custom` | `trajectory = :other` (ISMRMRD `trajectoryType`) |
| `extra["modality"]` (all sources) | decomposed into `contrast`, `cardiac_sync`, `anatomy`, `orientation` |
| `extra["subject"]` | `subject_id` (CMRxRecon, USC) / `cohort` (OCMR) |
| `extra["set"]`, `extra["dataset_set"]`, `extra["split"]` | `split::Symbol` |
| `extra["study"]`, `extra["patient_id"]` | `subject_id::String` |
| `extra["contrast"]`, `extra["sequence"]` | `contrast::Symbol` + `sequence::String` |
| `extra["tr_ms"]`, `extra["te_ms"]`, `extra["flip_angle"]` | `extra["repetition_time_ms"]`, `["echo_time_ms"]`, `["flip_angle_deg"]` |
| `extra["fov_x"]`, `extra["fov_y"]` | `extra["reconstruction_fov_mm"]::NTuple{2,Float64}` |
| `extra["nx"]`, `extra["ny"]` | `extra["acquisition_matrix"]::NTuple{2,Int}` |
| `extra["nz"]`, `extra["slices"]` | `num_slices::Union{Int,Nothing}` |
| `extra["nt"]` | `num_frames::Union{Int,Nothing}` |
| `extra["hardware_coils"]` | `extra["multi_coil_elements"]` |
| `extra["coil_type"]` | `receiver_channels` + `coil_data::Symbol` |
| `extra["sampling"]` | `fully_sampled::Bool` + `undersampling_pattern::Union{Symbol,Nothing}` |
| `extra["view"]` | `orientation::Union{Symbol,Nothing}` |
| `extra["echo"]` (asy/sym) | `partial_fourier::Union{Bool,Nothing}` + `extra["partial_fourier_direction"]` |
| `extra["stimulus"]`, mridata `protocol` | `extra["protocol_name"]` |
| `extra["repetition"]` | `repetition::Union{Int,Nothing}` |
| all byte offsets / archive names in `extra` | new `locator::Dict{String,Any}` field |

## 4. New field set

`DatasetEntry` after the refactor. Every field carries its DICOM anchor in the
docstring; the seven extensions are flagged.

```julia
Base.@kwdef struct DatasetEntry
    # ── identity ────────────────────────────────────────────────────────────
    source::AbstractSource
    id::String
    name::String                                        # Series Description (0008,103E)

    # ── subject ─────────────────────────────────────────────────────────────
    subject_id::Union{String, Nothing}  = nothing       # Clinical Trial Subject ID (0012,0040)
    cohort::Union{Symbol, Nothing}      = nothing       # EXTENSION: :volunteer/:patient/:phantom
    split::Union{Symbol, Nothing}       = nothing       # EXTENSION: :train/:val/:test/:demo
    repetition::Union{Int, Nothing}     = nothing       # Acquisition Number (0020,0012)

    # ── system ──────────────────────────────────────────────────────────────
    vendor::Union{Symbol, Nothing}        = nothing     # Manufacturer (0008,0070)
    scanner_model::Union{String, Nothing} = nothing     # Manufacturer Model Name (0008,1090)
    institution::Union{String, Nothing}   = nothing     # Institution Name (0008,0080)
    field_strength::Union{Float64, Nothing} = nothing   # Magnetic Field Strength (0018,0087), T
    receiver_channels::Union{Int, Nothing}  = nothing   # EXTENSION (see §4.1)
    coil_data::Symbol = :original                       # Image Type value 1 (0008,0008)

    # ── what was imaged ─────────────────────────────────────────────────────
    anatomy::Symbol   = :unknown                        # Body Part Examined (0018,0015)
    contrast::Symbol  = :unknown                        # Acquisition Contrast (0008,9209)
    orientation::Union{Symbol, Nothing} = nothing       # View Code Sequence (0054,0220), see §4.6
    sequence::Union{String, Nothing}    = nothing       # Pulse Sequence Name (0018,9005)
    echo_type::Union{Symbol, Nothing}   = nothing       # Echo Pulse Sequence (0018,9008)
    quantitative::Bool = false                          # EXTENSION (Parametric Map SOP class)

    # ── acquisition geometry ────────────────────────────────────────────────
    acquisition_dim::Int = 2                            # MR Acquisition Type (0018,0023)
    num_slices::Union{Int, Nothing}  = nothing          # Number of Frames (0028,0008)
    num_frames::Union{Int, Nothing}  = nothing          # Cardiac Number of Images (0018,1090)
    num_averages::Union{Int, Nothing} = nothing         # Number of Averages (0018,0083)

    # ── sampling ────────────────────────────────────────────────────────────
    trajectory::Symbol = :unknown                       # ISMRMRD trajectoryType, see §4.9
    fully_sampled::Union{Bool, Nothing} = nothing       # Percent Sampling (0018,0093) == 100
    acceleration::Union{Float64, Nothing} = nothing     # EXTENSION: net R, see §4.10
    undersampling_pattern::Union{Symbol, Nothing} = nothing  # EXTENSION, see §4.5
    partial_fourier::Union{Bool, Nothing} = nothing     # Partial Fourier (0018,9081)
    has_acs::Bool = false                               # Parallel Acquisition (0018,9077)

    # ── cardiac / contrast-agent flags ──────────────────────────────────────
    cardiac_sync::Symbol = :none                        # Cardiac Sync Technique (0018,9037)
    phase_contrast::Bool = false                        # Phase Contrast (0018,9014)
    blood_signal_nulling::Bool = false                  # Blood Signal Nulling (0018,9022)
    fat_suppression::Union{Symbol, Nothing} = nothing   # Spectrally Sel. Suppression (0018,9025)
    contrast_agent::Union{Bool, Nothing} = nothing      # Contrast/Bolus Agent (0018,0010)

    # ── transport (non-DICOM) ───────────────────────────────────────────────
    file_format::Symbol = :ismrmrd                      # :ismrmrd / :fastmri_h5 / :matlab_v73
    approx_size_bytes::Union{Int, Nothing} = nothing
    sha256::Union{String, Nothing} = nothing
    url::String = ""

    extra::Dict{String, Any}   = Dict{String, Any}()    # DICOM-named, source-specific
    locator::Dict{String, Any} = Dict{String, Any}()    # byte coordinates; never displayed
end
```

### 4.1–4.10 Extension rationale

Each extension exists because DICOM has no attribute for the concept. The numbering
matches the review that produced this plan; keep it stable when editing.

- **4.1 `receiver_channels`** — DICOM enumerates coil elements in Multi-Coil Definition
  Sequence (0018,9045) with Multi-Coil Element Used (0018,9048); there is no count
  attribute. Anchor on ISMRMRD `acquisitionSystemInformation/receiverChannels`, which
  is what `load_raw` emits anyway. Document as "count of used multi-coil elements".
- **4.2 `split`** — ML-corpus partition, not an imaging concept.
- **4.3 `cohort`** — no DICOM research-subject-class attribute.
- **4.5 `undersampling_pattern`** — Parallel Acquisition Technique (0018,9078) names the
  *reconstruction* (SENSE/SMASH/GRAPPA), not the sampling mask. VISTA, kt-Gaussian,
  kt-radial, Poisson-disc have no term.
- **4.6 `orientation`** — View Code Sequence (0054,0220) is the right container and takes
  SNOMED codes, but DICOM publishes no Context Group for cardiac **MR** views (the
  cardiac view CIDs are echocardiography). Local symbols for now; SNOMED coding is a
  later refinement, and codes must not be invented.
- **4.7 `quantitative`** — DICOM's anchor is the Parametric Map Storage SOP class, an
  object type rather than an attribute. BIDS `T1map`/`T2map` suffix is the practical
  equivalent.
- **4.9 `trajectory`** — Geometry of k-Space Traversal (0018,9032) offers only
  `RECTILINEAR`/`RADIAL`/`SPIRAL`; EPI lives in Scanning Sequence (`EP`) and
  golden-angle is a radial *ordering* with no term. ISMRMRD's enum is strictly more
  expressive and is the package's output format. Ship a crosswalk in the docstring.
- **4.10 `acceleration`** — Parallel Reduction Factor In-plane (0018,9069) is in-plane
  and parallel-imaging-specific. `acceleration` is *net* R, defined at the source's
  native frame binning; that qualifier matters for golden-angle and real-time data
  (see §6 fastMRI breast and USC). Keep the DICOM value, when known, as
  `extra["parallel_reduction_factor_in_plane"]`.

`fully_sampled` is **not** an extension: it is Percent Sampling (0018,0093) `== 100`.
The boolean is kept for query ergonomics; the docstring must state the equivalence.

## 5. Controlled vocabularies

New file `src/catalog/taxonomy.jl`, included first in `MRITestData.jl` so the parsers
and the `DatasetEntry` inner constructor can both see it.

```julia
# DICOM Acquisition Contrast (0008,9209) defined terms, lowercased.
const CONTRASTS = (:t1, :t2, :t2_star, :proton_density, :diffusion, :fluid_attenuated,
                   :perfusion, :stir, :tagging, :tof, :mixed, :unknown)

# ISMRMRD trajectoryType enumeration, verbatim.
const TRAJECTORIES = (:cartesian, :epi, :radial, :goldenangle, :spiral, :other, :unknown)

# DICOM Body Part Examined (0018,0015) defined terms, lowercased.
const ANATOMIES = (:heart, :aorta, :brain, :knee, :breast, :prostate,
                   :pharynx_larynx, :neck, :chest, :abdomen, :unknown)

# DICOM Cardiac Synchronization Technique (0018,9037).
const CARDIAC_SYNC = (:none, :realtime, :prospective, :retrospective, :paced)

# DICOM Spectrally Selected Suppression (0018,9025).
const FAT_SUPPRESSION = (:none, :fat, :water, :fat_and_water, :silicon_gel)

# DICOM Echo Pulse Sequence (0018,9008).
const ECHO_TYPES = (:spin, :gradient, :both)

# DICOM Image Type (0008,0008) value 1, applied to the channel data.
const COIL_DATA = (:original, :derived)

# Extensions (§4.2, §4.3, §4.5, §4.6).
const SPLITS = (:train, :val, :test, :demo)
const COHORTS = (:volunteer, :patient, :phantom)
const UNDERSAMPLING_PATTERNS = (:uniform, :pseudo_random, :vista, :kt_gaussian,
                                :kt_radial, :poisson_disc, :golden_angle)
const ORIENTATIONS = (:axial, :sagittal, :coronal, :oblique,
                      :short_axis, :long_axis, :lvot)  # LVOT = left ventricular outflow tract
```

`sequence` stays a `String`, spelled out, never abbreviated: `"balanced steady-state
free precession"`, `"spoiled gradient echo"`, `"turbo spin echo"`, `"echo-planar
imaging"`, `"MOLLI inversion recovery"`, `"T2-prepared balanced SSFP"`,
`"radial VIBE (stack-of-stars)"`, `"fast spin echo"`.

An inner constructor validates every `Symbol`-typed field against its tuple and throws
on an unknown value, so a typo in a committed map fails at parse time instead of
producing an entry nothing can ever match.

## 6. Per-source derivations

Full provenance table. Confidence: **map** = already in a committed `data/*.csv`;
**pub** = stated in the dataset's own publication (see §12); **protocol** = fixed by the
acquisition protocol for the whole source.

| Source · selector | Assignments | Conf. |
|---|---|---|
| **all** | `anatomy = :heart` for OCMR/CMRxRecon (was `:cardiac`) | — |
| CMRx24 `cine_sax/lax/lvot` | `contrast=:mixed`, `sequence="balanced steady-state free precession"`, `orientation=:short_axis`/`:long_axis`/`:lvot`, `cardiac_sync=:retrospective`, `num_frames=nt` | map |
| CMRx24 `T1map` | `contrast=:t1`, `quantitative=true`, `sequence="MOLLI inversion recovery"`, `orientation=:short_axis` ¹ | pub |
| CMRx24 `T2map` | `contrast=:t2`, `quantitative=true`, `sequence="T2-prepared balanced SSFP"`, `orientation=:short_axis` ¹ | pub |
| CMRx24 `tagging` | `contrast=:tagging`, `sequence="tagged cine (SPAMM)"`, `cardiac_sync=:retrospective` | pub |
| CMRx24 `flow2d` | `contrast=:flow_encoded`, `phase_contrast=true` | pub |
| CMRx24 `blackblood` | `blood_signal_nulling=true`, `sequence="dark-blood turbo spin echo"`, `contrast=:unknown` ¹ | pub |
| CMRx24 `aorta_sag/tra` | **`anatomy=:aorta`**, `contrast=:mixed`, `orientation=:sagittal`/`:axial` | map |
| CMRx24 all | `receiver_channels = 10` (multi) / `1` (single), `coil_data=:derived` (SVD), `extra["multi_coil_elements"]=hardware_coils`, `num_slices=nz`, `acquisition_matrix=(nx,ny)`, `repetition_time_ms`, `echo_time_ms`, `flip_angle_deg`, `reconstruction_fov_mm` | map |
| CMRx300 `Cine SAX/LAX` | `contrast=:mixed`, `orientation=:short_axis`/`:long_axis`, `sequence="balanced steady-state free precession"`, `cardiac_sync=:retrospective` | map |
| CMRx300 `T1map`/`T2map` | `contrast=:t1`/`:t2`, `quantitative=true` | map |
| CMRx300 all | `receiver_channels = 30`, `acceleration = 3.0`, `undersampling_pattern=:uniform`, `has_acs=true`, `cohort=:volunteer`, `fully_sampled=false` | pub |
| fastMRI knee | `contrast=:proton_density`, `orientation=:coronal`, `sequence="fast spin echo"`, `vendor=:siemens` | pub |
| fastMRI `AXT1`/`AXT1PRE` | `contrast=:t1`, `orientation=:axial`, `contrast_agent=false` | map (filename) |
| fastMRI `AXT1POST` | `contrast=:t1`, `orientation=:axial`, `contrast_agent=true` | map (filename) |
| fastMRI `AXT2` | `contrast=:t2`, `orientation=:axial` | map (filename) |
| fastMRI `AXFLAIR` | `contrast=:fluid_attenuated`, `orientation=:axial` | map (filename) |
| fastMRI prostate `T2`/`DIFF` | `contrast=:t2`/`:diffusion`, `sequence="turbo spin echo"`/`"echo-planar imaging"`, `orientation=:axial`, `num_averages` set for DIFF | map |
| fastMRI breast | `trajectory=:goldenangle`, `acquisition_dim=3`, `receiver_channels=16`, `vendor=:siemens`, `scanner_model="Siemens MAGNETOM TimTrio"`, `field_strength=3.0`, `num_slices=192`, `contrast=:t1`, `sequence="radial VIBE (stack-of-stars)"`, `fully_sampled=false`, `acceleration≈2.8`, `partial_fourier=true` | pub |
| fastMRI split | `split` from column; **`fully_sampled = split != :test`** (fixes the bug in §7.1) | map |
| fastMRI coil format | `receiver_channels` unset; `coil_data = :derived` for `singlecoil` (emulated), `:original` otherwise | map |
| M4Raw `T1`/`T2` | `contrast=:t1`/`:t2`, `sequence="turbo spin echo"` | pub |
| M4Raw `FLAIR` | `contrast=:fluid_attenuated`, `sequence="turbo spin echo (inversion-recovery prepared)"` | pub |
| M4Raw `GRE` | `contrast=:t1` ¹, `sequence="spoiled gradient echo"`, `echo_type=:gradient` | pub |
| M4Raw all | `orientation=:axial`, `num_slices=18`, `receiver_channels=4`, `cohort=:volunteer`, **`vendor=:ningbo_xingaoyi`**, `scanner_model="Oper-0.3"` | pub |
| USC all | `anatomy=:pharynx_larynx`, `orientation=:sagittal`, `sequence="spoiled gradient echo (13-interleaf spiral-out)"`, `echo_type=:gradient`, **`fully_sampled=true`** (13 interleaves reach Nyquist), `cohort=:volunteer`, `extra`: `repetition_time_ms=6.004`, `echo_time_ms=0.8`, `flip_angle_deg=15`, `reconstruction_fov_mm=(200,200)`, `acquisition_matrix=(84,84)`, `slice_thickness_mm=6` | pub |
| OCMR | `anatomy=:heart`, `orientation` from decoded `viw`, `partial_fourier` from `ech`, `cohort` from `sub`, `num_slices` from `slices`, `vendor=:siemens` default | map |
| mridata | `acquisition_dim` and `anatomy` parsed from the scraped title (`"3D FSE knee"`, `"2D Cartesian brain/body"`) | map |

¹ Verify against the challenge protocol before committing. The CMRxRecon mapping-series
orientation, the black-blood weighting, and M4Raw's "T1 GRE" label are the three values
this plan does **not** consider settled.

## 7. Phases

### Phase 0 — vocabulary and mapping table (no behaviour change)

- New `src/catalog/taxonomy.jl`: the constants of §5.
- New `src/catalog/dicom_map.jl`: `const DICOM_ATTRIBUTES::Dict{Symbol,Tuple{UInt16,UInt16,String}}`
  plus `dicom_tag(field) -> Union{Tuple,Nothing}` and `dicom_keyword(field)`.
  Covers core fields **and** the `extra` keys of §8. Extensions map to `nothing` and
  are listed in a companion `const TAXONOMY_EXTENSIONS` with a one-line justification
  each, so the docs table (§11) can be generated rather than hand-maintained.
- `include` both at the top of `src/MRITestData.jl`, before `catalog/catalog.jl`.
- Export `dicom_tag`; add to `docs/src/api.md`.

### Phase 1 — fastMRI map column fix

The `coils` column of `data/fastmri_map.csv` is the middle token of the archive name,
not a coil count: `knee_singlecoil_train` → `singlecoil`, but
`fastMRI_prostate_T2_IDS_001_020.tar.gz` → `T2`. `tryparse(Int, …)` therefore returns
`nothing` on all 8618 rows, and the column is not copied into `extra`, so the
singlecoil/multicoil distinction is currently absent from the catalog entirely.

- Rename the CSV header `coils` → `series_variant` (one-line edit of the committed
  file; no re-indexing, no fastMRI credentials needed).
- `scripts/fastmri_common.jl` and `scripts/index_fastmri*.jl`: emit the new header, and
  add a comment stating what the column actually holds.
- Parser reads `series_variant` and dispatches: `singlecoil`/`multicoil` →
  `coil_data`; `T2`/`DIFF` → `contrast` + `sequence`.

### Phase 2 — `DatasetEntry` restructure

- `src/catalog/catalog.jl`: new field list (§4), inner constructor validation,
  `locator` field.
- Replace `_with_size` (currently transcribes all 14 fields by hand and will silently
  drop any new one) with a generic
  `_with(e::DatasetEntry; kw...)` built over `fieldnames(DatasetEntry)`.
- `_zip_span_extra` → `_zip_span_locator`; every `extra[...] = <byte offset>` in the
  five map-backed parsers moves to `locator[...]`.
- `src/download/*_fetch.jl` and `src/load/cmrxrecon_ismrmrd.jl` read `e.locator`
  instead of `e.extra` (mechanical; the key names do not change).

### Phase 3 — per-source parsers

Apply §6 in `ocmr_catalog.jl`, `mridata_catalog.jl`, `cmrxrecon2024_catalog.jl`,
`cmrxrecon300_catalog.jl`, `m4raw_catalog.jl`, `usc_speech_catalog.jl`,
`fastmri_catalog.jl`. Two shared helpers to avoid seven copies:

- `_normalize_split(s)` — handles `train`/`multicoil_train`/`TrainingSet`/`DemoData`/`gre`.
- `_cardiac_series(stem)` — maps a CMRxRecon file stem or CMRxRecon-300 `modality`
  string to `(contrast, orientation, sequence, quantitative, flags...)`.

Also in this phase: add `_OCMR_VIEW` decode table (the only coded OCMR column still
passed through raw, `ocmr_catalog.jl:89`) and extend `_OCMR_SLICEMODE` with `"mul"`.

### Phase 4 — query API

- `src/catalog/query.jl`: keyword validation. An unknown keyword currently falls
  through to `extra` matching, so `query(; anatomi = :knee)` returns `[]` instead of
  erroring. Validate against `fieldnames(DatasetEntry)` ∪ `extra_schema(source)` for
  the queried sources; `@warn` by default, `error` under `strict = true`.
- New `extra_schema(source) -> Dict{String,String}` declared beside each parser
  (key → one-line description). Feeds the validation, the TUI details pane and the
  generated docs table.
- `_matches_text` searches `name`, `id` and `extra` only — never `locator`. This fixes
  free-text hits on archive paths (`query(; text = "train")` currently matches the
  `multicoil_train` archive name of every M4Raw entry).

### Phase 5 — display and browser

- `src/catalog/display.jl`: delete `_coils_value` (the `Int`-or-`String` cell that makes
  the `Coils` column sort lexicographically, `"10ch" < "8ch"`); `receiver_channels` is
  always `Int`. `_sampling_value` loses the `replace(pat, " undersampled" => "")` hack
  now that `undersampling_pattern` is a `Symbol`.
- `src/browse.jl` columns: `# | Source | ID | Anatomy | Contrast | B₀ [T] | Trajectory |
  Channels | Sampling | R | Frames | Split | Cached | Size`.
  - `Cached` — ✓ when the file is already in the Scratch cache. Local check, no network,
    and the single highest-value column for day-to-day use.
  - `R` — `acceleration`, blank when fully sampled.
- Details pane for the selected row: every `extra` key with its `extra_schema`
  description and its query keyword, so `extra` filtering stops being guess-and-check.
- Source-adaptive columns: when the filter narrows to one source, append that source's
  `extra_schema` highlight keys.

### Phase 6 — loaders

`src/load/cmrxrecon_ismrmrd.jl`, `m4raw_ismrmrd.jl`, `fastmri_ismrmrd.jl` populate the
synthesized ISMRMRD XML from the entry via `dicom_map.jl`:
`acquisitionSystemInformation` (vendor, model, institution, field strength,
receiver channels), `sequenceParameters` (TR/TE/flip angle/sequence type),
`encoding/trajectory`, `measurementInformation/protocolName`. Where the entry has
`nothing`, keep the current fallback so no file stops loading.

### Phase 7 — tests

- `test/test_catalog.jl` — vocabulary validation: every entry of every source has
  `anatomy ∈ ANATOMIES`, `contrast ∈ CONTRASTS`, `trajectory ∈ TRAJECTORIES`, etc.
  This is the regression net for the committed maps and runs offline.
- New `test/test_taxonomy.jl` — `dicom_tag` coverage: every core field is either in
  `DICOM_ATTRIBUTES` or in `TAXONOMY_EXTENSIONS`, never both, never neither.
- `test/test_query.jl` — unknown-keyword warning; `extra` text search does not reach
  `locator`; `subject_id` vs `cohort` disambiguation across sources.
- `test/test_fastmri.jl` — `coil_data == :derived` for singlecoil; prostate `contrast`;
  brain contrast from filename for all five tokens; **`fully_sampled == false` for the
  `test` split** (§7.1 regression).
- `test/test_browse.jl` — new column count and the `Cached` cell.
- Update `test_m4raw.jl`, `test_usc_speech.jl`, `test_cmrxrecon2024.jl`,
  `test_cmrxrecon300.jl`, `test_download_real.jl` for renamed fields.
- Aqua/JET stay offline (`offline = true`), unchanged.

#### 7.1 Correctness fix carried by this refactor

`fastmri_catalog.jl:72` sets `is_fully_sampled = anatomy !== :prostate`, so all 1342
knee/brain `test`-split entries claim `fully_sampled = true` while being prospectively
undersampled (`docs/src/datasets.md:299` already says so, and those files ship a `mask`).
Fix is exact, from the `split` column.

### Phase 8 — documentation

- `docs/src/api.md` — new `## Taxonomy` section: `dicom_tag`, the vocabulary constants,
  `extra_schema`. `checkdocs = :public` is on, so every newly exported name needs a
  docstring in the same commit.
- `docs/src/usage.md` — rewrite the query examples. `query(; subject = "patient")`
  (line 58) is currently wrong for four sources; it becomes
  `query(; cohort = :volunteer)`. Add examples for `contrast`, `split`, `acceleration`.
  Document the `missing`/`nothing` distinction against the new fields.
- `docs/src/datasets.md` — the `extra` key tables per source become a single generated
  table of core-field values per source plus the source's `extra_schema`. Update the
  OCMR coded-metadata table (`view` is now decoded), the CMRxRecon "Modalities" tables
  (they document a key that no longer exists), the fastMRI per-anatomy table
  (`entry.is3D` → `acquisition_dim`, add the breast R ≈ 2.8 and the corrected
  test-split sampling), the M4Raw table (named scanner), and the USC section
  (`fully_sampled` is now `true`, with the 13-interleaf Nyquist note).
  Update the "Quick cross-source summary" table at the end.
- `docs/src/index.md` — the feature bullets mention `coils`/`fully_sampled`; retitle.
- `README.md` — same field renames in the example block.
- New `docs/src/taxonomy.md`, added to `docs/make.jl` `pages`: the DICOM mapping table
  (§4, §8), the seven extensions with their justification (§4.1–4.10), the ISMRMRD
  trajectory crosswalk, and the reference list of §12. This is the page that makes the
  extensions defensible to an outside reader.
- `examples/reconstruct_all_types.jl` and `docs/generate_recon_images.jl` use
  `fully_sampled`/`coils`; update.
- `scripts/README.md` — document the `series_variant` column rename.

## 8. `extra` key renames (DICOM keyword, snake_case, unit-suffixed)

| Source | Now | New | DICOM anchor |
|---|---|---|---|
| CMRx24 | `tr_ms` | `repetition_time_ms` | Repetition Time (0018,0080) |
| CMRx24 | `te_ms` | `echo_time_ms` | Echo Time (0018,0081) |
| CMRx24 | `flip_angle` | `flip_angle_deg` | Flip Angle (0018,1314) |
| CMRx24 | `fov_x`,`fov_y` | `reconstruction_fov_mm` | Reconstruction FOV (0018,9317) |
| CMRx24 | `nx`,`ny` | `acquisition_matrix` | Acquisition Matrix (0018,1310) |
| CMRx24 | `hardware_coils` | `multi_coil_elements` | (0018,9045) item count |
| CMRx24 | `field_strength` | → core | (0018,0087) |
| OCMR | `scanner_model` | → core | (0008,1090) |
| OCMR | `duration` | `acquisition_duration_class` | Acquisition Duration (0018,9073) |
| OCMR | `slice_mode` | `slice_mode` (kept) | EXTENSION |
| OCMR | `fov` (ali/noa) | `phase_wrap`::Bool | EXTENSION, near (0018,0094) |
| OCMR | `echo` | `partial_fourier_direction` | (0018,9036) |
| USC | `stimulus` | `protocol_name` | Protocol Name (0018,1030) |
| mridata | `protocol` | `protocol_name` | Protocol Name (0018,1030) |
| mridata | `institution` | → core | (0008,0080) |
| mridata | `download count` | `provenance_download_count` | non-imaging |

`Modality (0008,0060)` is `MR` for every entry in the package — a constant, stored
nowhere. That is the second reason to retire the `modality` key: the name is taken by
DICOM and means something else.

## 9. `locator` contents (explicitly non-DICOM, never searched or displayed)

`path`, `archive`, `file_id`, `mat_file`, `file_name`, `start_off`, `end_off`,
`lfh_size`, `compressed_size`, `uncompressed_size`, `compression`, `start_frag`,
`end_frag`, `tar_data_offset`, `file_size`, `data_offset`, `size`, `calib_path`,
`calib_data_offset`, `calib_size`.

`url`, `sha256` and `approx_size_bytes` stay as core fields (they are part of the
public download contract and `approx_size_bytes` drives the `max_bytes` guard) but are
documented as transport, not DICOM.

## 10. Blast radius

Files touching the renamed fields, from `grep`:

- `is3D` — 10 `.jl`, `docs/src/datasets.md`, `data/mridata_index.toml`, 3 test files.
- `coils` — 18 `.jl` (incl. `scripts/`), 4 docs pages, `README.md`, `examples/`, 3 tests.
- `fully_sampled` — 12 `.jl`, 3 docs pages, `README.md`, `examples/`, 7 tests.
- `extra[` — 12 `.jl`, 4 tests.

`data/mridata_index.toml` uses `is3D`/`coils` as TOML keys and must be rewritten in
Phase 2 together with `_MRIDATA_NAMED_FIELDS` in `mridata_catalog.jl`.

Run `runic --inplace .` before finishing, per `CLAUDE.md`.

## 11. Suggested commit sequence

1. `feat(catalog): add DICOM-anchored taxonomy vocabularies and attribute map` (Phase 0)
2. `fix(fastmri): the map's coils column holds an archive token, not a coil count` (Phase 1)
3. `refactor(catalog): split DatasetEntry into core, extra and locator namespaces` (Phase 2)
4. `feat(catalog): derive DICOM-mapped metadata for every source` (Phase 3)
5. `fix(fastmri): test-split data is prospectively undersampled` (Phase 7.1, can precede 4)
6. `feat(query): validate filter keywords and expose extra_schema` (Phase 4)
7. `feat(browse): contrast, R, frames, split and cached columns plus a details pane` (Phase 5)
8. `feat(load): populate ISMRMRD headers from the catalog entry` (Phase 6)
9. `test(catalog): vocabulary and DICOM-coverage regression tests` (Phase 7)
10. `docs: document the taxonomy and its DICOM anchors` (Phase 8)

## 12. External references consulted

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
- DICOM PS3.16 Annex L, Correspondence of Anatomic Region Codes and Body Part Examined
  — verified terms `HEART`, `AORTA`, `BRAIN`, `KNEE`, `BREAST`, `PROSTATE`,
  `PHARYNXLARYNX`, `LARYNX`, `TONGUE`, `NECK`.
  <https://dicom.nema.org/medical/dicom/current/output/chtml/part16/chapter_L.html>
- DICOM Standard Browser (Innolitics), Acquisition Contrast (0008,9209).
  <https://dicom.innolitics.com/ciods/enhanced-mr-image/enhanced-mr-image/00089209>
- DICOM Standard Browser (Innolitics), Percent Sampling (0018,0093) — "the fraction of
  acquisition matrix lines acquired, expressed as a percent"; the anchor for
  `fully_sampled`. <https://dicom.innolitics.com/ciods/mr-image/mr-image/00180093>
- DICOM Standard Browser (Innolitics), MR Receive Coil Sequence (0018,9042) and
  Multi-Coil Definition Sequence (0018,9045) — confirms there is no channel-count
  attribute, only element enumeration (§4.1).
  <https://dicom.innolitics.com/ciods/enhanced-mr-color-image/enhanced-mr-color-image-multi-frame-functional-groups/52009229/00189042>
- BIDS, Magnetic Resonance Imaging data — suffixes `T1w`/`T2w`/`PDw`/`FLAIR`/`dwi`,
  parametric `T1map`/`T2map`, entities `acq-`/`ce-`/`echo-`/`flip-`/`inv-`/`part-`.
  <https://bids-specification.readthedocs.io/en/stable/modality-specific-files/magnetic-resonance-imaging-data.html>
- BIDS BEP001 — the community DICOM crosswalk for Parallel Acquisition Technique
  (0018,9078) and Parallel Reduction Factor In-plane (0018,9069).
  <https://github.com/bids-standard/bep001/blob/master/src/04-modality-specific-files/01-magnetic-resonance-imaging-data.md>
- ISMRMRD schema `ismrmrd.xsd` — `trajectoryType` enumeration
  (`cartesian`, `epi`, `radial`, `goldenangle`, `spiral`, `other`),
  `sequenceParameters`, `acquisitionSystemInformation`, `measurementInformation`.
  <https://raw.githubusercontent.com/ismrmrd/ismrmrd/master/schema/ismrmrd.xsd>

Dataset publications (source of the "pub" rows in §6):

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
- Existing in-repo documentation used as a source for the CMRxRecon and OCMR rows:
  `docs/src/datasets.md` (channel counts, R ≈ 3 for CMRxRecon-300, modality tables,
  the already-documented fact that the fastMRI test splits are undersampled).

## 13. Open questions

1. The three ¹-flagged values in §6 (CMRxRecon mapping-series orientation, black-blood
   weighting, M4Raw "T1 GRE") need confirmation against the challenge protocol and the
   M4Raw paper's sequence table before they are committed.
2. `acceleration` for the fastMRI knee/brain `test` splits is R = 4 or 8 per file, held
   only in each file's `mask`. Left `nothing`; populating it would require reading every
   archive member, which contradicts the no-re-indexing constraint.
3. Whether `orientation` should eventually carry SNOMED codes in a
   `View Code Sequence`-shaped `NamedTuple` rather than a bare `Symbol`.
