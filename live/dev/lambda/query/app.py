# lambda/query/app.py
import os, json, urllib.request, urllib.error, hashlib, traceback, time, random
from urllib.parse import urlparse
from botocore.session import Session
from botocore.awsrequest import AWSRequest
from botocore.auth import SigV4Auth
from botocore.exceptions import ClientError

# ---------- Config (env) ----------
AOSS_ENDPOINT   = os.environ["OPENSEARCH_ENDPOINT"]
INDEX_NAME      = os.environ.get("INDEX_NAME", "chunks")

BEDROCK_REGION  = os.environ.get("BEDROCK_REGION", "ap-southeast-2")
EMBED_MODEL_ID  = os.environ.get("EMBED_MODEL_ID", "amazon.titan-embed-text-v2:0")

# Primary chat model (Sonnet by default) + cheap fallback (Haiku)
CHAT_MODEL_ID    = os.environ.get("CHAT_MODEL_ID",     "anthropic.claude-3-sonnet-20240229-v1:0")
CHAT_FALLBACK_ID = os.environ.get("CHAT_FALLBACK_ID",  "anthropic.claude-3-haiku-20240307-v1:0")

# Pacing (per warm container) to avoid hitting low TPS/chat bursts
CHAT_MIN_GAP_MS  = int(os.environ.get("CHAT_MIN_GAP_MS", "1400"))

EMBED_DIM        = int(os.environ.get("EMBED_DIM", "1024"))
VEC_FIELD        = os.environ.get("VEC_FIELD", "vector")
MAX_CTX_SNIPPET  = int(os.environ.get("MAX_CTX_SNIPPET", "120"))

# ---------- Clients ----------
_sess   = Session()
bedrock = _sess.create_client("bedrock-runtime", region_name=BEDROCK_REGION)

# ---------- Utilities ----------
def _region_from_endpoint(endpoint: str) -> str:
    host = endpoint.replace("https://","").split("/")[0]
    parts = host.split(".")
    return parts[1] if len(parts) >= 3 and parts[2] == "aoss" else os.environ.get("AWS_REGION", BEDROCK_REGION)

def _signed_request(method: str, url: str, body: bytes, region: str):
    body = body or b""
    if isinstance(body, str): body = body.encode("utf-8")
    payload_hash = hashlib.sha256(body).hexdigest()
    creds = _sess.get_credentials().get_frozen_credentials()
    host = urlparse(url).netloc
    headers = {
        "host": host,
        "content-type": "application/json",
        "accept": "application/json",
        "x-amz-content-sha256": payload_hash,
    }
    req = AWSRequest(method=method, url=url, data=body, headers=headers)
    SigV4Auth(creds, "aoss", region).add_auth(req)
    p = req.prepare()
    h = dict(p.headers); h.pop("Content-Length", None); h.pop("content-length", None)
    return urllib.request.urlopen(urllib.request.Request(p.url, data=body, method=p.method, headers=h))

def _cors():
    return {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "POST,OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type"
    }

def _json_headers():
    h = _cors()
    h["Content-Type"] = "application/json"
    return h

def _err(status, msg, where=None, exc=None):
    body = {"error": msg}
    if where: body["where"] = where
    if exc:
        print(f"[error] {where}: {exc}\n{traceback.format_exc()}")
        if isinstance(exc, ClientError):
            err = exc.response.get("Error") or {}
            body["bedrock_code"] = err.get("Code")
            body["bedrock_message"] = err.get("Message")
    return {"statusCode": status, "headers": _json_headers(), "body": json.dumps(body)}

# ---------- Embedding ----------
def _embed(text: str):
    body = {"inputText": (text or "")[:4000]}
    last = None
    for i in range(4):  # retries with small backoff
        try:
            r = bedrock.invoke_model(
                modelId=EMBED_MODEL_ID,
                body=json.dumps(body).encode("utf-8"),
                contentType="application/json",
                accept="application/json",
            )
            out = json.loads(r["body"].read().decode("utf-8","ignore"))
            vec = out.get("embedding") or out.get("vector") or []
            if len(vec) > EMBED_DIM: vec = vec[:EMBED_DIM]
            if len(vec) < EMBED_DIM: vec = vec + [0.0]*(EMBED_DIM - len(vec))
            return vec
        except ClientError as e:
            code = (e.response.get("Error") or {}).get("Code","")
            if code in ("ThrottlingException","ModelTimeoutException","ServiceUnavailableException","InternalServerException"):
                time.sleep(0.35 * (2**i))
                last = e
                continue
            raise
    raise last or RuntimeError("embed failed")

# ---------- Search (KNN) ----------
def _knn(vec, k=10):
    url = f"{AOSS_ENDPOINT.rstrip('/')}/{INDEX_NAME}/_search"
    body = {
        "size": k,
        "_source": ["source","page","text"],
        "query": {"knn": { VEC_FIELD: { "vector": vec, "k": k } }}
    }
    resp = _signed_request("POST", url, json.dumps(body).encode("utf-8"), _region_from_endpoint(AOSS_ENDPOINT))
    data = json.loads(resp.read().decode("utf-8","ignore"))
    return data.get("hits",{}).get("hits",[])

