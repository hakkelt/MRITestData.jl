# FAQ & troubleshooting

## Access & credentials

### How do I create a Synapse Personal Access Token? (CMRxRecon2024 / CMRxRecon-300)

1. Register a free account at [synapse.org](https://www.synapse.org).
2. **CMRxRecon2024 only:** also apply to join the
   [CMRxRecon2024 challenge](https://cmrxrecon.github.io/2024/Task2.html) and complete
   the external team-information form. Until that registration is finalised a token has
   no download permission on the data — this is the most common CMRxRecon2024 failure.
   **CMRxRecon-300** needs no challenge application (CC-BY, free account only).
3. Go to **Account Settings → Personal Access Tokens → Create New Token**
   (`https://www.synapse.org/#!PersonalAccessTokens:`). Give it **View** and
   **Download** scopes. Copy the token — it is shown once.
4. Register it with the package:

   ```julia
   MRITestData.set_synapse_token!("eyJ0…")   # persisted in LocalPreferences.toml
   ```

   or export `SYNAPSE_AUTH_TOKEN` (takes precedence over the stored value).

`LocalPreferences.toml` is gitignored by the package template — keep it that way; never
commit a token.

### fastMRI: I filled the form but `list_datasets(FASTMRI)` is empty

Two independent things are needed:

1. **Signed URLs** from the confirmation email, registered with
   [`set_fastmri_urls!`](@ref) — paste the whole email body or just the `curl` block.
   Check expiry with `fastmri_url_expires()`; re-request after 90 days.
2. **A populated offset map** (`data/fastmri_map.csv`). This is a *maintainer* artifact
   built once against the real archives (`scripts/index_fastmri.jl` /
   `scripts/index_fastmri_gz.jl`). Until a populated map is committed to the package,
   `list_datasets(FASTMRI)` returns an empty catalog even with valid URLs. See
   [fastMRI: form-gated credentials](@ref).

### "403 Forbidden" partway through a download

figshare (USC Speech) and AWS pre-signed URLs (fastMRI) expire. The package re-resolves
figshare URLs once automatically on a 403; for fastMRI, call `set_fastmri_urls!` again
with fresh links. For Synapse, regenerate the PAT if it was revoked or scoped wrong.

## Storage & network

### Where are downloads stored?

Wherever you point `MRITestData.set_download_path!` — a directory of your choice, or the
per-package [Scratch.jl](https://github.com/JuliaPackaging/Scratch.jl) space
(`set_download_path!(:cache)`, under `~/.julia/scratchspaces/<MRITestData-UUID>/`). The
choice is persisted in `LocalPreferences.toml`. **Nothing downloads until it is set.**
The Scratch space persists across sessions and Julia versions but is garbage-collected
by Pkg if the package is uninstalled. `cache_path(entry)` gives the exact path for one
entry; `get_download_path()` the configured root.

```julia
clear_cache()                       # wipe everything
clear_cache(; source = OCMR_SOURCE) # one source
```

### Do I have to download the whole archive?

**No.** Only OCMR and mridata.org datasets are whole-file downloads (tens of MB to a
few GB). For every archive-backed source the package fetches **just the bytes of the
one file you ask for** via HTTP range requests (ZIP range-extraction, xz block ranges,
or a zran checkpoint index — see [Internals: random-access extraction](@ref)). The
huge archive sizes below are the *upstream* totals, not what lands on your disk.

### Disk-footprint reference

| Source | Upstream archive(s) | Typical **per-file** download | Access |
|---|--:|--:|---|
| `MRIDATA` | — (per-file) | 0.1–2 GB (3-D knee volumes) | direct HTTP |
| `OCMR_SOURCE` | — (per-file) | 10–150 MB | direct HTTP |
| `CMRXRECON2024` | ~1.2 TB split ZIP | 5–300 MB per `.mat` | Synapse token + challenge reg. |
| `CMRXRECON300` | ~580 GB split `.tar.gz` | 50–800 MB per `.mat` (+ paired `_calib`) | free Synapse account |
| `USC_SPEECH` | ~570 GB `dataset.zip` | 20–200 MB per `.h5` | figshare, no account |
| `M4RAW` | several multi-GB ZIPs | 5–40 MB per `.h5` | Zenodo, no account |
| `FASTMRI` | ~60–250 GB per anatomy archive | 0.05–4.5 GB per `.h5` (breast largest) | form-gated signed URLs |

`download_dataset(entry; max_bytes = 2_000_000_000)` aborts before pulling a file
larger than the guard.

### A download or index refresh fails with a network error

Discovery is offline-safe: on any network failure the **bundled index** that ships with
the package is used, with a `@warn`, not an exception. Force fully-offline behaviour
with `offline = true`:

```julia
list_datasets(OCMR_SOURCE; offline = true)
run_browser(; offline = true)
```

Actual file downloads do need the network and will throw if it is unavailable.

### Behind an HTTP proxy?

The package uses Julia's `Downloads` stdlib (libcurl). Set `HTTPS_PROXY` / `HTTP_PROXY`
(and `NO_PROXY`) in the environment before starting Julia.

## Loading & reconstruction

### My reconstruction is aliased / folded

The dataset is undersampled and you used a direct (inverse-FFT) reconstruction. Use
CG-SENSE — see [Reconstructing undersampled data](@ref). Check `entry.fully_sampled`
and `entry.acceleration` first; `entry.has_acs == true` means a calibration region is
available for coil-sensitivity estimation.

### The image looks stretched in one direction

`load_raw` uses the ISMRMRD `encodedSize` and does **not** auto-crop to `reconSize`, so
readout oversampling (commonly 2×) and partial-Fourier dimensions are preserved. Crop
the readout axis yourself (`m[nx÷4+1 : 3nx÷4, :]`) or resize to `raw.params["reconSize"]`.

### Non-Cartesian (USC Speech) reconstruction

`raw.params["trajectory"]` is not `"cartesian"`; an inverse FFT does not apply. Build a
non-Cartesian `AcquisitionData` with the trajectory and a density-compensation weighting
(the package does **not** estimate DCF — supply your own). See
[Reconstruction with MRIReco](@ref).

## Catalog

### Why is `entry.receiver_channels` (or TE, TR, FOV…) `nothing`?

The source does not publish it. `nothing` is the honest value, and it is treated as a
*value to match* in filters, not a wildcard — `list_datasets(src; receiver_channels =
nothing)` returns exactly the entries where it is unknown. Pass `missing` (or omit the
keyword) to not filter on it. Some fields (coil counts for OCMR) become known only after
`load_raw` reads the file.

### The live catalog has more datasets than the offline one

`MRIDATA` and `OCMR_SOURCE` self-update from upstream; the committed bundled index is a
smaller fallback. The other five sources ship a static committed map and are identical
online and offline. `refresh_index()` forces an update; `index_age_days(src)` reports
staleness.
