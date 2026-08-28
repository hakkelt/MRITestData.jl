# Controlled vocabularies for `DatasetEntry`'s `Symbol`-typed fields. Anchored in the
# DICOM standard where a term exists; see `docs/dev/taxonomy-refactor-plan.md` §5/§12 for
# the external references consulted and `docs/src/taxonomy.md` for the published mapping.
#
# `DatasetEntry`'s inner constructor validates every field below against its tuple, so a
# typo in a committed map fails at parse time instead of producing an entry nothing can
# ever match.

"""
    CONTRASTS

Controlled vocabulary for `DatasetEntry.contrast` — DICOM Acquisition Contrast
(0008,9209) defined terms (PS3.3 §C.8.13.3), lowercased snake_case. Proton density is a
contrast; cine/mapping/tagging/flow/black-blood are not — they are `sequence` /
`cardiac_sync` / `phase_contrast` / `blood_signal_nulling` instead.
"""
const CONTRASTS = (
    :t1, :t2, :t2_star, :proton_density, :diffusion, :fluid_attenuated,
    :perfusion, :stir, :tagging, :tof, :flow_encoded, :mixed, :unknown,
)

"""
    TRAJECTORIES

Controlled vocabulary for `DatasetEntry.trajectory` — the ISMRMRD `trajectoryType`
enumeration, verbatim (`ismrmrd.xsd`). An EXTENSION (no single DICOM attribute is this
expressive): strictly more expressive than DICOM's Geometry of k-Space Traversal
(0018,9032), which lacks EPI and golden-angle.
"""
const TRAJECTORIES = (:cartesian, :epi, :radial, :goldenangle, :spiral, :other, :unknown)

"""
    ANATOMIES

Controlled vocabulary for `DatasetEntry.anatomy` — DICOM Body Part Examined (0018,0015)
defined terms, lowercased (PS3.16 Annex L). `:other` covers mridata.org's open-ended
scraped anatomy text (hip, shoulder, spine, phantom, ...) that this package does not
curate a term for — distinct from `:unknown` (not recorded at all).
"""
const ANATOMIES = (
    :heart, :aorta, :brain, :knee, :breast, :prostate,
    :pharynx_larynx, :neck, :chest, :abdomen, :other, :unknown,
)

"""
    CARDIAC_SYNC

Controlled vocabulary for `DatasetEntry.cardiac_sync` — DICOM Cardiac Synchronization
Technique (0018,9037) defined terms (PS3.3 §C.7.6.18).
"""
const CARDIAC_SYNC = (:none, :realtime, :prospective, :retrospective, :paced)

"""
    FAT_SUPPRESSION

Controlled vocabulary for `DatasetEntry.fat_suppression` — DICOM Spectrally Selected
Suppression (0018,9025) defined terms.
"""
const FAT_SUPPRESSION = (:none, :fat, :water, :fat_and_water, :silicon_gel)

"""
    ECHO_TYPES

Controlled vocabulary for `DatasetEntry.echo_type` — DICOM Echo Pulse Sequence
(0018,9008) defined terms.
"""
const ECHO_TYPES = (:spin, :gradient, :both)

"""
    COIL_DATA

Controlled vocabulary for `DatasetEntry.coil_data` — DICOM Image Type (0008,0008) value
1, applied to the channel data. An EXTENSION (§4.1): no DICOM attribute counts receiver
channels, but ORIGINAL/DERIVED covers emulated/virtual coils.
"""
const COIL_DATA = (:original, :derived)

# ── Extensions (no DICOM anchor; see plan §4.2–4.6) ─────────────────────────────────

"""
    SPLITS

Controlled vocabulary for `DatasetEntry.split` — the ML-corpus partition. EXTENSION: not
an imaging concept, so DICOM has no attribute for it.
"""
const SPLITS = (:train, :val, :test, :demo)

"""
    COHORTS

Controlled vocabulary for `DatasetEntry.cohort` — EXTENSION: DICOM has no
research-subject-class attribute.
"""
const COHORTS = (:volunteer, :patient, :phantom)

"""
    UNDERSAMPLING_PATTERNS

Controlled vocabulary for `DatasetEntry.undersampling_pattern`. EXTENSION: DICOM's
Parallel Acquisition Technique (0018,9078) names the *reconstruction* (SENSE/GRAPPA), not
the sampling mask — VISTA, kt-Gaussian, kt-radial, Poisson-disc have no DICOM term.
"""
const UNDERSAMPLING_PATTERNS = (
    :uniform, :pseudo_random, :vista, :kt_gaussian,
    :kt_radial, :poisson_disc, :golden_angle,
)

"""
    ORIENTATIONS

Controlled vocabulary for `DatasetEntry.orientation`. Anchored on DICOM View Code
Sequence (0054,0220) as a container, but DICOM publishes no Context Group for cardiac
**MR** views (the cardiac view CIDs are echocardiography), so these are local symbols
(§4.6) rather than SNOMED codes. `:lvot` = left ventricular outflow tract.
"""
const ORIENTATIONS = (:axial, :sagittal, :coronal, :oblique, :short_axis, :long_axis, :lvot)

# `sequence` stays a `String`, spelled out, never abbreviated — Pulse Sequence Name
# (0018,9005). Examples: "balanced steady-state free precession", "spoiled gradient echo",
# "turbo spin echo", "echo-planar imaging", "MOLLI inversion recovery",
# "T2-prepared balanced SSFP", "radial VIBE (stack-of-stars)", "fast spin echo".
