FROM public.ecr.aws/lambda/python:3.11

# needed by faiss wheel on Amazon Linux
RUN (dnf -y install libgomp || yum -y install libgomp || true) && (dnf clean all || yum clean all || true)

COPY requirements.txt .
RUN echo "--- requirements.txt ---" && cat requirements.txt && echo "-----------------------"
RUN python -m pip install --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt && \
    python - <<'PY'
import pkgutil
assert pkgutil.find_loader("faiss"), "faiss missing"
assert pkgutil.find_loader("numpy"), "numpy missing"
print("✅ deps OK")
PY

COPY app.py ${LAMBDA_TASK_ROOT}/app.py
CMD ["app.handler"]
