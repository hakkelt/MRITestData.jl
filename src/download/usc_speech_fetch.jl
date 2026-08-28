# USC SPAN 75-speaker speech rtMRI range-extraction engine.
#
# The whole corpus ships as a single ~570 GB `dataset.zip` on figshare (file id
# 26378810). To pull one 2drt raw `.h5` member we:
#   1. look up its byte span + ZIP local-header length in the offset map
#      (catalog/usc_speech_catalog.jl),
#   2. resolve a temporary pre-signed S3 URL for the archive (figshare redirect),
#   3. issue an HTTP Range request against S3 (no auth on the S3 leg),
#   4. strip the ZIP local file header and, if the member is Deflated, inflate it.
#
# The data is public CC-BY, so unlike the CMRxRecon sources there is no token. The
# only wrinkle is figshare's redirect: `ndownloader.figshare.com/files/<id>` issues a
# 302 to a short-lived (~10 s) pre-signed S3 URL, so the URL is resolved immediately
# before the range request and re-resolved once on a 403 (expiry). The extracted file
# is already MRD/ISMRMRD, so it flows through the default `load_raw` path unchanged.

const _USC_NDOWNLOADER = "https://ndownloader.figshare.com/files/"

# USC Speech ids map to the in-archive `.h5` member; the cached file restores the
# extension (joinpath turns the id's slashes into a directory tree).
_cache_basename(::USCSpeech, e::DatasetEntry) = string(e.id, ".h5")

# Resolve the temporary pre-signed S3 URL for the figshare archive. A 1-byte ranged
# GET follows the 302 redirect to S3; `resp.url` is the final (pre-signed) URL, which
# is valid for a subsequent GET range request.
function _usc_resolve_presigned(file_id::AbstractString)::String
    url = string(_USC_NDOWNLOADER, file_id)
    resp = Downloads.request(
        url; method = "GET", output = devnull,
        headers = ["Range" => "bytes=0-0"], throw = true,
    )
    return resp.url
end

# True for a 403 from S3 (a pre-signed URL that expired between resolution and use).
_usc_is_expiry(err) = err isa Downloads.RequestError && err.response.status == 403

function _fetch_dataset(::USCSpeech, e::DatasetEntry, dest::AbstractString; progress::Bool, verify::Bool)
    file_id = String(e.locator["file_id"]::AbstractString)
    return _fetch_zip_member(
        e, dest, () -> _usc_resolve_presigned(file_id), _usc_is_expiry; progress = progress,
    )
end
