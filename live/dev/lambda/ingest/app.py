# lambda/ingest/app.py
import os, json, urllib.request, urllib.error
from botocore.session import Session
from botocore.awsrequest import AWSRequest
from botocore.auth import SigV4Auth

AOSS_ENDPOINT = os.environ.get("OPENSEARCH_ENDPOINT", "")
INDEX_NAME    = os.environ.get("INDEX_NAME", "chunks")
EMBED_DIM     = int(os.environ.get("EMBED_DIM", "1024"))
SKIP_AOSS     = os.environ.get("SKIP_AOSS", "0") == "1"

_index_checked = False

def _region_from_endpoint(endpoint: str) -> str:
    # expects <id>.<region>.aoss.amazonaws.com
    host = endpoint.replace("https://", "").split("/")[0]
    parts = host.split(".")
    return parts[1] if len(parts) >= 3 and parts[2] == "aoss" else os.environ.get("AWS_REGION", "ap-southeast-2")

def _signed_request(method: str, url: str, body, region: str):
    creds = Session().get_credentials().get_frozen_credentials()
    req   = AWSRequest(method=method, url=url, data=body, headers={"content-type": "application/json"})
    SigV4Auth(creds, "aoss", region).add_auth(req)
    p = req.prepare()
    r = urllib.request.Request(p.url, data=p.body, method=p.method, headers=dict(p.headers))
    try:
        return urllib.request.urlopen(r)
    except urllib.error.HTTPError as e:
        print(f"[ingest] {method} {url} -> {e.code} {e.reason}")
        print("[ingest] resp headers:", dict(e.headers.items()))
        raise

def ensure_index():
    if SKIP_AOSS or not AOSS_ENDPOINT:
        print("[ingest] SKIP_AOSS or empty endpoint; skipping AOSS")
        return
    region = _region_from_endpoint(AOSS_ENDPOINT)
    base   = AOSS_ENDPOINT.rstrip("/")
    try:
        _signed_request("HEAD", f"{base}/{INDEX_NAME}", None, region)
        print(f"[ingest] index '{INDEX_NAME}' exists")
        return
    except urllib.error.HTTPError as e:
        if e.code != 404:
            print("[ingest] HEAD failed (non-404); skipping index creation for now")
            return
    body = {
        "settings": {"index": {"knn": True}},
        "mappings": {"properties": {
            "text": {"type": "text"},
            "vector": {"type": "knn_vector", "dimension": EMBED_DIM,
                       "method": {"name":"hnsw","engine":"lucene","space_type":"cosinesimil",
                                  "parameters":{"m":16,"ef_construction":128}}},
            "source": {"type":"keyword"}, "page": {"type":"integer"}
        }}
    }
    _signed_request("PUT", f"{base}/{INDEX_NAME}", json.dumps(body).encode("utf-8"), region)
    print(f"[ingest] created index '{INDEX_NAME}'")

def handler(event, _ctx):
    global _index_checked
    if not _index_checked:
        ensure_index()
        _index_checked = True
    print("[ingest] event (truncated):", str(event)[:800])
    return {"ok": True}
