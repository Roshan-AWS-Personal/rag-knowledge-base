import os, json, io, boto3, faiss, numpy as np
from botocore.exceptions import ClientError

BUCKET = os.environ["S3_BUCKET"]
DOCS_PREFIX = os.environ.get("DOCS_PREFIX", "docs/")
INDEX_PREFIX = os.environ.get("INDEX_PREFIX", "indexes/latest/")
BEDROCK_REGION = os.environ.get("BEDROCK_REGION", "ap-southeast-2")
EMBED_MODEL_ID = os.environ.get("EMBED_MODEL_ID", "amazon.titan-embed-text-v2:0")
EMBED_DIM = int(os.environ.get("EMBED_DIM", "1024"))

s3 = boto3.client("s3")
bedrock = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)

def _embed(text: str) -> np.ndarray:
    # Titan v2 expects {"inputText": "..."}
    body = json.dumps({"inputText": text})
    resp = bedrock.invoke_model(modelId=EMBED_MODEL_ID,
                                accept="application/json",
                                contentType="application/json",
                                body=body)
    out = json.loads(resp["body"].read())
    vec = np.array(out["embedding"], dtype="float32")
    # Use cosine similarity via inner product => normalize
    norm = np.linalg.norm(vec) or 1.0
    return (vec / norm).astype("float32")

def handler(event, context):
    # 1) read docs from S3 (simple: each .txt is one chunk)
    keys, texts = [], []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET, Prefix=DOCS_PREFIX):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if not key.lower().endswith(".txt"): continue
            data = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read().decode("utf-8", "ignore")
            if data.strip():
                keys.append(key); texts.append(data.strip())

    if not texts:
        return {"statusCode": 200, "body": json.dumps({"ok": True, "msg": "no docs"})}

    # 2) embed
    vecs = [ _embed(t) for t in texts ]
    X = np.vstack(vecs).astype("float32")

    # 3) build FAISS (inner product)
    index = faiss.IndexFlatIP(EMBED_DIM)
    index.add(X)

    # 4) write artifacts to /tmp
    faiss_path = "/tmp/index.faiss"
    meta_path  = "/tmp/meta.jsonl"
    faiss.write_index(index, faiss_path)
    with io.open(meta_path, "w", encoding="utf-8") as f:
        for i, (k, t) in enumerate(zip(keys, texts)):
            f.write(json.dumps({"i": i, "s3key": k, "preview": t[:300]}) + "\n")

    # 5) upload to S3
    s3.upload_file(faiss_path, BUCKET, INDEX_PREFIX + "index.faiss")
    s3.upload_file(meta_path,  BUCKET, INDEX_PREFIX + "meta.jsonl")

    return {"statusCode": 200, "body": json.dumps({"ok": True, "count": len(texts)})}
