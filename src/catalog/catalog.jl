"""
    DatasetEntry

Metadata describing a single downloadable MRI dataset. Returned by
[`list_datasets`](@ref) and used to drive downloading and loading.

Field names, vocabularies and units are anchored in the DICOM standard — see
[`dicom_tag`](@ref) and `docs/src/taxonomy.md` for the full mapping. A handful of fields
have no DICOM equivalent (`receiver_channels`, `split`, `cohort`, `undersampling_pattern`,
`quantitative`, `trajectory`, `acceleration`); these are documented in
[`TAXONOMY_EXTENSIONS`](@ref) with their justification.

# Fields
## Identity
- `source::AbstractSource`: which repository hosts the file.
- `id::String`: source-specific identifier (mridata UUID, OCMR file stem, ...).
- `name::String`: human-readable label — Series Description (0008,103E).

## Subject
- `subject_id::Union{String,Nothing}`: Clinical Trial Subject ID (0012,0040).
- `cohort::Union{Symbol,Nothing}`: `:volunteer`/`:patient`/`:phantom`. EXTENSION.
- `split::Union{Symbol,Nothing}`: `:train`/`:val`/`:test`/`:demo`. EXTENSION.
- `repetition::Union{Int,Nothing}`: Acquisition Number (0020,0012).

## System
- `vendor::Union{Symbol,Nothing}`: e.g. `:siemens`, `:ge` — Manufacturer (0008,0070).
- `scanner_model::Union{String,Nothing}`: Manufacturer Model Name (0008,1090).
- `institution::Union{String,Nothing}`: Institution Name (0008,0080).
- `field_strength::Union{Float64,Nothing}`: tesla — Magnetic Field Strength (0018,0087).
- `receiver_channels::Union{Int,Nothing}`: count of used receive channels. EXTENSION.
- `coil_data::Symbol`: `:original`/`:derived` — Image Type value 1 (0008,0008).

## What was imaged
- `anatomy::Symbol`: e.g. `:knee`, `:brain`, `:heart` — Body Part Examined (0018,0015).
- `contrast::Symbol`: T1/T2/T2*/proton-density/... — Acquisition Contrast (0008,9209).
- `orientation::Union{Symbol,Nothing}`: e.g. `:short_axis` — View Code Sequence (0054,0220).
- `sequence::Union{String,Nothing}`: spelled-out pulse sequence name, never abbreviated —
  Pulse Sequence Name (0018,9005).
- `echo_type::Union{Symbol,Nothing}`: `:spin`/`:gradient`/`:both` — Echo Pulse Sequence
  (0018,9008).
- `quantitative::Bool`: parametric-mapping acquisition (T1map/T2map/...). EXTENSION.

## Acquisition geometry
- `acquisition_dim::Int`: `1`/`2`/`3` — MR Acquisition Type (0018,0023).
- `num_slices::Union{Int,Nothing}`: Number of Frames (0028,0008).
- `num_frames::Union{Int,Nothing}`: cardiac/temporal frames — Cardiac Number of Images
  (0018,1090).
- `num_averages::Union{Int,Nothing}`: Number of Averages (0018,0083).

## Sampling
- `trajectory::Symbol`: ISMRMRD `trajectoryType` — `:cartesian`, `:epi`, `:radial`,
  `:goldenangle`, `:spiral`, `:other`, `:unknown`. EXTENSION (more expressive than DICOM).
- `fully_sampled::Union{Bool,Nothing}`: Percent Sampling (0018,0093) `== 100`.
- `acceleration::Union{Float64,Nothing}`: net R at the source's native frame binning.
  EXTENSION.
- `undersampling_pattern::Union{Symbol,Nothing}`: e.g. `:vista`, `:kt_gaussian`. EXTENSION.
- `partial_fourier::Union{Bool,Nothing}`: Partial Fourier (0018,9081).
- `has_acs::Bool`: Parallel Acquisition (0018,9077).

## Cardiac / contrast-agent flags
- `cardiac_sync::Symbol`: `:none`/`:realtime`/`:prospective`/`:retrospective`/`:paced` —
  Cardiac Synchronization Technique (0018,9037).
- `phase_contrast::Bool`: Phase Contrast (0018,9014).
- `blood_signal_nulling::Bool`: Blood Signal Nulling (0018,9022).
- `fat_suppression::Union{Symbol,Nothing}`: Spectrally Selected Suppression (0018,9025).
- `contrast_agent::Union{Bool,Nothing}`: Contrast/Bolus Agent present (0018,0010).

## Transport (non-DICOM)
- `file_format::Symbol`: `:ismrmrd`/`:fastmri_h5`/`:matlab_v73`.
- `approx_size_bytes::Union{Int,Nothing}`: rough download size.
- `sha256::Union{String,Nothing}`: pinned checksum, if known.
- `url::String`: resolved download URL.
- `extra::Dict{String,Any}`: source-specific metadata, keyed by DICOM keyword where one
  exists (see [`dicom_tag`](@ref) and `extra_schema`).
- `locator::Dict{String,Any}`: transport coordinates (byte offsets, archive names) needed
  to fetch the file. Not DICOM-anchored; never text-searched or displayed.
"""
struct DatasetEntry
    # ── identity ────────────────────────────────────────────────────────────
    source::AbstractSource
    id::String
    name::String

    # ── subject ─────────────────────────────────────────────────────────────
    subject_id::Union{String, Nothing}
    cohort::Union{Symbol, Nothing}
    split::Union{Symbol, Nothing}
    repetition::Union{Int, Nothing}

    # ── system ──────────────────────────────────────────────────────────────
    vendor::Union{Symbol, Nothing}
    scanner_model::Union{String, Nothing}
    institution::Union{String, Nothing}
    field_strength::Union{Float64, Nothing}
    receiver_channels::Union{Int, Nothing}
    coil_data::Symbol

    # ── what was imaged ─────────────────────────────────────────────────────
    anatomy::Symbol
    contrast::Symbol
    orientation::Union{Symbol, Nothing}
    sequence::Union{String, Nothing}
    echo_type::Union{Symbol, Nothing}
    quantitative::Bool

    # ── acquisition geometry ────────────────────────────────────────────────
    acquisition_dim::Int
    num_slices::Union{Int, Nothing}
    num_frames::Union{Int, Nothing}
    num_averages::Union{Int, Nothing}

    # ── sampling ────────────────────────────────────────────────────────────
    trajectory::Symbol
    fully_sampled::Union{Bool, Nothing}
    acceleration::Union{Float64, Nothing}
    undersampling_pattern::Union{Symbol, Nothing}
    partial_fourier::Union{Bool, Nothing}
    has_acs::Bool

    # ── cardiac / contrast-agent flags ──────────────────────────────────────
    cardiac_sync::Symbol
    phase_contrast::Bool
    blood_signal_nulling::Bool
    fat_suppression::Union{Symbol, Nothing}
    contrast_agent::Union{Bool, Nothing}

    # ── transport (non-DICOM) ───────────────────────────────────────────────
    file_format::Symbol
    approx_size_bytes::Union{Int, Nothing}
    sha256::Union{String, Nothing}
    url::String

    extra::Dict{String, Any}
    locator::Dict{String, Any}
