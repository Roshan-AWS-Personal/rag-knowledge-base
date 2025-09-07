FROM public.ecr.aws/lambda/python:3.11
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py ${LAMBDA_TASK_ROOT}/app.py
CMD ["app.handler"]
