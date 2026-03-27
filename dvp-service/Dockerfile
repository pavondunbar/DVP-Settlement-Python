FROM python:3.13-slim

WORKDIR /app

RUN pip install --no-cache-dir asyncpg==0.30.0

COPY dvp-service.py .

CMD ["python", "dvp-service.py"]