end

# Validate every controlled-vocabulary field so a typo in a committed map fails at parse
# time instead of silently producing an entry no query can ever match.
function _check_vocab(field::Symbol, value, vocab::Tuple)
    value in vocab || error(
        "DatasetEntry.$field = $(repr(value)) is not one of the controlled vocabulary " *
            "$(vocab); see src/catalog/taxonomy.jl",
    )
    return nothing
end

function _validate_entry(e::DatasetEntry)
    _check_vocab(:anatomy, e.anatomy, ANATOMIES)
    _check_vocab(:contrast, e.contrast, CONTRASTS)
    _check_vocab(:trajectory, e.trajectory, TRAJECTORIES)
    _check_vocab(:coil_data, e.coil_data, COIL_DATA)
    _check_vocab(:cardiac_sync, e.cardiac_sync, CARDIAC_SYNC)
    e.echo_type === nothing || _check_vocab(:echo_type, e.echo_type, ECHO_TYPES)
    e.fat_suppression === nothing || _check_vocab(:fat_suppression, e.fat_suppression, FAT_SUPPRESSION)
    e.cohort === nothing || _check_vocab(:cohort, e.cohort, COHORTS)
    e.split === nothing || _check_vocab(:split, e.split, SPLITS)
    e.undersampling_pattern === nothing ||
        _check_vocab(:undersampling_pattern, e.undersampling_pattern, UNDERSAMPLING_PATTERNS)
    e.orientation === nothing || _check_vocab(:orientation, e.orientation, ORIENTATIONS)
    e.acquisition_dim in (1, 2, 3) || error(
        "DatasetEntry.acquisition_dim = $(e.acquisition_dim) must be 1, 2 or 3",
    )
    return nothing
