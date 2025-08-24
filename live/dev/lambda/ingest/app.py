# lambda/ingest/app.py
import os, json, urllib.request, urllib.error
import hashlib
from urllib.parse import urlparse, unquote_plus
from botocore.session import Session
from botocore.awsrequest import AWSRequest
from botocore.auth import SigV4Auth
import botocore
from botocore.exceptions import ClientError

# S3 client (uses Lambda's execution role / env region)
s3 = Session().create_client("s3")

# ---- Config from environment ----
AOSS_ENDPOINT = os.environ.get("OPENSEARCH_ENDPOINT", "")
INDEX_NAME    = os.environ.get("INDEX_NAME", "chunks")
EMBED_DIM     = int(os.environ.get("EMBED_DIM", "1024"))
SKIP_AOSS     = os.environ.get("SKIP_AOSS", "0") == "1"

_index_checked = False  # run ensure_index() once per warm container

# ---- Helpers ----
def _region_from_endpoint(endpoint: str) -> str:
    host = endpoint.replace("https://", "").split("/")[0]
    parts = host.split(".")
    if len(parts) >= 3 and parts[2] == "aoss":
        return parts[1]
    return os.environ.get("AWS_REGION", "ap-southeast-2")

def _signed_request(method: str, url: str, body, region: str):
    # Normalize body for hashing/signing
    if body is None:
        body = b""
    if isinstance(body, str):
        body = body.encode("utf-8")

    # AOSS requires x-amz-content-sha256 with the *actual* payload hash
    payload_hash = hashlib.sha256(body).hexdigest()
    creds = Session().get_credentials().get_frozen_credentials()

    host = urlparse(url).netloc
    base_headers = {
        "host": host,
        "content-type": "application/json",
        "x-amz-content-sha256": payload_hash,
    }

    # SigV4 for service 'aoss' in the exact region
    req = AWSRequest(method=method, url=url, data=body, headers=base_headers)
    SigV4Auth(creds, "aoss", region).add_auth(req)
    p = req.prepare()

    # Do not send a stale/signed Content-Length
    send_headers = dict(p.headers)
    send_headers.pop("Content-Length", None)
    send_headers.pop("content-length", None)

    # Debug: show SignedHeaders and payload hash actually used
    auth_hdr = send_headers.get("Authorization", "")
    sh = ""
    if "SignedHeaders=" in auth_hdr:
        sh = auth_hdr.split("SignedHeaders=")[-1].split(",")[0]
    print(f"[sigv4] region={region} host={host} SignedHeaders={sh} x-amz-content-sha256={send_headers.get('x-amz-content-sha256')}")

    r = urllib.request.Request(p.url, data=body, method=p.method, headers=send_headers)
    try:
        return urllib.request.urlopen(r)
    except urllib.error.HTTPError as e:
        hint = None
        try:
            hint = e.headers.get("x-aoss-response-hint")
        except Exception:
            pass
        body_txt = ""
        try:
            body_txt = e.read().decode("utf-8", "ignore")
        except Exception:
            pass
        print(f"[ingest] {method} {url} -> {e.code} {e.reason} (hint={hint})")
        if body_txt:
            print("[ingest] error body:", body_txt[:4000])
        raise

def _verify_index_exists():
    region = _region_from_endpoint(AOSS_ENDPOINT)
    url = f"{AOSS_ENDPOINT.rstrip('/')}/{INDEX_NAME}"
    resp = _signed_request("GET", url, None, region)
    print(f"[ingest] endpoint={AOSS_ENDPOINT} derived_region={_region_from_endpoint(AOSS_ENDPOINT)}")
    print("[ingest] GET index ok, status:", getattr(resp, "status", "ok"))

def _index_dummy_doc():
    region = _region_from_endpoint(AOSS_ENDPOINT)
    url    = f"{AOSS_ENDPOINT.rstrip('/')}/{INDEX_NAME}/_doc"
    body   = {"text": "hello from lambda", "vector": [0.0]*EMBED_DIM, "source": "self-test", "page": 1}
    resp = _signed_request("POST", url, json.dumps(body).encode("utf-8"), region)
    print("[ingest] indexed dummy doc, status:", getattr(resp, "status", "ok"))

