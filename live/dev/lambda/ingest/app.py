import os
import json
import boto3
from botocore.session import Session
from opensearchpy import OpenSearch, RequestsHttpConnection, AWSV4SignerAuth

AOSS_ENDPOINT = os.environ["OPENSEARCH_ENDPOINT"]          # e.g., https://xxxx.aoss.ap-southeast-2.amazonaws.com
INDEX_NAME    = os.environ.get("INDEX_NAME", "chunks")
EMBED_DIM     = int(os.environ.get("EMBED_DIM", "1024"))

def _aoss_region_from_endpoint(endpoint: str) -> str:
    # ...aoss.<region>.amazonaws.com
    host = endpoint.replace("https://", "").split("/")
    parts = host[0].split(".")
    # parts = [<id>, "aoss", "<region>", "amazonaws", "com"]
    return parts[2]

def os_client():
    region = _aoss_region_from_endpoint(AOSS_ENDPOINT)
    creds  = Session().get_credentials()
    auth   = AWSV4SignerAuth(creds, region, service="aoss")
    host   = AOSS_ENDPOINT.replace("https://", "")
    return OpenSearch(
        hosts=[{"host": host, "port": 443}],
        http_auth=auth,
        use_ssl=True,
        verify_certs=True,
        connection_class=RequestsHttpConnection,
        timeout=30,
    )

def ensure_index(client: OpenSearch, name: str, dim: int) -> None:
    if client.indices.exists(index=name):
        print(f"[ingest] index '{name}' already exists")
        return
    body = {
        "settings": {
            "index": {
                "knn": True
            }
        },
        "mappings": {
            "properties": {
                "text":   { "type": "text" },
                "vector": {
                    "type": "knn_vector",
                    "dimension": dim,
                    # Optional: pin the HNSW method (defaults are OK)
                    # "method": {
                    #   "name": "hnsw",
                    #   "engine": "lucene",
                    #   "space_type": "cosinesimil",
                    #   "parameters": { "m": 16, "ef_construction": 128 }
                    # }
                },
                "source": { "type": "keyword" },
                "page":   { "type": "integer" }
            }
        }
    }
    client.indices.create(index=name, body=body)
    print(f"[ingest] created index '{name}' (dimension={dim})")

# --- Cold start: get client and ensure index once ---
_os = os_client()
ensure_index(_os, INDEX_NAME, EMBED_DIM)

def handler(event, context):
    # For now just prove the S3→SQS→Lambda path and index creation.
    # Next step we’ll read the S3 object, chunk, embed, and index docs.
    print("[ingest] event:", json.dumps(event)[:1000])
    return {"ok": True}