end

function DatasetEntry(;
        source, id, name,
        subject_id = nothing, cohort = nothing, split = nothing, repetition = nothing,
        vendor = nothing, scanner_model = nothing, institution = nothing,
        field_strength = nothing, receiver_channels = nothing, coil_data = :original,
        anatomy = :unknown, contrast = :unknown, orientation = nothing, sequence = nothing,
        echo_type = nothing, quantitative = false,
        acquisition_dim = 2, num_slices = nothing, num_frames = nothing, num_averages = nothing,
        trajectory = :unknown, fully_sampled = nothing, acceleration = nothing,
        undersampling_pattern = nothing, partial_fourier = nothing, has_acs = false,
        cardiac_sync = :none, phase_contrast = false, blood_signal_nulling = false,
        fat_suppression = nothing, contrast_agent = nothing,
        file_format = :ismrmrd, approx_size_bytes = nothing, sha256 = nothing, url = "",
        extra = Dict{String, Any}(), locator = Dict{String, Any}(),
    )
    # Calls the positional constructor `@kwdef` derives from the struct's field order
    # (a distinct method from this keyword-only one, so no infinite recursion).
    e = DatasetEntry(
        source, id, name,
        subject_id, cohort, split, repetition,
        vendor, scanner_model, institution, field_strength, receiver_channels, coil_data,
        anatomy, contrast, orientation, sequence, echo_type, quantitative,
        acquisition_dim, num_slices, num_frames, num_averages,
        trajectory, fully_sampled, acceleration, undersampling_pattern, partial_fourier, has_acs,
        cardiac_sync, phase_contrast, blood_signal_nulling, fat_suppression, contrast_agent,
        file_format, approx_size_bytes, sha256, url, extra, locator,
    )
    _validate_entry(e)
    return e
end

function Base.show(io::IO, e::DatasetEntry)
    print(io, "DatasetEntry(", source_name(e.source), ":", e.id, ", ", repr(e.name))
    e.anatomy === :unknown || print(io, ", ", e.anatomy)
    e.contrast === :unknown || print(io, ", ", e.contrast)
    e.trajectory === :unknown || print(io, ", ", e.trajectory)
    e.field_strength === nothing || print(io, ", ", e.field_strength, "T")
    return print(io, ")")
end

"""
    DatasetHandle(entry::DatasetEntry)

A [`DatasetEntry`](@ref) bound for download/loading. Currently a thin wrapper that
lets the API accept either an entry or a handle; created by [`dataset`](@ref).
"""
struct DatasetHandle
    entry::DatasetEntry
end

