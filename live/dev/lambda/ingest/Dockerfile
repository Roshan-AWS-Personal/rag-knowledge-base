FROM public.ecr.aws/lambda/python:3.11

# needed by faiss wheel on Amazon Linux
RUN (dnf -y install libgomp || yum -y install libgomp || true) && (dnf clean all || yum clean all || true)

COPY requirements.txt .

# Helpful: print the requirements the image actually sees
RUN echo "--- requirements.txt ---" && cat requirements.txt && echo "-----------------------"

# Keep pip recent and force wheels only for faiss
RUN python -m pip install --upgrade pip && \
    (pip install --no-cache-dir --only-binary=:all: faiss-cpu==1.8.0 || \
     pip install --no-cache-dir --only-binary=:all: faiss-cpu==1.7.4) && \
    pip install --no-cache-dir -r requirements.txt && \
    python - <<'PY'
import pkgutil
assert pkgutil.find_loader("faiss"), "faiss missing"
assert pkgutil.find_loader("numpy"), "numpy missing"
print("✅ deps OK")
PY

COPY app.py ${LAMBDA_TASK_ROOT}/app.py
CMD ["app.handler"]
