FROM python:3.13-slim

WORKDIR /app

RUN pip install --no-cache-dir asyncpg==0.30.0 aiokafka==0.12.0

COPY outbox-publisher.py .

CMD ["python", "outbox-publisher.py"]
