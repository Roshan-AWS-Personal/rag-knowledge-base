import os, json, io, boto3, faiss, numpy as np, uuid, mimetypes, datetime, textwrap
from botocore.exceptions import ClientError

BUCKET = os.environ["S3_BUCKET"]
DOCS_PREFIX = os.environ.get("DOCS_PREFIX", "docs/")
INDEX_PREFIX = os.environ.get("INDEX_PREFIX", "indexes/latest/")
BEDROCK_REGION = os.environ.get("BEDROCK_REGION", "ap-southeast-2")
EMBED_MODEL_ID = os.environ.get("EMBED_MODEL_ID", "amazon.titan-embed-text-v2:0")
EMBED_DIM = int(os.environ.get("EMBED_DIM", "1024"))
CHUNK_SIZE = int(os.environ.get("CHUNK_SIZE", "500"))   # characters
CHUNK_OVERLAP = int(os.environ.get("CHUNK_OVERLAP", "50"))

s3 = boto3.client("s3")
bedrock = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)

def _embed(text: str) -> np.ndarray:
    body = json.dumps({"inputText": text})
    resp = bedrock.invoke_model(modelId=EMBED_MODEL_ID,
                                accept="application/json",
                                contentType="application/json",
                                body=body)
    out = json.loads(resp["body"].read())
    vec = np.array(out["embedding"], dtype="float32")
    norm = np.linalg.norm(vec) or 1.0
    return (vec / norm).astype("float32")

def _chunk_text(text: str, size: int = CHUNK_SIZE, overlap: int = CHUNK_OVERLAP):
    text = text.strip()
    if not text:
        return []
    chunks = []
    start = 0
    while start < len(text):
        end = min(len(text), start + size)
        chunk = text[start:end]
        chunks.append(chunk)
        start += size - overlap
    return chunks

def handler(event, context):
    # Collect docs
    entries = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET, Prefix=DOCS_PREFIX):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if not key.lower().endswith(".txt"): 
                continue
            raw = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read().decode("utf-8", "ignore")
            if not raw.strip():
                continue
            # Metadata
            doc_id = str(uuid.uuid4())
            title = os.path.basename(key)
            mime, _ = mimetypes.guess_type(title)
            uploaded_at = obj.get("LastModified", datetime.datetime.utcnow()).isoformat()
            tags = []
            chunks = _chunk_text(raw)
            for i, chunk in enumerate(chunks):
                entries.append({
                    "doc_id": doc_id,
                    "title": title,
                    "s3_uri": f"s3://{BUCKET}/{key}",
                    "uploaded_at": uploaded_at,
                    "mime": mime or "text/plain",
                    "tags": tags,
                    "chunk_id": f"{doc_id}_{i}",
                    "text": chunk,
                })

    if not entries:
        return {"statusCode": 200, "body": json.dumps({"ok": True, "msg": "no docs"})}

    # Embed all
    vecs = [_embed(e["text"]) for e in entries]
    X = np.vstack(vecs).astype("float32")

    # Build FAISS index
    index = faiss.IndexFlatIP(EMBED_DIM)
    index.add(X)

    # Write artifacts
    faiss_path = "/tmp/index.faiss"
    meta_path  = "/tmp/meta.jsonl"
    faiss.write_index(index, faiss_path)
    with io.open(meta_path, "w", encoding="utf-8") as f:
        for i, e in enumerate(entries):
            e_out = {k: v for k,v in e.items() if k != "text"}  # store metadata only
            e_out["preview"] = e["text"][:300]
            e_out["i"] = i
            f.write(json.dumps(e_out) + "\n")

    # Upload
    s3.upload_file(faiss_path, BUCKET, INDEX_PREFIX + "index.faiss")
    s3.upload_file(meta_path,  BUCKET, INDEX_PREFIX + "meta.jsonl")

    return {"statusCode": 200, "body": json.dumps({"ok": True, "count": len(entries)})}
