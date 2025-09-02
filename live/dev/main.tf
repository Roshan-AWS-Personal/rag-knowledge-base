resource "aws_s3_bucket" "rag-documents_bucket" {
  bucket = "ai-kb-${var.env}-docs"
  force_destroy = true
}

data "aws_iam_policy_document" "s3_to_sqs" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.ingest_queue.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.rag-documents_bucket.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "allow_s3" {
  queue_url = aws_sqs_queue.ingest_queue.id
  policy    = data.aws_iam_policy_document.s3_to_sqs.json
}

# main.tf
resource "aws_s3_bucket_notification" "docs_to_sqs" {
  bucket = aws_s3_bucket.rag-documents_bucket.id

  queue {
    queue_arn = aws_sqs_queue.ingest_queue.arn
    events    = ["s3:ObjectCreated:*"]

    # Omit when empty (null means "don’t send the field")
    filter_prefix = var.s3_prefix != "" ? var.s3_prefix : null
    filter_suffix = var.s3_suffix != "" ? var.s3_suffix : null
  }

  # Ensure the queue policy exists before S3 registers the notification
  depends_on = [aws_sqs_queue_policy.allow_s3]
}

############################
# S3 static bucket (private; CF OAC only)
############################
resource "aws_s3_bucket" "site" {
  bucket = "${var.name}-site"
  tags = { Project = var.name }
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  restrict_public_buckets = true
  ignore_public_acls      = true
}

############################
# S3 bucket policy allowing CF OAC
############################
resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid: "AllowCloudFrontServicePrincipalReadOnly",
      Effect: "Allow",
      Principal: { Service: "cloudfront.amazonaws.com" },
      Action: ["s3:GetObject"],
      Resource: ["${aws_s3_bucket.site.arn}/*"],
      Condition: {
        StringEquals: {
          "AWS:SourceArn": aws_cloudfront_distribution.this.arn
        }
      }
    }]
  })
}

resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.site.id
  key          = "index.html"
  content_type = "text/html"
  content      = <<HTML
<!doctype html><meta charset="utf-8"><title>KB Chat</title>
<style>body{font-family:system-ui,Inter,sans-serif;max-width:760px;margin:40px auto;padding:0 16px}.msg{padding:12px 14px;border-radius:14px;margin:10px 0;white-space:pre-wrap}.user{background:#eef}.bot{background:#f6f6f6}.row{display:flex;gap:8px;position:sticky;bottom:0;background:#fff;padding:12px 0}input,button{font-size:16px}input{flex:1;padding:10px 12px;border:1px solid #ddd;border-radius:10px}button{padding:10px 14px;border:1px solid #ddd;border-radius:10px}</style>
<h2>Knowledge-base chat (dev)</h2>
<div id="chat"></div>
<div class="row"><input id="q" placeholder="Ask..." autofocus><button id="ask">Ask</button></div>
<script>
const chat=document.getElementById('chat'),q=document.getElementById('q'),btn=document.getElementById('ask');
function bubble(t,c){const d=document.createElement('div');d.className='msg '+c;d.textContent=t;chat.appendChild(d);window.scrollTo(0,document.body.scrollHeight)}
async function ask(){const text=q.value.trim();if(!text)return;bubble(text,'user');q.value='';btn.disabled=true;
try{const r=await fetch('/query',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({q:text})});
    const j=await r.json();bubble(j.answer||JSON.stringify(j),'bot');
    if(j.citations?.length){bubble("Sources:\\n- "+j.citations.map(x=>x.source+" (p."+x.page+")").join("\\n- "),'bot')}
}catch(e){bubble("Error: "+e,'bot')}finally{btn.disabled=false}}
btn.onclick=ask;q.onkeydown=e=>{if(e.key==='Enter'&&!e.shiftKey)ask()};
</script>
HTML
}

resource "aws_s3_bucket_cors_configuration" "website_cors" {
  bucket = aws_s3_bucket.site.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["PUT", "GET"]
    allowed_origins = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

output "cloudfront_url" { value = "https://${aws_cloudfront_distribution.this.domain_name}" }
output "site_bucket"    { value = aws_s3_bucket.site.bucket }