"""
    _filter_hit(value, filter) -> Bool

Test one field `value` against one `filter`, the shared predicate behind
`_matches` (named [`DatasetEntry`](@ref) fields) and `_matches_extra`
(source-specific `extra` keys). A `filter` of `missing` means "no filter" and always
matches; otherwise it is a predicate, a collection to test membership in, or a value to
compare with `==`.
"""
function _filter_hit(value, filter)::Bool
    filter === missing && return true
    filter isa Function && return filter(value)::Bool
    (filter isa AbstractVector || filter isa Tuple || filter isa AbstractSet) &&
        return value in filter
    return value == filter
end

"""
    _matches(e::DatasetEntry, filters::AbstractDict{Symbol}) -> Bool
    _matches(e::DatasetEntry; filters...) -> Bool

Test whether `e` satisfies every `filter`. Each filter key is a field name of
[`DatasetEntry`](@ref); the value may be:

- a scalar — matched by `==`,
- a vector/tuple/set — matched by membership (`in`),
- a predicate function — matched by calling it on the field value,
- `missing` — no filter; matches everything.

Note that `nothing` is a *value*, not a wildcard: `fully_sampled = nothing` selects the
entries whose sampling status is unknown. Use `missing` (or omit the key) to not filter on
a field at all.

The `AbstractDict` form exists because [`query`](@ref) builds its filters at run time;
splatting that dictionary back into keyword arguments would rebuild the keyword tuple for
every candidate entry.
"""
function _matches(e::DatasetEntry, filters::AbstractDict{Symbol})
    for (k, v) in filters
        _filter_hit(getfield(e, k), v) || return false
    end
    return true
end

function _matches(e::DatasetEntry; kwargs...)
    for (k, v) in kwargs
        _filter_hit(getfield(e, k), v) || return false
    end
    return true
end

"""
    list_datasets(source::AbstractSource; filters...) -> Vector{DatasetEntry}

Return the catalog entries for `source`, optionally narrowed by keyword `filters`
(see `_matches`). The catalog is read from a committed metadata file, so
this works offline.

A filter value of `missing` (or an omitted key) does not filter; `nothing` matches entries
whose field is unset, so `fully_sampled = nothing` finds the ones with unknown sampling.

# Examples
```julia
list_datasets(MRIDATA; anatomy = :knee, fully_sampled = true)
list_datasets(OCMR_SOURCE; field_strength = (1.5, 3.0))
list_datasets(MRIDATA; coils = c -> c !== nothing && c >= 8)
list_datasets(FASTMRI; coils = nothing)          # coil count not recorded
```
"""
function list_datasets(source::AbstractSource; offline::Bool = false, kwargs...)
    all_entries = _catalog_entries(source; offline = offline)
    # `_catalog_entries` may hand back a memoised vector shared with other callers, so an
    # unfiltered listing still needs its own copy — but not a per-entry predicate call.
    isempty(kwargs) && return copy(all_entries)
    return filter(e -> _matches(e; kwargs...), all_entries)
end

"""
    dataset(source::AbstractSource, id::AbstractString) -> DatasetHandle

Look up a dataset by `id`. If `id` is in the curated catalog the full metadata is
used; otherwise (where the source supports it, e.g. an arbitrary mridata UUID) a
minimal entry is synthesised from `id`.
"""
function dataset(source::AbstractSource, id::AbstractString; offline::Bool = false)
    for e in _catalog_entries(source; offline = offline)
        e.id == id && return DatasetHandle(e)
    end
    _can_synthesize(source) || error(
        "unknown $(source_name(source)) id $(repr(id)); it is not in the catalog, and this " *
            "source can only serve files recorded in its committed map — the id must appear " *
            "in $(basename(_bundled_index_path(source))).",
    )
    return DatasetHandle(_synthesize_entry(source, String(id)))
end

# Per-source hooks implemented in mridata_catalog.jl / ocmr_catalog.jl.
function _catalog_entries end
function _synthesize_entry end

