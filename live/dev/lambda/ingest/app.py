# lambda/ingest/app.py
import os, json, urllib.request, urllib.error, hashlib, time
from urllib.parse import urlparse, unquote_plus
from botocore.session import Session
from botocore.awsrequest import AWSRequest
from botocore.auth import SigV4Auth
from botocore.exceptions import ClientError

# --- Clients (use Lambda role creds/region) ---
_sess = Session()
s3 = _sess.create_client("s3")

# ---- Config from environment ----
AOSS_ENDPOINT  = os.environ.get("OPENSEARCH_ENDPOINT", "")
INDEX_NAME     = os.environ.get("INDEX_NAME", "chunks")
EMBED_DIM      = int(os.environ.get("EMBED_DIM", "1024"))
SKIP_AOSS      = os.environ.get("SKIP_AOSS", "0") == "1"

# Bedrock (embedding)
BEDROCK_REGION = os.environ.get("BEDROCK_REGION", "us-west-2")
EMBED_MODEL_ID = os.environ.get("EMBED_MODEL_ID", "amazon.titan-embed-text-v2:0")
PREVIEW_KNN    = os.environ.get("PREVIEW_KNN", "1") == "1"

bedrock = _sess.create_client("bedrock-runtime", region_name=BEDROCK_REGION)

_index_checked = False  # run ensure_index() once per warm container

# ---- Helpers ----
def _region_from_endpoint(endpoint: str) -> str:
    host = endpoint.replace("https://", "").split("/")[0]
    parts = host.split(".")
    if len(parts) >= 3 and parts[2] == "aoss":
        return parts[1]
    return os.environ.get("AWS_REGION", "ap-southeast-2")

def _signed_request(method: str, url: str, body, region: str):
    if body is None:
        body = b""
    if isinstance(body, str):
        body = body.encode("utf-8")

    payload_hash = hashlib.sha256(body).hexdigest()
    creds = _sess.get_credentials().get_frozen_credentials()

    host = urlparse(url).netloc
    base_headers = {
        "host": host,
        "content-type": "application/json",
        "x-amz-content-sha256": payload_hash,
    }

    req = AWSRequest(method=method, url=url, data=body, headers=base_headers)
    SigV4Auth(creds, "aoss", region).add_auth(req)
    p = req.prepare()

    send_headers = dict(p.headers)
    send_headers.pop("Content-Length", None)
    send_headers.pop("content-length", None)

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
        try: hint = e.headers.get("x-aoss-response-hint")
        except Exception: pass
        body_txt = ""
        try: body_txt = e.read().decode("utf-8", "ignore")
        except Exception: pass
        print(f"[ingest] {method} {url} -> {e.code} {e.reason} (hint={hint})")
        if body_txt: print("[ingest] error body:", body_txt[:4000])
        raise

def _verify_index_exists():
    region = _region_from_endpoint(AOSS_ENDPOINT)
    url = f"{AOSS_ENDPOINT.rstrip('/')}/{INDEX_NAME}"
    resp = _signed_request("GET", url, None, region)
    print(f"[ingest] endpoint={AOSS_ENDPOINT} derived_region={_region_from_endpoint(AOSS_ENDPOINT)}")
    print("[ingest] GET index ok, status:", getattr(resp, "status", "ok"))

def _log_index_count():
    try:
        region = _region_from_endpoint(AOSS_ENDPOINT)
        url = f"{AOSS_ENDPOINT.rstrip('/')}/{INDEX_NAME}/_count"
        resp = _signed_request("GET", url, None, region)
        print("[ingest] _count:", resp.read().decode("utf-8", "ignore"))
    except Exception as e:
        print("[ingest] _count failed:", e)

# ---------- Embeddings (Bedrock Titan) ----------
def _zeros(n): return [0.0] * n

