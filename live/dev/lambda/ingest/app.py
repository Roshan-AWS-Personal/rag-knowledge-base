# lambdas/ingest/app.py
import os, json, boto3, base64, gzip, io
from opensearchpy import OpenSearch, RequestsHttpConnection

BEDROCK_REGION = os.environ["BEDROCK_REGION"]
EMBED_MODEL_ID = os.environ["EMBED_MODEL_ID"]
INDEX          = os.environ["INDEX_NAME"]
OS_ENDPOINT    = os.environ["OPENSEARCH_ENDPOINT"]

brt = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)
s3  = boto3.client("s3")

os_client = OpenSearch(
    hosts=[{"host": OS_ENDPOINT.replace("https://",""), "port": 443}],
    use_ssl=True, verify_certs=True, connection_class=RequestsHttpConnection
)

def embed(text: str):
    body = { "inputText": text }  # adjust to model schema if needed
    resp = brt.invoke_model(
        modelId=EMBED_MODEL_ID,
        body=json.dumps(body),
        contentType="application/json",
        accept="application/json"
    )
    data = json.loads(resp["body"].read())
    # normalize: pick the vector field your model returns
    return data["embedding"] or data["vector"]  # adjust

def handler(event, _ctx):
    # event from SQS -> records with S3 PutObject notifications
    for record in event["Records"]:
        s3evt = json.loads(record["body"])["Records"][0]
        bkt, key = s3evt["s3"]["bucket"]["name"], s3evt["s3"]["object"]["key"]
        obj = s3.get_object(Bucket=bkt, Key=key)["Body"].read().decode("utf-8")

        # naive split (replace with better chunker later)
        chunks = [obj[i:i+1000] for i in range(0, len(obj), 1000)]
        docs = []
        for i, chunk in enumerate(chunks):
            vec = embed(chunk)
            docs.append({"id": f"{key}:{i}", "vector": vec, "text": chunk})

        # bulk upsert (adjust to your index mapping)
        actions = []
        for d in docs:
            actions.append(json.dumps({ "index": {"_index": INDEX, "_id": d["id"]}}))
            actions.append(json.dumps({ "text": d["text"], "vector": d["vector"]}))
        body = "\n".join(actions) + "\n"
        os_client.bulk(body=body)
    return {"ok": True}