"""
    _can_synthesize(source) -> Bool

Whether `source` can build a usable entry for an id that is not in its catalog. True for
mridata.org (any UUID resolves to a download URL) and OCMR (any bucket file name); false
for the map-backed sources, whose files can only be fetched from byte coordinates recorded
in a committed offset map. [`dataset`](@ref) raises a uniform error for the latter rather
than each source spelling out its own.
"""
_can_synthesize(::AbstractSource) = false

# Return a copy of `e` with the named fields replaced. `DatasetEntry` is immutable, so
# any post-hoc patch (size discovery, calibration-entry derivation) has to rebuild the
# entry; building over `fieldnames` keeps a new field from being silently dropped by a
# hand-transcribed call site.
function _with(e::DatasetEntry; kwargs...)
    vals = (f in keys(kwargs) ? kwargs[f] : getfield(e, f) for f in fieldnames(DatasetEntry))
    return DatasetEntry(vals...)
end

# `fetch_sizes`/`merge_sizes` only ever patch the size, so keep the old name as a thin
# wrapper — it reads better at those call sites than a bare `_with`.
_with_size(e::DatasetEntry, sz::Union{Int, Nothing}) = _with(e; approx_size_bytes = sz)

# ── Shared offset-map CSV cell readers ────────────────────────────────────────────
# The map-backed sources read `readdlm`-parsed rows whose cells arrive as Int, Float64 or
# SubString depending on the column. A missing column index (0, from `get(col, key, 0)`)
# means the column is absent.

# Read a numeric cell as Int; `nothing` when the column is absent or unparseable.
function _csv_cell_int(row, col, key)
    idx = get(col, key, 0)
    idx == 0 && return nothing
    v = row[idx]
    v isa Integer && return Int(v)
    v isa Real && return round(Int, v)
    return tryparse(Int, strip(String(v)))
end

# Read a numeric cell as Float64; `nothing` when the column is absent or unparseable.
function _csv_cell_float(row, col, key)
    idx = get(col, key, 0)
    idx == 0 && return nothing
    v = row[idx]
    v isa Real && return Float64(v)
    s = strip(v isa AbstractString ? String(v) : string(v))
    isempty(s) && return nothing
    return tryparse(Float64, s)
end

# Read a string cell; `""` when the column is absent or empty.
function _csv_cell_str(row, col, key)
    idx = get(col, key, 0)
    idx == 0 && return ""
    v = row[idx]
    return strip(v isa AbstractString ? String(v) : string(v))
end

# Store `value` in `extra` under `key` only when it carries information, so `extra` never
# holds empty strings or `nothing` placeholders that callers would have to filter out.
_put_optional!(extra::AbstractDict, key::AbstractString, value) =
    (value === nothing || value == "") ? extra : (extra[key] = value; extra)

# Copy the columns named in `keys` from `row` into `extra`, reading each with `reader` and
# skipping the ones the row leaves blank.
function _put_columns!(extra::AbstractDict, row, col, reader, keys)
    for k in keys
        _put_optional!(extra, k, reader(row, col, k))
    end
    return extra
end

# Parse an offset-map CSV into `(data, col)` where `col` maps header name → column index.
# Returns `nothing` if the file is missing or lacks the mandatory `key_column`.
function _read_offset_map(path::AbstractString; key_column::AbstractString = "path")
    isfile(path) || return nothing
    data, header = readdlm(path, ','; header = true)
    col = Dict(strip(String(h)) => i for (i, h) in enumerate(vec(header)))
    haskey(col, key_column) || return nothing
    return data, col
end

# ── ZIP member coordinates ────────────────────────────────────────────────────────