def _embed_text(text: str):
    """Return a length-EMBED_DIM vector using Titan; fallback to zeros."""
    text = (text or "").strip()
    if not text:
        return _zeros(EMBED_DIM)

    # Titan v2 accepts {"inputText": "..."} and can honor output length
    body = {"inputText": text}
    # If you want to be explicit about dimension, uncomment next line:
    # body["embeddingConfig"] = {"outputEmbeddingLength": EMBED_DIM}

    last_err = None
    for i in range(3):
        try:
            resp = bedrock.invoke_model(
                modelId=EMBED_MODEL_ID,
                body=json.dumps(body).encode("utf-8"),
                contentType="application/json",
                accept="application/json",
            )
            payload = resp["body"].read()
            out = json.loads(payload.decode("utf-8", "ignore"))
            vec = out.get("embedding") or out.get("vector")
            if not isinstance(vec, list):
                raise RuntimeError("No embedding in model response")
            # Normalize to EMBED_DIM
            if len(vec) > EMBED_DIM: vec = vec[:EMBED_DIM]
            if len(vec) < EMBED_DIM: vec = vec + [0.0]*(EMBED_DIM - len(vec))
            print(f"[embed] model={EMBED_MODEL_ID} region={BEDROCK_REGION} dim={len(vec)}")
            return vec
        except ClientError as e:
            last_err = e
            code = (e.response.get("Error") or {}).get("Code", "")
            if code in ("ThrottlingException","ModelTimeoutException","InternalServerException","ServiceUnavailableException"):
                time.sleep(0.4*(2**i))
                continue
            raise
        except Exception as e:
            last_err = e
            break
    print(f"[embed] failed, using zeros. reason={last_err}")
    return _zeros(EMBED_DIM)

# ---------- Indexing & KNN preview ----------
def _index_doc(text: str, source_key: str):
    if SKIP_AOSS or not AOSS_ENDPOINT:
        print("[ingest] SKIP_AOSS active; not indexing text")
        return
    region = _region_from_endpoint(AOSS_ENDPOINT)
    url    = f"{AOSS_ENDPOINT.rstrip('/')}/{INDEX_NAME}/_doc"

    # embed a small representative slice (Titan allows long inputs,
    # but keeping short here is fine for txt)
    to_embed = (text or "")[:4000]
    vector   = _embed_text(to_embed)

    body = {
        "text":   (text or "")[:20000],
        "vector": vector,
        "source": source_key,
        "page":   1
    }
    _signed_request("POST", url, json.dumps(body).encode("utf-8"), region)
    print(f"[ingest] indexed doc from s3://{source_key} (len={len(text or '')})")
    _log_index_count()

def _knn_preview(query_text: str, k=3):
    """Log top hits for a quick visual proof."""
    if SKIP_AOSS or not AOSS_ENDPOINT:
        return
    qvec   = _embed_text((query_text or "")[:1000])
    region = _region_from_endpoint(AOSS_ENDPOINT)
    url    = f"{AOSS_ENDPOINT.rstrip('/')}/{INDEX_NAME}/_search"
    body   = {
        "size": k,
        "_source": ["source","page","text"],
        "knn": {
            "field": "vector",
            "query_vector": qvec,
            "k": k,
            "num_candidates": 100
        }
    }
    resp = _signed_request("POST", url, json.dumps(body).encode("utf-8"), region)
    data = json.loads(resp.read().decode("utf-8","ignore"))
    hits = data.get("hits",{}).get("hits",[])
    pretty = [
        {
            "score": round(h.get("_score", 0.0), 4),
            "source": (h.get("_source",{}).get("source",""))[:120],
            "snippet": (h.get("_source",{}).get("text","")[:120]).replace("\n"," ")
        } for h in hits
    ]
    print("[knn] preview:", json.dumps(pretty))

