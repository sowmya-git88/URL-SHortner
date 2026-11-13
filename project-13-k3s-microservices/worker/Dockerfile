# syntax=docker/dockerfile:1.7
FROM python:3.12-slim AS deps
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /venv
COPY requirements.txt .
RUN /venv/bin/pip install -r requirements.txt

FROM python:3.12-slim
ENV PATH=/venv/bin:$PATH PYTHONUNBUFFERED=1
RUN useradd --system --uid 10001 --no-create-home worker
COPY --from=deps /venv /venv
WORKDIR /app
COPY worker.py .
USER 10001
CMD ["python", "worker.py"]