"""
    ZipSpan

Where one member lives inside a ZIP archive, as recorded by the map-generator scripts.
`start_off`/`end_off` bound the member's local file header plus its (possibly compressed)
payload; `lfh_size` is how many of those bytes the header occupies, and `compression` is
the ZIP method (0 = stored, 8 = Deflate). Shared by M4Raw, USC Speech and CMRxRecon2024,
whose maps all carry the same six columns.
"""
struct ZipSpan
    start_off::Int
    end_off::Int
    lfh_size::Int
    compressed_size::Int
    uncompressed_size::Union{Int, Nothing}
    compression::Int
end

# Read a `ZipSpan` from an offset-map row, or `nothing` when the row lacks any of the
# coordinates needed to fetch the member. `uncompressed_size` is optional (it only feeds
# `approx_size_bytes`), so its absence does not reject the row.
function _zip_span_from_row(row, col)
    start_off = _csv_cell_int(row, col, "start_off")
    end_off = _csv_cell_int(row, col, "end_off")
    lfh_size = _csv_cell_int(row, col, "lfh_size")
    compressed_size = _csv_cell_int(row, col, "compressed_size")
    compression = _csv_cell_int(row, col, "compression")
    any(x -> x === nothing, (start_off, end_off, lfh_size, compressed_size, compression)) &&
        return nothing
    return ZipSpan(
        start_off, end_off, lfh_size, compressed_size,
        _csv_cell_int(row, col, "uncompressed_size"), compression,
    )
end

# The `locator` keys the fetch engines read back out of a `ZipSpan`. Byte coordinates are
# transport, not DICOM-describable metadata, so they live in `locator`, not `extra`.
function _zip_span_locator(span::ZipSpan)
    return Dict{String, Any}(
        "start_off" => span.start_off,
        "end_off" => span.end_off,
        "lfh_size" => span.lfh_size,
        "compressed_size" => span.compressed_size,
        "compression" => span.compression,
    )
end

# `list_datasets` and `query` re-read the index on every call, and the committed maps are
# large (fastMRI ships ~10k rows), so memoise the parsed entries. The key carries mtime and
# size, so a refreshed or hand-edited index invalidates the memo on its own. Entries are
# immutable, so handing the same vector to several callers is safe.
const _INDEX_ENTRY_CACHE = Dict{Tuple{String, Float64, Int}, Vector{DatasetEntry}}()

function _cached_index_entries(path::AbstractString, parse)::Vector{DatasetEntry}
    isfile(path) || return DatasetEntry[]
    key = (String(path), mtime(path), filesize(path))
    hit = get(_INDEX_ENTRY_CACHE, key, nothing)
    hit === nothing || return hit
    entries = parse(path)::Vector{DatasetEntry}
    _INDEX_ENTRY_CACHE[key] = entries
    return entries
end

# ── Shared per-source derivation helpers (plan §6, Phase 3) ───────────────────────

"""
    _normalize_split(s) -> Union{Symbol,Nothing}

Map a source's own split/set vocabulary (`"train"`, `"multicoil_train"`, `"TrainingSet"`,
`"validation"`, `"DemoData"`, `"gre"`, ...) onto [`SPLITS`](@ref). `nothing` when `s` is
empty or unrecognised (never silently guessed).
"""
function _normalize_split(s::AbstractString)
    t = lowercase(strip(s))
    isempty(t) && return nothing
    occursin("train", t) && return :train
    occursin("val", t) && return :val
    occursin("test", t) && return :test
    occursin("demo", t) && return :demo
    return nothing
end
_normalize_split(::Nothing) = nothing

