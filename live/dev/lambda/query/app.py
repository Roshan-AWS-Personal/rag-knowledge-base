import os, json, io, boto3, faiss, numpy as np

BUCKET = os.environ["S3_BUCKET"]
INDEX_PREFIX = os.environ.get("INDEX_PREFIX", "indexes/latest/")
BEDROCK_REGION = os.environ.get("BEDROCK_REGION", "ap-southeast-2")
EMBED_MODEL_ID = os.environ.get("EMBED_MODEL_ID", "amazon.titan-embed-text-v2:0")
CHAT_MODEL_ID  = os.environ.get("CHAT_MODEL_ID",  "anthropic.claude-3-sonnet-20240229-v1:0")
EMBED_DIM = int(os.environ.get("EMBED_DIM", "1024"))
TOP_K = int(os.environ.get("TOP_K", "5"))

s3 = boto3.client("s3")
bedrock = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)

INDEX = None
META = []
ETAG = None

def _embed(q: str) -> np.ndarray:
    body = json.dumps({"inputText": q})
    resp = bedrock.invoke_model(
        modelId=EMBED_MODEL_ID,
        accept="application/json",
        contentType="application/json",
        body=body
    )
    out = json.loads(resp["body"].read())
    v = np.array(out["embedding"], dtype="float32")
    n = np.linalg.norm(v) or 1.0
    return (v / n).astype("float32")[None, :]  # (1, d)

def _ensure_index_loaded():
    global INDEX, META, ETAG
    head = s3.head_object(Bucket=BUCKET, Key=INDEX_PREFIX + "index.faiss")
    new_etag = head["ETag"].strip('"')
    if INDEX is not None and ETAG == new_etag:
        return
    idx_path = "/tmp/index.faiss"
    meta_path = "/tmp/meta.jsonl"
    s3.download_file(BUCKET, INDEX_PREFIX + "index.faiss", idx_path)
    s3.download_file(BUCKET, INDEX_PREFIX + "meta.jsonl",  meta_path)
    INDEX = faiss.read_index(idx_path)
    META = [json.loads(line) for line in io.open(meta_path, "r", encoding="utf-8")]
    ETAG = new_etag

def _select_hits(q_vec: np.ndarray, k: int):
    # Clamp k to the number of vectors we actually have.
    k = max(1, min(k, len(META)))
    D, I = INDEX.search(q_vec.astype("float32"), k)
    results = []
    for dist, idx in zip(D[0].tolist(), I[0].tolist()):
        if idx == -1:  # FAISS filler when not enough neighbors
            continue
        m = META[idx]
        # you can transform dist to similarity if needed; we keep it internal
        results.append({
            "idx": idx,
            "distance": float(dist),
            "s3key": m.get("s3key"),
            "preview": m.get("preview", "")
        })
    return results

def _build_context(hits, max_chars=1800):
    """Concatenate previews until max_chars."""
    buf, used = [], 0
    for h in hits:
        snippet = h.get("preview") or ""
        if not snippet:
            continue
        if used + len(snippet) + 100 > max_chars:
            break
        buf.append(f"- From {h.get('s3key')}: {snippet}")
        used += len(snippet) + 1
    return "\n".join(buf)

def _chat_with_bedrock(question: str, context: str, system: str | None = None, max_tokens: int = 600):
    # Anthropic Claude via Bedrock (messages API)
    payload = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": max_tokens,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text":
                        (
                          (f"System guidance:\n{system}\n\n" if system else "") +
                          "You are a concise assistant that answers using ONLY the provided context. "
                          "If the answer isn't in the context, say you don't know.\n\n"
                          f"Question:\n{question}\n\n"
                          f"Context:\n{context}"
                        )
                    }
                ]
            }
        ]
    }
    # Alternatively, you can pass top-level "system": "...", but in Bedrock's Anthropics
    # it's supported as a top-level field. This inline form works well too.
    resp = bedrock.invoke_model(
        modelId=CHAT_MODEL_ID,
        accept="application/json",
        contentType="application/json",
        body=json.dumps(payload)
    )
    data = json.loads(resp["body"].read())
    # Extract text from the first content block
    try:
        text = "".join(part.get("text","") for part in data["content"][0]["text"] if isinstance(part, dict))  # for older schemas
    except Exception:
        # Newer schema: list of blocks with {"type":"text","text": "..."}
        blocks = data.get("content", [])
        text_parts = []
        for b in blocks:
            if isinstance(b, dict) and b.get("type") == "text":
                text_parts.append(b.get("text",""))
        text = "".join(text_parts) or data.get("output_text") or ""
    return text.strip() or "I couldn't find the answer in the indexed context."

def _response(status: int, body: dict):
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            # permissive CORS for dev; tighten in prod
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type,Authorization",
            "Access-Control-Allow-Methods": "POST,OPTIONS"
        },
        "body": json.dumps(body)
    }

def handler(event, context):
    if event.get("httpMethod") == "OPTIONS":  # CORS preflight
        return _response(200, {"ok": True})

    _ensure_index_loaded()

    body = {}
    if isinstance(event, dict) and isinstance(event.get("body"), str):
        try:
            body = json.loads(event["body"])
        except:
            body = {}
    elif isinstance(event, dict):
        body = event

    q = (body.get("q") or "").strip()
    k = int(body.get("k") or TOP_K)
    system = (body.get("system") or "").strip() or None

    if not q:
        return _response(400, {"error": "missing q"})
    if INDEX is None:
        return _response(500, {"error": "FAISS index not loaded"})

    # 1) retrieve
    q_vec = _embed(q)
    hits = _select_hits(q_vec, k)

    # 2) generate
    context_text = _build_context(hits)
    answer = _chat_with_bedrock(q, context_text, system=system)

    # 3) return friendly shape for your UI
    sources = [{"key": h["s3key"], "preview": h["preview"]} for h in hits]
    return _response(200, {"answer": answer, "sources": sources})
