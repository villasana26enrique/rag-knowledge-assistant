FROM python:3.12-alpine AS base
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY *.py ./

# Tests: docker build --target test document-processor (the build fails if a test fails)
FROM base AS test
COPY requirements-dev.txt .
RUN pip install --no-cache-dir -r requirements-dev.txt
COPY tests ./tests
RUN python -m pytest -q tests

FROM base
USER nobody
EXPOSE 8080
CMD ["python", "-u", "server.py"]