def ensure_index():
    if SKIP_AOSS or not AOSS_ENDPOINT:
        print("[ingest] SKIP_AOSS active or OPENSEARCH_ENDPOINT empty; skipping AOSS")
        return

    region = _region_from_endpoint(AOSS_ENDPOINT)
    base   = AOSS_ENDPOINT.rstrip("/")

    # 1) Check existence
    try:
        _signed_request("HEAD", f"{base}/{INDEX_NAME}", None, region)
        print(f"[ingest] index '{INDEX_NAME}' exists")
        return
    except urllib.error.HTTPError as e:
        if e.code != 404:
            print("[ingest] HEAD failed (non-404); skipping index creation this invoke")
            return

    # 2) Create index (Lucene KNN)
    try:
        body = {
            "settings": { "index.knn": True },
            "mappings": {
                "properties": {
                    "text":   { "type": "text" },
                    "vector": { "type": "knn_vector", "dimension": EMBED_DIM },
                    "source": { "type": "keyword" },
                    "page":   { "type": "integer" }
                }
            }
        }
        _signed_request("PUT", f"{base}/{INDEX_NAME}", json.dumps(body).encode("utf-8"), region)
        print(f"[ingest] created index '{INDEX_NAME}' via PUT")
        _verify_index_exists()
        return
    except urllib.error.HTTPError as e_put:
        if getattr(e_put, "code", None) == 403:
            print("[ingest] PUT create denied (403). Trying implicit create via first document...")
            try:
                _index_dummy_doc()
                print("[ingest] index created implicitly by first document")
                return
            except urllib.error.HTTPError as e_post:
                print("[ingest] implicit create failed:", getattr(e_post, "code", "?"), getattr(e_post, "reason", "?"))
                raise
        else:
            raise

# ---- New: index real text and handle S3 events ----
def _index_text(text: str, source_key: str):
    if SKIP_AOSS or not AOSS_ENDPOINT:
        print("[ingest] SKIP_AOSS active; not indexing text")
        return
    region = _region_from_endpoint(AOSS_ENDPOINT)
    url    = f"{AOSS_ENDPOINT.rstrip('/')}/{INDEX_NAME}/_doc"
    body   = {
        "text":   (text or "")[:2000],   # keep small for now
        "vector": [0.0] * EMBED_DIM,     # placeholder until embedding is wired
        "source": source_key,
        "page":   1
    }
    _signed_request("POST", url, json.dumps(body).encode("utf-8"), region)
    print(f"[ingest] indexed doc from s3://{source_key} (len={len(text or '')})")

def _handle_s3_event(event):
    recs = event.get("Records", [])
    for r in recs:
        if r.get("eventSource") != "aws:s3":
            continue
        bucket = r["s3"]["bucket"]["name"]
        key    = unquote_plus(r["s3"]["object"]["key"])
        print(f"[ingest] S3 event for s3://{bucket}/{key}")

        try:
            obj = s3.get_object(Bucket=bucket, Key=key)
            body_bytes = obj["Body"].read()
            # naive decode for text files; extend later for PDFs/Docx, etc.
            try:
                text = body_bytes.decode("utf-8", errors="replace")
            except Exception:
                text = ""  # fallback to empty string if decode fails
        except ClientError as e:
            print(f"[ingest] S3 get_object failed: {e}")
            continue

        _index_text(text, f"{bucket}/{key}")

# ---- Lambda entrypoint ----
def handler(event, _ctx):
    global _index_checked
    if not _index_checked:
        ensure_index()
        _index_checked = True

    if "Records" in event:          # real S3 trigger
        _handle_s3_event(event)
    elif event.get("self_test"):    # console test event to index a dummy doc
        _index_dummy_doc()

    print("[ingest] event (truncated):", str(event)[:800])
    return {"ok": True}
