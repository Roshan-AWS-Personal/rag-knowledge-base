import os, json, io, time, random
from typing import Any, Dict, List, Optional, cast
import boto3
from botocore.exceptions import ClientError
import faiss  # type: ignore
import numpy as np

BUCKET = os.environ["S3_BUCKET"]
INDEX_PREFIX = os.environ.get("INDEX_PREFIX", "indexes/latest/")
BEDROCK_REGION = os.environ.get("BEDROCK_REGION", "ap-southeast-2")
EMBED_MODEL_ID = os.environ.get("EMBED_MODEL_ID", "amazon.titan-embed-text-v2:0")
CHAT_MODEL_ID  = os.environ.get("CHAT_MODEL_ID",  "anthropic.claude-3-sonnet-20240229-v1:0")
EMBED_DIM = int(os.environ.get("EMBED_DIM", "1024"))
TOP_K = int(os.environ.get("TOP_K", "5"))

s3 = boto3.client("s3")
bedrock = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)

INDEX: Optional[faiss.Index] = None
META: List[Dict[str, Any]] = []
ETAG: Optional[str] = None

# -----------------------------
# Bedrock invoke with retries
# -----------------------------
def _invoke_json_with_retry(
    model_id: str,
    payload: Dict[str, Any],
    *,
    accept: str = "application/json",
    content_type: str = "application/json",
    tries: int = 5,
    base: float = 0.4,
    cap: float = 4.0,
) -> Dict[str, Any]:
    """Invoke Bedrock and return parsed JSON. Retries on throttling with backoff + jitter."""
    delay = base
    last_exc: Optional[Exception] = None
    last_body: Optional[str] = None

    for attempt in range(1, tries + 1):
        try:
            resp: Dict[str, Any] = bedrock.invoke_model(
                modelId=model_id,
                accept=accept,
                contentType=content_type,
                body=json.dumps(payload),
            )
            stream: Any = resp.get("body")
            if stream is None or not hasattr(stream, "read"):
                raise RuntimeError("Bedrock response missing streaming body")
            raw_bytes: bytes = cast(bytes, stream.read())
            body_str: str = raw_bytes.decode("utf-8", errors="replace")
            last_body = body_str
            return json.loads(body_str)
        except ClientError as e:
            code = e.response.get("Error", {}).get("Code", "")
            if code in ("ThrottlingException", "Throttling", "TooManyRequestsException"):
                last_exc = e
                if attempt == tries:
                    break
                time.sleep(delay + random.random() * 0.2)
                delay = min(delay * 2, cap)
                continue
            raise
        except Exception as e:
            last_exc = e
            if attempt == tries:
                break
            time.sleep(delay + random.random() * 0.2)
            delay = min(delay * 2, cap)

    msg = f"Bedrock invoke failed after {tries} attempts."
    if last_exc:
        msg += f" Error: {last_exc}"
    if last_body:
        msg += f" Body: {last_body[:200]}..."
    raise RuntimeError(msg)

# -----------------------------
# Embedding / FAISS helpers
# -----------------------------
def _embed(q: str) -> np.ndarray:
    out = _invoke_json_with_retry(EMBED_MODEL_ID, {"inputText": q})
    emb = out.get("embedding")
    if not isinstance(emb, list):
        raise ValueError("Embedding response malformed: missing 'embedding' list")
    v = np.array(emb, dtype=np.float32)
    if v.ndim != 1:
        v = v.reshape(-1)
    n = float(np.linalg.norm(v)) or 1.0
    v = (v / n).astype(np.float32, copy=False)[None, :]  # (1, d)
    # Optional: check dimension, but don't crash if different
    # if v.shape[1] != EMBED_DIM: pass
    return v

def _ensure_index_loaded() -> None:
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

def _select_hits(index: faiss.Index, meta: List[Dict[str, Any]], q_vec: np.ndarray, k: int) -> List[Dict[str, Any]]:
    k = max(1, min(k, len(meta)))
    q_arr: np.ndarray = q_vec.astype(np.float32, copy=False)
    # FAISS lacks precise type stubs; suppress Pylance confusion on this call:
    D, I = index.search(q_arr, k)  # type: ignore[attr-defined]
    results: List[Dict[str, Any]] = []
    dlist = cast(List[float], D[0].tolist())
    ilist = cast(List[int], I[0].tolist())
    for dist, idx in zip(dlist, ilist):
        if idx == -1:
            continue
        m = meta[idx]
        results.append({
            "idx": idx,
            "distance": float(dist),
            "s3key": m.get("s3key"),
            "preview": m.get("preview", ""),
        })
    return results

def _build_context(hits: List[Dict[str, Any]], max_chars: int = 1800) -> str:
    buf: List[str] = []
    used = 0
    for h in hits:
        snippet = (h.get("preview") or "").strip()
        if not snippet:
            continue
        if used + len(snippet) + 100 > max_chars:
            break
        buf.append(f"- From {h.get('s3key')}: {snippet}")
        used += len(snippet) + 1
    return "\n".join(buf)

# -----------------------------
# Chat (Claude via Bedrock)
# -----------------------------
def _chat_with_bedrock(question: str, context: str, system: Optional[str] = None, max_tokens: int = 300) -> str:
    payload: Dict[str, Any] = {
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
    data = _invoke_json_with_retry(CHAT_MODEL_ID, payload)

    # Primary: blocks [{"type":"text","text":"..."}]
    blocks = data.get("content")
    if isinstance(blocks, list):
        parts: List[str] = []
        for b in blocks:
            if isinstance(b, dict) and b.get("type") == "text":
                t = b.get("text")
                if isinstance(t, str):
                    parts.append(t)
        if parts:
            return "".join(parts).strip()

    # Fallback: older nested form
    try:
        items = data["content"][0]["text"]  # type: ignore[index]
        if isinstance(items, list):
            out = "".join(part.get("text", "") for part in items if isinstance(part, dict)).strip()
            if out:
                return out
    except Exception:
        pass

    # Last resorts
    for k in ("output_text", "completion", "answer"):
        val = data.get(k)
        if isinstance(val, str) and val.strip():
            return val.strip()

    return "I couldn't find the answer in the indexed context."

# -----------------------------
# HTTP / Lambda
# -----------------------------
def _response(status: int, body: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type,Authorization",
            "Access-Control-Allow-Methods": "POST,OPTIONS",
        },
        "body": json.dumps(body),
    }

def handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    if event.get("httpMethod") == "OPTIONS":
        return _response(200, {"ok": True})

    _ensure_index_loaded()

    body: Dict[str, Any] = {}
    raw = event.get("body")
    if isinstance(raw, str):
        try:
            body = json.loads(raw)
        except Exception:
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

    q_vec = _embed(q)
    hits = _select_hits(INDEX, META, q_vec, k)

    context_text = _build_context(hits)
    answer = _chat_with_bedrock(q, context_text, system=system)

    sources = [{"key": h["s3key"], "preview": h["preview"]} for h in hits]
    return _response(200, {"answer": answer, "sources": sources})
