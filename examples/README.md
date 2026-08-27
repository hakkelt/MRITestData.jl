# MRITestData Examples

## `reconstruct_all_types.jl`

Validates the full `load_raw` → `AcquisitionData` → `reconstruction` pipeline across every
supported data source, then exports representative slices as PNGs under `examples/results/`.

### Prerequisites

The `examples/` folder ships its own `Project.toml` that includes MRIReco, MRICoilSensitivities,
and PNGFiles alongside MRITestData itself. Instantiate it once, then run the script:

```sh
julia --project=examples -e 'using Pkg; Pkg.instantiate()'
julia --project=examples examples/reconstruct_all_types.jl
```

### Source-specific setup

| Source | Required |
|---|---|
| CMRxRecon-300 | Synapse token (`set_synapse_token!` or `SYNAPSE_AUTH_TOKEN`) + committed `data/cmrxrecon300_*` artifacts (run `scripts/index_cmrxrecon300.jl` once) |
| CMRxRecon2024 | Same Synapse token |
| fastMRI | Signed URLs (`set_fastmri_urls!(email_text)`) + populated `data/fastmri_map.csv` (run `scripts/index_fastmri.jl` / `scripts/index_fastmri_gz.jl` once) |
| mridata.org | Network access (public) |
| OCMR | Network access (public) |
| USC Speech | Network access (public figshare) |
| M4Raw | Network access (public Zenodo) |

Sources without setup simply produce no candidates — the script skips them silently.

### Download cache

Downloads are cached under `examples/cache/` (gitignored) so re-runs are fast. Override
the cache location with `RECON_CACHE`:

```sh
RECON_CACHE=/data/mri_cache julia --project=... examples/reconstruct_all_types.jl
```

### Optional CLI filter

Pass a single filter string to reconstruct only matching candidates. The filter is matched
case-insensitively against the label, source name and entry id (separators ignored):

```sh
# Only CMRxRecon-300 entries
julia ... examples/reconstruct_all_types.jl cmrxrecon-300

# Only USC Speech entries
julia ... examples/reconstruct_all_types.jl usc

# One specific USC file
julia ... examples/reconstruct_all_types.jl sub001/2drt

# Only fastMRI prostate
julia ... examples/reconstruct_all_types.jl "prostate"

# Only OCMR
julia ... examples/reconstruct_all_types.jl ocmr
```

With no argument, every available candidate is reconstructed (sources without data simply
contribute zero candidates).

### Output

PNG files are written to `examples/results/` (gitignored), named
`<source_slug>_frame<NN>.png`. Fully-sampled data is reconstructed with the direct
(gridding) method; undersampled data (CMRxRecon-300, R≈3) uses SENSE with ESPIRiT coil
sensitivities estimated from embedded ACS lines.

### Example output (abbreviated)

```
=== MRIReco reconstruction across data types ===
results → /path/to/examples/results
CMRxRecon300 Cine SAX          OK   dims=(320, 320, 1, 1, 12)    profiles=3840   pngs=4
CMRxRecon300 Cine LAX          OK   dims=(320, 320, 1, 1, 12)    profiles=1920   pngs=4
CMRxRecon300 T1 map            OK   dims=(320, 320, 1, 1, 4)     profiles=1280   pngs=4
CMRxRecon300 T2 map            OK   dims=(320, 320, 1, 1, 3)     profiles=960    pngs=3
CMRxRecon2024 Cine             OK   dims=(512, 256, 1, 1, 12)    profiles=3072   pngs=4
...
fastMRI Knee singlecoil        OK   dims=(640, 368, 1, 1, 1)     profiles=368    pngs=1
fastMRI Knee multicoil         OK   dims=(640, 368, 1, 15, 1)    profiles=368    pngs=1
fastMRI Brain multicoil        OK   dims=(640, 320, 1, 16, 1)    profiles=320    pngs=1
fastMRI Prostate T2            OK   dims=(320, 320, 1, 16, 1)    profiles=320    pngs=1
fastMRI Breast                 OK   dims=(640, 320, 1, 16, 1)    profiles=320    pngs=1
```
