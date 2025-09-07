import os, json, io, boto3, faiss, numpy as np

BUCKET = os.environ["S3_BUCKET"]
INDEX_PREFIX = os.environ.get("INDEX_PREFIX", "indexes/latest/")
BEDROCK_REGION = os.environ.get("BEDROCK_REGION", "ap-southeast-2")
EMBED_MODEL_ID = os.environ.get("EMBED_MODEL_ID", "amazon.titan-embed-text-v2:0")
EMBED_DIM = int(os.environ.get("EMBED_DIM", "1024"))
TOP_K = int(os.environ.get("TOP_K", "5"))

s3 = boto3.client("s3")
bedrock = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)

INDEX = None
META = []
ETAG = None

def _embed(q: str) -> np.ndarray:
    body = json.dumps({"inputText": q})
    resp = bedrock.invoke_model(modelId=EMBED_MODEL_ID,
                                accept="application/json",
                                contentType="application/json",
                                body=body)
    out = json.loads(resp["body"].read())
    v = np.array(out["embedding"], dtype="float32")
    n = np.linalg.norm(v) or 1.0
    return (v / n).astype("float32")[None, :]  # shape (1, d)

def _ensure_index_loaded():
    global INDEX, META, ETAG
    head = s3.head_object(Bucket=BUCKET, Key=INDEX_PREFIX + "index.faiss")
    new_etag = head["ETag"].strip('"')
    if INDEX is not None and ETAG == new_etag:
        return

    # download artifacts
    idx_path = "/tmp/index.faiss"
    meta_path = "/tmp/meta.jsonl"
    s3.download_file(BUCKET, INDEX_PREFIX + "index.faiss", idx_path)
    s3.download_file(BUCKET, INDEX_PREFIX + "meta.jsonl",  meta_path)

    INDEX = faiss.read_index(idx_path)
    META = [json.loads(line) for line in io.open(meta_path, "r", encoding="utf-8")]
    ETAG = new_etag

def handler(event, context):
    _ensure_index_loaded()

    body = {}
    if "body" in event and isinstance(event["body"], str):
        try: body = json.loads(event["body"])
        except: body = {}
    elif isinstance(event, dict): body = event

    q = (body.get("q") or "").strip()
    k = int(body.get("k") or TOP_K)
    if not q:
        return {"statusCode": 400, "body": json.dumps({"error": "missing q"})}

    if INDEX is None:
        return {"statusCode": 500, "body": json.dumps({"error": "FAISS index not loaded"})}

    Q = _embed(q)
    D, I = INDEX.search(Q.astype("float32"), k)
    hits = []
    for score, idx in zip(D[0].tolist(), I[0].tolist()):
        m = META[idx]
        hits.append({"score": float(score), "s3key": m["s3key"], "preview": m["preview"]})

    return {
        "statusCode": 200,
        "headers": {"content-type": "application/json"},
        "body": json.dumps({"q": q, "hits": hits})
    }
