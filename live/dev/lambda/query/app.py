# lambda/query/app.py
import os, json, urllib.request, urllib.error, hashlib, traceback
from urllib.parse import urlparse
from botocore.session import Session
from botocore.awsrequest import AWSRequest
from botocore.auth import SigV4Auth

AOSS_ENDPOINT  = os.environ["OPENSEARCH_ENDPOINT"]
INDEX_NAME     = os.environ.get("INDEX_NAME", "chunks")
BEDROCK_REGION = os.environ.get("BEDROCK_REGION", "ap-southeast-2")
EMBED_MODEL_ID = os.environ.get("EMBED_MODEL_ID", "amazon.titan-embed-text-v2:0")
CHAT_MODEL_ID  = os.environ.get("CHAT_MODEL_ID",  "anthropic.claude-3-sonnet-20240229-v1:0")
EMBED_DIM      = int(os.environ.get("EMBED_DIM", "1024"))
VEC_FIELD      = os.environ.get("VEC_FIELD", "vector")

_sess = Session()
bedrock = _sess.create_client("bedrock-runtime", region_name=BEDROCK_REGION)

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

def _embed(text: str):
    body = {"inputText": (text or "")[:4000], "embeddingConfig": {"outputEmbeddingLength": EMBED_DIM}}
    r = bedrock.invoke_model(
        modelId=EMBED_MODEL_ID,
        body=json.dumps(body).encode("utf-8"),
        contentType="application/json",
        accept="application/json",
    )
    out = json.loads(r["body"].read().decode("utf-8","ignore"))
    vec = out.get("embedding") or out.get("vector") or []
    if len(vec) > EMBED_DIM: vec = vec[:EMBED_DIM]
    if len(vec) < EMBED_DIM: vec = vec + [0.0]*(EMBED_DIM-len(vec))
    return vec

def _knn(vec, k=5):
    url = f"{AOSS_ENDPOINT.rstrip('/')}/{INDEX_NAME}/_search"
    body = {
        "size": k,
        "_source": ["source","page","text"],
        "query": {"knn": { VEC_FIELD: { "vector": vec, "k": k } }}
    }
    resp = _signed_request("POST", url, json.dumps(body).encode("utf-8"), _region_from_endpoint(AOSS_ENDPOINT))
    data = json.loads(resp.read().decode("utf-8","ignore"))
    return data.get("hits",{}).get("hits",[])

def _build_messages(question: str, hits):
    context = []
    for i,h in enumerate(hits, start=1):
        s = h.get("_source", {})
        context.append(f"[{i}] SOURCE={s.get('source','')} page={s.get('page')}\n{s.get('text','')}")
    ctx = "\n\n".join(context)
    txt = (
      "You are a careful assistant. Answer ONLY from the sources below. "
      "If unsure, say you don't know. Cite sources like [1], [2].\n\n"
      f"QUESTION:\n{question}\n\nSOURCES:\n{ctx}"
    )
    return [{"role":"user","content":[{"type":"text","text":txt}]}]

def _cors():
    return {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "POST,OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type"
    }

def _err(status, msg, where=None, exc=None):
    if exc:
        print(f"[error] {where}: {exc}\n{traceback.format_exc()}")
    body = {"error": msg}
    if where: body["where"] = where
    return {"statusCode": status, "headers": _cors(), "body": json.dumps(body)}

def handler(event, _ctx):
    # CORS preflight
    if event.get("requestContext",{}).get("http",{}).get("method") == "OPTIONS":
        return {"statusCode": 200, "headers": _cors(), "body": ""}

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

    # 1) embed
    try:
        qvec = _embed(q)
    except Exception as e:
        return _err(502, "embed failed (Titan)", "embed", e)

    # 2) search
    try:
        hits = _knn(qvec, k=5)
    except Exception as e:
        return _err(502, "search failed (AOSS)", "search", e)

    # 3) compose + chat
    try:
        msgs = _build_messages(q, hits)
        r = bedrock.invoke_model(
            modelId=CHAT_MODEL_ID,
            body=json.dumps({"anthropic_version":"bedrock-2023-05-31","max_tokens":700,"messages":msgs}).encode("utf-8"),
            contentType="application/json",
            accept="application/json",
        )
        out = json.loads(r["body"].read().decode("utf-8","ignore"))
        answer = (out.get("content") or [{}])[0].get("text","")
    except Exception as e:
        return _err(502, "chat failed (Claude)", "chat", e)

    citations = [
      {"source": h.get("_source",{}).get("source"), "page": h.get("_source",{}).get("page"), "score": h.get("_score")}
      for h in hits
    ]
    return {"statusCode": 200, "headers": _cors(), "body": json.dumps({"answer": answer, "citations": citations})}
