FROM public.ecr.aws/lambda/python:3.11

# needed by faiss wheel on Amazon Linux
RUN (dnf -y install libgomp || yum -y install libgomp || true) && (dnf clean all || yum clean all || true)

COPY requirements.txt .

# Show exactly what the image sees
RUN echo "--- requirements.txt ---" && cat requirements.txt && echo "-----------------------"

# Force prebuilt FAISS wheel; fallback to 1.7.4 if 1.8.0 wheel unavailable
RUN python -m pip install --upgrade pip && \
    (pip install --no-cache-dir --only-binary=:all: faiss-cpu==1.8.0 || \
     pip install --no-cache-dir --only-binary=:all: faiss-cpu==1.7.4) && \
    pip install --no-cache-dir -r requirements.txt && \
    python - <<'PY'
import pkgutil
for mod in ["faiss","numpy","boto3","packaging"]:
    assert pkgutil.find_loader(mod), f"{mod} missing"
print("✅ deps OK")
PY

COPY app.py ${LAMBDA_TASK_ROOT}/app.py
CMD ["app.handler"]
