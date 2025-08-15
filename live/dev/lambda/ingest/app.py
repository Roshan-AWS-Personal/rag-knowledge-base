# lambda/ingest/app.py
import os, json
from botocore.session import Session
from botocore.awsrequest import AWSRequest
from botocore.auth import SigV4Auth
import urllib.request

AOSS_ENDPOINT = os.environ["OPENSEARCH_ENDPOINT"]   # e.g., https://xxxxx.aoss.ap-southeast-2.amazonaws.com
INDEX_NAME    = os.environ.get("INDEX_NAME", "chunks")
EMBED_DIM     = int(os.environ.get("EMBED_DIM", "1024"))

def _region_from_endpoint(endpoint: str) -> str:
    host = endpoint.replace("https://", "").split("/")[0]
    parts = host.split(".")  # [id, 'aoss', '<region>', 'amazonaws', 'com']
    return parts[2]

def _signed_request(method: str, url: str, body: bytes | None, region: str):
    creds = Session().get_credentials().get_frozen_credentials()
    req   = AWSRequest(method=method, url=url, data=body, headers={"content-type":"application/json"})
    SigV4Auth(creds, "aoss", region).add_auth(req)
    prepared = req.prepare()
    http_req = urllib.request.Request(
        url=prepared.url,
        data=prepared.body,
        method=prepared.method,
        headers=dict(prepared.headers),
    )
    return urllib.request.urlopen(http_req)  # raises on non-2xx

def ensure_index():
    region = _region_from_endpoint(AOSS_ENDPOINT)
    head_url = f"{AOSS_ENDPOINT.rstrip('/')}/{INDEX_NAME}"
    try:
        _signed_request("HEAD", head_url, None, region)
        print(f"[ingest] index '{INDEX_NAME}' already exists")
        return
    except Exception as e:
        # 404 → create it; anything else re-raise
        if "404" not in str(e):
            print(f"[ingest] HEAD failed: {e}")
            raise

    body = {
        "settings": { "index": { "knn": True } },
        "mappings": {
            "properties": {
                "text":   { "type": "text" },
                "vector": {
                    "type": "knn_vector",
                    "dimension": EMBED_DIM,
                    # Pin cosine; defaults can vary by version
                    "method": {
                        "name": "hnsw",
                        "engine": "lucene",
                        "space_type": "cosinesimil",
                        "parameters": { "m": 16, "ef_construction": 128 }
                    }
                },
                "source": { "type": "keyword" },
                "page":   { "type": "integer" }
            }
        }
    }
    put_url = f"{AOSS_ENDPOINT.rstrip('/')}/{INDEX_NAME}"
    _signed_request("PUT", put_url, json.dumps(body).encode("utf-8"), region)
    print(f"[ingest] created index '{INDEX_NAME}' (dim={EMBED_DIM})")

# Cold start: ensure index
ensure_index()

def handler(event, _ctx):
    # we’ll add chunking/embedding next
    print("[ingest] got event (truncated):", str(event)[:800])
    return {"ok": True}
