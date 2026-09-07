# Internals & maintainer notes

Nothing on this page is needed to *use* the package — [`load_raw`](@ref) hides all of
it. It documents how archive-backed sources are fetched without downloading the whole
archive, the maintainer scripts that build the committed index artifacts, and the design
rationale behind the DICOM-anchored taxonomy.

## Taxonomy design principles

This section is the internal companion to [Taxonomy](@ref): that page is the
*reference* (what each field means, the DICOM mapping, the extension list, the
external sources cited). This section only covers what that page doesn't: the rules to
follow when extending the taxonomy (new source, new field, new vocabulary value).

### Field tiers

Deciding where a new piece of source metadata goes: DICOM-anchored and present across
most/all sources → core field. DICOM-anchored but source-specific → `extra`
(`extra_schema` documents it per source). Not DICOM-anchored and purely about where the
bytes live → `locator`. Keeping `locator` separate from `extra` is what lets
`_matches_text` search imaging metadata without also matching an archive path
substring — `locator` is never searched or displayed.

### When to add an extension

A field becomes a documented extension only when DICOM genuinely has no attribute for
the concept — not when the mapping is merely inconvenient. Check the standard first
(DICOM PS3.3, PS3.16 Annex L for body parts) before concluding there's no anchor.

Each extension needs a one-line justification recorded in `TAXONOMY_EXTENSIONS`
(`src/catalog/dicom_map.jl`) and in the extension list of [Taxonomy](@ref) — keep both
in sync.

Promoting an extension's local `Symbol` vocabulary to a real coding system later (e.g.
`orientation` to SNOMED View Code Sequence terms) is a separate, deliberate change, not
something to do opportunistically while adding a source.

### Controlled vocabularies

Every `Symbol`-typed core field is validated against a fixed tuple in
`src/catalog/taxonomy.jl` (`CONTRASTS`, `TRAJECTORIES`, `ANATOMIES`, etc.) by
`DatasetEntry`'s inner constructor. A typo in a committed map fails at parse time
instead of producing an entry that queries can never match. When adding a value to a
vocabulary: for the DICOM-defined ones, add only terms the standard actually defines
(lowercased, not abbreviated); for the extension ones (`SPLITS`, `COHORTS`,
`UNDERSAMPLING_PATTERNS`, `ORIENTATIONS`), add a value only when a source actually
needs it, with the same one-line-justification bar as a new extension field.

`sequence` deliberately stays a free-text `String`, spelled out in full, rather than a
controlled vocabulary — pulse sequence names vary too much across vendors and papers to
enumerate without losing information.

### Provenance confidence when deriving per-source values

When a per-source parser (`src/catalog/*_catalog.jl`) sets a field from something that
isn't a 1:1 column copy, tag the source of that fact in the comment: **map** (already
present in a committed `data/*.csv` column), **pub** (stated in the dataset's own
publication — cite author, year, and ideally a quoted phrase), or **protocol** (fixed by
the acquisition protocol for the entire source, not per-row data).

A `pub`-sourced value that isn't fully settled (ambiguous in the paper, or inferred
rather than stated) gets a footnote in the parser comment saying so — don't present an
inference as a documented fact. `contrast = :unknown` is a legitimate value when the
source genuinely doesn't say; it is not a placeholder to fill in later.

### Adding a new dataset source

1. Write the per-source catalog parser (`src/catalog/<source>_catalog.jl`) directly
   against the field tiers above — no separate design phase needed, the taxonomy
   already exists.
2. Reuse an existing DICOM-anchored field or `extra` key before adding a new one; check
   [Taxonomy](@ref)'s tables first.
3. If the source needs a genuinely new extension or vocabulary value, follow the rules
   above.
4. Add the source's protocol facts to [Taxonomy](@ref)'s external-references list with
   a citation, and extend `test/test_catalog.jl`'s vocabulary-membership checks and
   `test/test_taxonomy.jl`'s DICOM-coverage check to cover the new source.
5. Update `docs/src/datasets.md` with the new source's per-field table.

## Internals: random-access extraction

Only `MRIDATA` and `OCMR_SOURCE` are whole-file downloads. Every other source is a small
file inside a very large upstream archive, and the package pulls **only that file's
bytes** with HTTP range requests. Three strategies, by archive format:

### ZIP central directory (USC Speech, M4Raw)

A ZIP stores a central directory listing every member's byte offset, compressed size and
compression method. The package reads that directory once (committed as
`data/usc_speech_map.csv` / `data/m4raw_map.csv`), then issues a single HTTP `Range`
request for the target member, strips its local file header, and inflates it if the
member is DEFLATE-compressed.

- USC Speech: figshare's `ndownloader` 302-redirects to a short-lived presigned S3 URL
  that supports ranges; the URL is resolved just before the range GET and re-resolved
  once on a 403 (expiry).
- M4Raw: Zenodo serves ranges directly.

### Split ZIP with a per-file offset map (CMRxRecon2024)

The CMRxRecon2024 training and after-competition archives are each one giant ZIP split
into 4 GiB Synapse file entities. `cmrxrecon2024_fetch.jl` maps each `.mat` member to
its `(fragment, offset, length)` using the committed `data/cmrxrecon2024_map.csv`, then
range-reads across fragment boundaries as needed.

### zran checkpoint index for gzip streams (CMRxRecon-300, fastMRI `.tar.gz`)

A `.tar.gz` is a single continuous gzip stream and is **not** randomly seekable. The
package ships a precomputed **zran** (zlib random-access) index: while streaming the
archive once, a checkpoint is captured at the DEFLATE block boundary just before each
member — a 32 KiB dictionary snapshot plus the sub-byte bit offset. `src/util/zran.jl`
(`libz` `ccall` wrappers + `inflatePrime` for the bit offset) then seeds a raw-inflate
decoder from the nearest checkpoint and decompresses only forward to the member.

