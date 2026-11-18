# Multi-stage image so training, tests and serving all use identical library versions.
# Stage "base": runtime dependencies only (cached between builds).
FROM python:3.12-slim AS base
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt

# Stage "trainer": base + test tooling. Jenkins runs train.py and pytest in this image.
FROM base AS trainer
RUN pip install "pytest>=8,<10" "httpx>=0.27,<1"

# Stage "runtime": the FastAPI service with the freshly trained model baked in.
FROM base AS runtime
COPY app.py .
COPY artifacts/ artifacts/
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
