# lambdas/query/app.py
import os, json, boto3
from opensearchpy import OpenSearch, RequestsHttpConnection

BEDROCK_REGION = os.environ["BEDROCK_REGION"]
CHAT_MODEL_ID  = os.environ["CHAT_MODEL_ID"]
INDEX          = os.environ["INDEX_NAME"]
OS_ENDPOINT    = os.environ["OPENSEARCH_ENDPOINT"]

brt = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)
os_client = OpenSearch(
    hosts=[{"host": OS_ENDPOINT.replace("https://",""), "port": 443}],
    use_ssl=True, verify_certs=True, connection_class=RequestsHttpConnection
)

SYS_PROMPT = """You are a helpful assistant. Use ONLY the context below to answer.
If unsure, say you don't know. Cite sources as [#]."""

def handler(event, _ctx):
    q = json.loads(event.get("body") or "{}").get("query","")
    # vector search (if you saved vectors) OR text BM25 if you didn't yet
    res = os_client.search(index=INDEX, body={"size": 5, "query": {"match": {"text": q}}})
    ctx_blocks = []
    for i,h in enumerate(res["hits"]["hits"], start=1):
        ctx_blocks.append(f"[{i}] {h['_source']['text'][:800]}")

    prompt = f"{SYS_PROMPT}\n\nContext:\n" + "\n".join(ctx_blocks) + f"\n\nQ: {q}\nA:"
    body = { "anthropic_version":"bedrock-2023-05-31",
             "max_tokens": 512,
             "messages":[{"role":"user","content":prompt}] }

    resp = brt.invoke_model(modelId=CHAT_MODEL_ID,
                            body=json.dumps(body),
                            contentType="application/json",
                            accept="application/json")
    out = json.loads(resp["body"].read())
    # extract text depending on model schema
    answer = out.get("output_text") or out.get("content",[{}])[0].get("text","")
    return {"statusCode":200, "headers":{"Content-Type":"application/json"},
            "body": json.dumps({"answer": answer, "contexts": ctx_blocks}) }