def _dedupe_hits(hits, want=3):
    out, seen = [], set()
    for h in hits:
        s = h.get("_source", {}) or {}
        if s.get("source") == "self-test":
            continue
        key = (s.get("source"), s.get("page"), (s.get("text","")[:160]))
        if key in seen:
            continue
        seen.add(key)
        out.append(h)
        if len(out) >= want:
            break
    return out

# ---------- Prompt ----------
def _build_messages(question: str, hits):
    blocks = []
    for i,h in enumerate(hits, start=1):
        s = h.get("_source", {}) or {}
        blocks.append(f"[{i}] SOURCE={s.get('source','')} page={s.get('page')}\n{s.get('text','')}")
    ctx = "\n\n".join(blocks)
    prompt = (
      "You are a careful assistant. Answer ONLY from the sources below. "
      "If unsure, say you don't know. Cite sources like [1], [2].\n\n"
      f"QUESTION:\n{question}\n\nSOURCES:\n{ctx}"
    )
    return [{"role":"user","content":[{"type":"text","text":prompt}]}]

# ---------- Chat (pacing + retries + fallback) ----------
_last_chat_ts = 0.0
def _respect_min_gap():
    global _last_chat_ts
    now = time.time()
    gap_s = CHAT_MIN_GAP_MS / 1000.0
    wait = gap_s - (now - _last_chat_ts)
    if wait > 0:
        time.sleep(wait)
    _last_chat_ts = time.time()

def _chat_once(messages, model_id):
    payload = {"anthropic_version":"bedrock-2023-05-31","max_tokens":700,"messages":messages}
    _respect_min_gap()
    r = bedrock.invoke_model(
        modelId=model_id,
        body=json.dumps(payload).encode("utf-8"),
        contentType="application/json",
        accept="application/json",
    )
    out = json.loads(r["body"].read().decode("utf-8","ignore"))
    return (out.get("content") or [{}])[0].get("text","")

def _chat_with_retries(messages, model_id, attempts=4):
    last = None
    for i in range(attempts):
        try:
            return _chat_once(messages, model_id)
        except ClientError as e:
            code = (e.response.get("Error") or {}).get("Code","")
            if code in ("ThrottlingException","ModelTimeoutException","ServiceUnavailableException","InternalServerException"):
                # exponential backoff + jitter
                sleep = (1.0 + random.random()*0.5) * (2 ** i)  # ~1.0s, 2.1s, 4.4s, 8.8s
                time.sleep(sleep)
                last = e
                continue
            raise
    raise last or RuntimeError("chat failed after retries")

# ---------- Tiny in-memory cache (per warm container) ----------
_cache = {"q": None, "resp": None, "ts": 0.0}
def _get_cached(q):
    if _cache["q"] == q and time.time() - _cache["ts"] < 60:
        return _cache["resp"]
def _set_cached(q, resp):
    _cache.update({"q": q, "resp": resp, "ts": time.time()})

# ---------- Lambda handler ----------
def handler(event, _ctx):
    # CORS preflight
    if event.get("requestContext",{}).get("http",{}).get("method") == "OPTIONS":
        return {"statusCode": 200, "headers": _json_headers(), "body": ""}

    # Parse body
    try:
        if isinstance(event.get("body"), str):
            body = json.loads(event["body"])
        elif isinstance(event, dict):
            body = event
        else:
            body = {}
    except Exception as e:
        return _err(400, "invalid JSON", "parse", e)

    q = (body.get("q") or body.get("question") or "").strip()
    if not q:
        return _err(400, "missing q")

    cached = _get_cached(q)
    if cached:
        return {"statusCode": 200, "headers": _json_headers(), "body": json.dumps(cached)}

    # 1) embed
    try:
        qvec = _embed(q)
    except Exception as e:
        return _err(502, "embed failed (Titan)", "embed", e)

    # 2) search
    try:
        raw_hits = _knn(qvec, k=10)
        hits = _dedupe_hits(raw_hits, want=3)
    except Exception as e:
        return _err(502, "search failed (AOSS)", "search", e)

    if not hits:
        resp = {"answer": "I couldn’t find anything relevant in the knowledge base.", "citations": []}
        _set_cached(q, resp)
        return {"statusCode": 200, "headers": _json_headers(), "body": json.dumps(resp)}

    # 3) compose + chat (with fallback)
    try:
        msgs = _build_messages(q, hits)
        try:
            answer = _chat_with_retries(msgs, CHAT_MODEL_ID, attempts=4)
        except ClientError as e:
            err_code = (e.response.get("Error") or {}).get("Code","")
            if err_code == "ThrottlingException" and CHAT_FALLBACK_ID:
                answer = _chat_with_retries(msgs, CHAT_FALLBACK_ID, attempts=4)
            else:
                raise
    except Exception as e:
        return _err(502, "chat failed (Claude)", "chat", e)

    def snip(t: str) -> str:
        return (t or "").replace("\n"," ")[:MAX_CTX_SNIPPET]

    citations = [
      {"source": s.get("source"), "page": s.get("page"), "score": h.get("_score"), "snippet": snip(s.get("text") or "")}
      for h in hits
      for s in [h.get("_source", {}) or {}]
    ]

    resp = {"answer": answer, "citations": citations}
    _set_cached(q, resp)
    return {"statusCode": 200, "headers": _json_headers(), "body": json.dumps(resp)}
