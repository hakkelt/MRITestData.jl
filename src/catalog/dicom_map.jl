# DICOM attribute anchors for `DatasetEntry`'s core fields and its DICOM-keyword-named
# `extra` keys. Data-driven so the ISMRMRD-header synthesis in `src/load/*_ismrmrd.jl`
# can be built from one table instead of per-converter hand-rolled XML, and so the
# generated docs table (`docs/src/taxonomy.md`) does not have to be hand-maintained.
#
# Extensions (fields with no DICOM attribute) map to `nothing` here and are listed with
# their one-line justification in `TAXONOMY_EXTENSIONS` — see plan §4.1–4.10.

"""
    DICOM_ATTRIBUTES

`Dict{Symbol,Tuple{UInt16,UInt16,String}}` mapping a [`DatasetEntry`](@ref) core field, or
a DICOM-keyword-named `extra` key (as a `Symbol`), to its `(group, element, keyword)` DICOM
attribute. Fields with no DICOM anchor are omitted here — see [`TAXONOMY_EXTENSIONS`](@ref).
"""
const DICOM_ATTRIBUTES = Dict{Symbol, Tuple{UInt16, UInt16, String}}(
    # core fields
    :name => (0x0008, 0x103E, "SeriesDescription"),
    :subject_id => (0x0012, 0x0040, "ClinicalTrialSubjectID"),
    :repetition => (0x0020, 0x0012, "AcquisitionNumber"),
    :vendor => (0x0008, 0x0070, "Manufacturer"),
    :scanner_model => (0x0008, 0x1090, "ManufacturerModelName"),
    :institution => (0x0008, 0x0080, "InstitutionName"),
    :field_strength => (0x0018, 0x0087, "MagneticFieldStrength"),
    :coil_data => (0x0008, 0x0008, "ImageType"),
    :anatomy => (0x0018, 0x0015, "BodyPartExamined"),
    :contrast => (0x0008, 0x9209, "AcquisitionContrast"),
    :orientation => (0x0054, 0x0220, "ViewCodeSequence"),
    :sequence => (0x0018, 0x9005, "PulseSequenceName"),
    :echo_type => (0x0018, 0x9008, "EchoPulseSequence"),
    :acquisition_dim => (0x0018, 0x0023, "MRAcquisitionType"),
    :num_slices => (0x0028, 0x0008, "NumberOfFrames"),
    :num_frames => (0x0018, 0x1090, "CardiacNumberOfImages"),
    :num_averages => (0x0018, 0x0083, "NumberOfAverages"),
    :fully_sampled => (0x0018, 0x0093, "PercentSampling"),
    :partial_fourier => (0x0018, 0x9081, "PartialFourier"),
    :has_acs => (0x0018, 0x9077, "ParallelAcquisition"),
    :cardiac_sync => (0x0018, 0x9037, "CardiacSynchronizationTechnique"),
    :phase_contrast => (0x0018, 0x9014, "PhaseContrast"),
    :blood_signal_nulling => (0x0018, 0x9022, "BloodSignalNulling"),
    :fat_suppression => (0x0018, 0x9025, "SpectrallySelectedSuppression"),
    :contrast_agent => (0x0018, 0x0010, "ContrastBolusAgent"),
    # DICOM-keyword-named `extra` keys (see plan §8)
    :repetition_time_ms => (0x0018, 0x0080, "RepetitionTime"),
    :echo_time_ms => (0x0018, 0x0081, "EchoTime"),
    :flip_angle_deg => (0x0018, 0x1314, "FlipAngle"),
    :reconstruction_fov_mm => (0x0018, 0x9317, "ReconstructionFieldOfView"),
    :acquisition_matrix => (0x0018, 0x1310, "AcquisitionMatrix"),
    :multi_coil_elements => (0x0018, 0x9045, "MultiCoilDefinitionSequence"),
    :acquisition_duration_class => (0x0018, 0x9073, "AcquisitionDuration"),
    :partial_fourier_direction => (0x0018, 0x9036, "PartialFourierDirection"),
    :protocol_name => (0x0018, 0x1030, "ProtocolName"),
    :parallel_reduction_factor_in_plane => (0x0018, 0x9069, "ParallelReductionFactorInPlane"),
)

"""
    dicom_tag(field::Symbol) -> Union{Tuple{UInt16,UInt16,String},Nothing}

The `(group, element, keyword)` DICOM attribute anchoring `field`, or `nothing` when
`field` is an [`TAXONOMY_EXTENSIONS`](@ref) extension with no DICOM equivalent.
"""
dicom_tag(field::Symbol) = get(DICOM_ATTRIBUTES, field, nothing)

"""
    dicom_keyword(field::Symbol) -> Union{String,Nothing}

The DICOM keyword for `field` (e.g. `:field_strength` → `"MagneticFieldStrength"`), or
`nothing` when `field` has no DICOM anchor.
"""
function dicom_keyword(field::Symbol)
    tag = dicom_tag(field)
    return tag === nothing ? nothing : tag[3]
end

"""
    TAXONOMY_EXTENSIONS

`Dict{Symbol,String}` mapping each field that has **no** DICOM attribute to a one-line
justification. See `docs/src/taxonomy.md` and plan §4.1–4.10 for the full rationale.
"""
const TAXONOMY_EXTENSIONS = Dict{Symbol, String}(
    :cohort => "no DICOM research-subject-class attribute",
    :split => "ML-corpus partition, not an imaging concept",
    :receiver_channels => "DICOM enumerates coil elements (0018,9045/0018,9048) but has no count attribute; anchored on the ISMRMRD receiverChannels field",
    :quantitative => "DICOM's anchor is the Parametric Map Storage SOP class (an object type, not an attribute); BIDS T1map/T2map is the practical equivalent",
    :trajectory => "ISMRMRD trajectoryType is strictly more expressive than DICOM's Geometry of k-Space Traversal (0018,9032), which lacks EPI and golden-angle",
    :acceleration => "net R at the source's native frame binning; DICOM's Parallel Reduction Factor In-plane (0018,9069) is in-plane/PI-specific only",
    :undersampling_pattern => "Parallel Acquisition Technique (0018,9078) names the reconstruction (SENSE/GRAPPA), not the sampling mask (VISTA, kt-Gaussian, Poisson-disc, ...)",
    :file_format => "transport detail, not an imaging concept",
)