# The per-series decoded fields a CMRxRecon(-300) file stem or `modality` string implies.
# `nothing` in any slot means "leave the DatasetEntry field at its default" — this table
# only ever asserts what the challenge protocol actually documents (plan §6).
const _CARDIAC_SERIES = Dict{String, NamedTuple}(
    "cine_lax" => (
        contrast = :mixed, orientation = :long_axis,
        sequence = "balanced steady-state free precession",
        quantitative = false, cardiac_sync = :retrospective,
        phase_contrast = false, blood_signal_nulling = false, anatomy = :heart,
    ),
    "cine_sax" => (
        contrast = :mixed, orientation = :short_axis,
        sequence = "balanced steady-state free precession",
        quantitative = false, cardiac_sync = :retrospective,
        phase_contrast = false, blood_signal_nulling = false, anatomy = :heart,
    ),
    "cine_lvot" => (
        contrast = :mixed, orientation = :lvot,
        sequence = "balanced steady-state free precession",
        quantitative = false, cardiac_sync = :retrospective,
        phase_contrast = false, blood_signal_nulling = false, anatomy = :heart,
    ),
    "t1map" => (
        contrast = :t1, orientation = :short_axis, sequence = "MOLLI inversion recovery",
        quantitative = true, cardiac_sync = :none,
        phase_contrast = false, blood_signal_nulling = false, anatomy = :heart,
    ),
    "t2map" => (
        contrast = :t2, orientation = :short_axis, sequence = "T2-prepared balanced SSFP",
        quantitative = true, cardiac_sync = :none,
        phase_contrast = false, blood_signal_nulling = false, anatomy = :heart,
    ),
    "tagging" => (
        contrast = :tagging, orientation = :short_axis, sequence = "tagged cine (SPAMM)",
        quantitative = false, cardiac_sync = :retrospective,
        phase_contrast = false, blood_signal_nulling = false, anatomy = :heart,
    ),
    "flow2d" => (
        contrast = :flow_encoded, orientation = nothing, sequence = nothing,
        quantitative = false, cardiac_sync = :none,
        phase_contrast = true, blood_signal_nulling = false, anatomy = :heart,
    ),
    "blackblood" => (
        # Contrast weighting is unconfirmed against the challenge protocol (plan §13 ¹).
        contrast = :unknown, orientation = nothing, sequence = "dark-blood turbo spin echo",
        quantitative = false, cardiac_sync = :none,
        phase_contrast = false, blood_signal_nulling = true, anatomy = :heart,
    ),
    "aorta_sag" => (
        contrast = :mixed, orientation = :sagittal, sequence = nothing,
        quantitative = false, cardiac_sync = :none,
        phase_contrast = false, blood_signal_nulling = false, anatomy = :aorta,
    ),
    "aorta_tra" => (
        contrast = :mixed, orientation = :axial, sequence = nothing,
        quantitative = false, cardiac_sync = :none,
        phase_contrast = false, blood_signal_nulling = false, anatomy = :aorta,
    ),
)

"""
    _cardiac_series(stem) -> NamedTuple

Decode a CMRxRecon(-300) file stem or `modality` string (e.g. `"cine_sax"`, `"Cine SAX"`,
`"T1map"`, `"aorta_tra"`) into `(contrast, orientation, sequence, quantitative,
cardiac_sync, phase_contrast, blood_signal_nulling, anatomy)`. Unrecognised stems return
all-`nothing`/default fields rather than guessing.
"""
function _cardiac_series(stem::AbstractString)
    key = lowercase(replace(strip(String(stem)), r"[\s\-]+" => "_"))
    return get(
        _CARDIAC_SERIES, key,
        (
            contrast = :unknown, orientation = nothing, sequence = nothing,
            quantitative = false, cardiac_sync = :none,
            phase_contrast = false, blood_signal_nulling = false, anatomy = :heart,
        ),
    )
end

# Parse every row of an offset-map CSV with `row_to_entry(row, col)`, dropping rows it
# rejects (`nothing`). Shared by every map-backed source.
function _parse_offset_map(
        path::AbstractString, row_to_entry; key_column::AbstractString = "path",
    )::Vector{DatasetEntry}
    parsed = _read_offset_map(path; key_column = key_column)
    parsed === nothing && return DatasetEntry[]
    data, col = parsed
    entries = DatasetEntry[]
    for row in eachrow(data)
        e = row_to_entry(row, col)
        e === nothing || push!(entries, e)
    end
    return entries
end