- CMRxRecon-300: checkpoints in `data/cmrxrecon300_zran/`, member maps
  `data/cmrxrecon300_<set>_map.csv`.
- fastMRI prostate/breast: checkpoints in `data/fastmri_zran/<archive_stem>.bin.gz`,
  members appended to `data/fastmri_map.csv`.

### xz block-level ranges (fastMRI `.tar.xz`)

An `.xz` file is a sequence of independently-compressed blocks. `scripts/index_fastmri.jl`
walks every block (fetched by range request), decompresses it in isolation and scans the
embedded tar members, recording one row per `.h5` file in `data/fastmri_map.csv`. The
runtime range-reads and decompresses just the block(s) spanning the requested member.

## The `.mat` → ISMRMRD conversion

`CMRXRECON2024`, `CMRXRECON300`, `M4RAW` and `FASTMRI` are not ISMRMRD. On first load
`_cmrxrecon_to_ismrmrd` (`src/load/cmrxrecon_ismrmrd.jl`) builds a valid Cartesian
ISMRMRD file and caches it next to the raw download:

- one profile per phase-encode line, temporal/parametric frames → ISMRMRD contrasts;
- CMRxRecon-300 and fastMRI (non-fully-sampled) read the true acquired-line pattern from
  the k-space zero-fill and mark the acquisition undersampled; the ACS lines are written
  into the same file flagged `ACQ_IS_PARALLEL_CALIBRATION`;
- M4Raw and fully-sampled fastMRI use an all-true mask;
- CMRxRecon ships no FOV — a placeholder (matrix size in mm) is written while the
  encoding/recon matrix reflects the true dimensions.

`MRITestData.load_mat` returns the raw MATLAB arrays (`Dict`) for the CMRxRecon sources
if you want to bypass the conversion.

## Static vs live indexes

`_is_static_index(source)` marks the sources whose catalog ships with the package
(CMRxRecon2024, CMRxRecon-300, USC Speech, M4Raw, fastMRI). For those `ensure_index`
returns the bundled path directly — nothing is fetched, cached or aged out, and
`refresh_index` is a no-op that still reports the path. Only `OCMR` and `MridataOrg`
define `_index_source_url` / `_fetch_index`:

- OCMR — the authoritative `ocmr_data_attributes.csv` from OCMR's S3 bucket.
- mridata.org — scraped from `mridata.org/list` (no JSON API exists). The committed
  `data/mridata_index.toml` is the offline fallback: a successful scrape supplies the
  catalog and any committed field is merged on top of it per entry; the file is used on
  its own only when the scrape fails entirely.

A new map-backed source needs only `_bundled_index_path`, `_is_static_index`, its
row→entry parser, and a `_catalog_entries` that calls `_cached_index_entries`.

## Maintainer scripts

The committed index artifacts under `data/` are built offline by the scripts in
[`scripts/`](https://github.com/hakkelt/MRITestData.jl/blob/master/scripts/README.md).
They are needed only when adding a dataset version or when an upstream archive changes.

| Script | Produces | Needs |
|---|---|---|
| `list_cmrxrecon2024_parts.jl` | `data/cmrxrecon2024*_parts.toml` | Synapse token |
| `generate_cmrxrecon2024_map.jl` | `data/cmrxrecon2024_map.csv` | archive fragments on disk |
| `index_cmrxrecon300.jl` | `data/cmrxrecon300_*_map.csv` + zran checkpoints | Synapse token |
| `generate_usc_speech_map.jl` | `data/usc_speech_map.csv` | figshare access |
| `generate_m4raw_map.jl` | `data/m4raw_map.csv` | — |
| `index_fastmri.jl` | `data/fastmri_map.csv` (xz: knee, brain) | valid fastMRI signed URLs |
| `index_fastmri_gz.jl` | `data/fastmri_map.csv` + `data/fastmri_zran/` (gz: prostate, breast) | valid fastMRI signed URLs |

Each script's positional arguments are stored archive keys, local paths, or signed URLs;
see [`scripts/README.md`](https://github.com/hakkelt/MRITestData.jl/blob/master/scripts/README.md)
for the full archive lists and the parallel-execution recipe.

## Documentation assets

- `docs/generate_recon_images.jl` renders the coil-combined magnitude images in
  [Reconstruction with MRIReco](@ref). They are committed rather than built live because
  reconstruction needs MRIReco plus multi-GB real downloads (and a Synapse token).
- `docs/src/assets/browser-demo.gif` is a screen recording of a real
  `run_browser(offline = true)` session that walks through **paging** (`PgDn`),
  the **details pane** (`d`), a **string query** (`s` → `dataset=ocmr AND R!=nothing`)
  and the **column picker** (`c`). It is regenerated (not built in CI) using:
  1. **Record the cast**: Install `pexpect` (`pip install --user pexpect`) and run:
     ```bash
     python3 docs/record_browser_demo.py
     ```
     This drives the browser inside a 150×40 pseudo-terminal and writes `docs/assets/browser-demo.cast`.
  2. **Render to GIF**: Download [`agg`](https://github.com/asciinema/agg) (e.g., from [GitHub Releases](https://github.com/asciinema/agg/releases)) and render:
     ```bash
     agg --font-size 13 --fps-cap 12 --speed 1.15 --last-frame-duration 3 --theme asciinema docs/assets/browser-demo.cast docs/src/assets/browser-demo.gif
     ```
  Re-record it whenever the column set in `src/browse.jl` or the key bindings change.
