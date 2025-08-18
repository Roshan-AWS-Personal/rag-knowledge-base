# lambda/ingest/app.py
import os, json, urllib.request, urllib.error
from botocore.session import Session
from botocore.awsrequest import AWSRequest
from botocore.auth import SigV4Auth

AOSS_ENDPOINT = os.environ.get("OPENSEARCH_ENDPOINT", "")
INDEX_NAME    = os.environ.get("INDEX_NAME", "chunks")
EMBED_DIM     = int(os.environ.get("EMBED_DIM", "1024"))
SKIP_AOSS     = os.environ.get("SKIP_AOSS", "0") == "1"

_index_checked = False  # container-level guard

def _region_from_endpoint(endpoint: str) -> str:
    # expects <id>.<region>.aoss.amazonaws.com
    host = endpoint.replace("https://", "").split("/")[0]
    parts = host.split(".")
    if len(parts) >= 3 and parts[2] == "aoss":
        return parts[1]
    return os.environ.get("AWS_REGION", "ap-southeast-2")

def _signed_request(method: str, url: str, body, region: str):
    creds = Session().get_credentials().get_frozen_credentials()
    req   = AWSRequest(method=method, url=url, data=body,
                       headers={"content-type": "application/json"})
    SigV4Auth(creds, "aoss", region).add_auth(req)
    p = req.prepare()
    r = urllib.request.Request(p.url, data=p.body, method=p.method,
                               headers=dict(p.headers))
    try:
        return urllib.request.urlopen(r)
    except urllib.error.HTTPError as e:
        # Log enough to debug, but not the full body
        print(f"[ingest] {method} {url} -> {e.code} {e.reason}")
        print("[ingest] resp headers:", dict(e.headers.items()))
        raise

def _verify_index_exists():
    region = _region_from_endpoint(AOSS_ENDPOINT)
    url = f"{AOSS_ENDPOINT.rstrip('/')}/{INDEX_NAME}"
    resp = _signed_request("GET", url, None, region)
    print("[ingest] GET index ok, status:", getattr(resp, "status", "ok"))

def _index_dummy_doc():
    # Optional: proves writes work end-to-end
    region = _region_from_endpoint(AOSS_ENDPOINT)
    url = f"{AOSS_ENDPOINT.rstrip('/')}/{INDEX_NAME}/_doc"
    body = {
        "text":   "hello from lambda",
        "vector": [0.0] * EMBED_DIM,  # placeholder until we wire embeddings
        "source": "self-test",
        "page":   1
    }
    resp = _signed_request("POST", url, json.dumps(body).encode("utf-8"), region)
    print("[ingest] indexed dummy doc, status:", getattr(resp, "status", "ok"))

def ensure_index():
    if SKIP_AOSS or not AOSS_ENDPOINT:
        print("[ingest] SKIP_AOSS active or OPENSEARCH_ENDPOINT empty; skipping AOSS")
        return

    region = _region_from_endpoint(AOSS_ENDPOINT)
    base   = AOSS_ENDPOINT.rstrip("/")

    # Existence check
    try:
        _signed_request("HEAD", f"{base}/{INDEX_NAME}", None, region)
        print(f"[ingest] index '{INDEX_NAME}' exists")
    except urllib.error.HTTPError as e:
        if e.code != 404:
            print("[ingest] HEAD failed (non-404); skipping index creation this invoke")
            return
        # Create on 404
        body = {
            "settings": {"index": {"knn": True}},
            "mappings": {"properties": {
                "text":   {"type": "text"},
                "vector": {"type": "knn_vector", "dimension": EMBED_DIM,
                           "method": {"name":"hnsw","engine":"lucene","space_type":"cosinesimil",
                                      "parameters":{"m":16,"ef_construction":128}}},
                "source": {"type": "keyword"},
                "page":   {"type": "integer"}
            }}
        }
        _signed_request("PUT", f"{base}/{INDEX_NAME}", json.dumps(body).encode("utf-8"), region)
        print(f"[ingest] created index '{INDEX_NAME}'")
        # quick verify
        _verify_index_exists()

def handler(event, _ctx):
    global _index_checked
    if not _index_checked:
        ensure_index()
        _index_checked = True

    # For now we just log; later we’ll parse SQS bodies and index real docs
    print("[ingest] event (truncated):", str(event)[:800])

    # Optional: prove write path works (uncomment once index exists)
    # if not SKIP_AOSS and AOSS_ENDPOINT:
    #     _index_dummy_doc()

    return {"ok": True}