# ---------- Index create ----------
def _index_dummy_doc():
    region = _region_from_endpoint(AOSS_ENDPOINT)
    url    = f"{AOSS_ENDPOINT.rstrip('/')}/{INDEX_NAME}/_doc"
    body   = {"text": "hello from lambda", "vector": _zeros(EMBED_DIM), "source": "self-test", "page": 1}
    _signed_request("POST", url, json.dumps(body).encode("utf-8"), region)
    print("[ingest] indexed dummy doc")
    _log_index_count()

def ensure_index():
    if SKIP_AOSS or not AOSS_ENDPOINT:
        print("[ingest] SKIP_AOSS active or OPENSEARCH_ENDPOINT empty; skipping AOSS")
        return

    region = _region_from_endpoint(AOSS_ENDPOINT)
    base   = AOSS_ENDPOINT.rstrip("/")

    try:
        _signed_request("HEAD", f"{base}/{INDEX_NAME}", None, region)
        print(f"[ingest] index '{INDEX_NAME}' exists")
        return
    except urllib.error.HTTPError as e:
        if e.code != 404:
            print("[ingest] HEAD failed (non-404); skipping index creation this invoke")
            return

    try:
        body = {
            "settings": {"index.knn": True},
            "mappings": {"properties": {
                "text":   {"type": "text"},
                "vector": {"type": "knn_vector", "dimension": EMBED_DIM},
                "source": {"type": "keyword"},
                "page":   {"type": "integer"}
            }}
        }
        _signed_request("PUT", f"{base}/{INDEX_NAME}", json.dumps(body).encode("utf-8"), region)
        print(f"[ingest] created index '{INDEX_NAME}' via PUT")
        _verify_index_exists()
        return
    except urllib.error.HTTPError as e_put:
        if getattr(e_put,"code",None) == 403:
            print("[ingest] PUT create denied (403). Trying implicit create via first document...")
            try:
                _index_dummy_doc()
                print("[ingest] index created implicitly by first document")
                return
            except urllib.error.HTTPError as e_post:
                print("[ingest] implicit create failed:", getattr(e_post,"code","?"), getattr(e_post,"reason","?"))
                raise
        else:
            raise

# ---- Event handling (supports S3 direct or SQS-wrapped S3) ----
def _extract_s3_records(event):
    out = []
    for r in event.get("Records", []):
        src = r.get("eventSource") or r.get("EventSource")
        if src == "aws:s3" and "s3" in r:
            out.append(r)
        elif src == "aws:sqs" and "body" in r:
            try:
                inner = json.loads(r["body"])
                for ir in inner.get("Records", []):
                    if ir.get("eventSource") == "aws:s3" and "s3" in ir:
                        out.append(ir)
            except Exception as e:
                print(f"[ingest] could not parse SQS body as S3 event: {e}")
    return out

def _handle_event(event):
    s3_records = _extract_s3_records(event)
    if not s3_records:
        print("[ingest] no S3 records found in event")
        return

    for r in s3_records:
        bucket = r["s3"]["bucket"]["name"]
        key    = unquote_plus(r["s3"]["object"]["key"])
        print(f"[ingest] S3 event for s3://{bucket}/{key}")

        try:
            obj = s3.get_object(Bucket=bucket, Key=key)
            body_bytes = obj["Body"].read()
            try:
                text = body_bytes.decode("utf-8", errors="replace")
            except Exception:
                text = ""
        except ClientError as e:
            print(f"[ingest] S3 get_object failed: {e}")
            continue

        _index_doc(text, f"{bucket}/{key}")
        if PREVIEW_KNN:
            _knn_preview(text[:300])

# ---- Lambda entrypoint ----
def handler(event, _ctx):
    global _index_checked
    if not _index_checked:
        ensure_index()
        _index_checked = True

    if "Records" in event:
        _handle_event(event)
    elif event.get("self_test"):
        _index_dummy_doc()
    elif event.get("count_only"):
        _log_index_count()

    print("[ingest] event (truncated):", str(event)[:800])
    return {"ok": True}
