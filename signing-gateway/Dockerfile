FROM python:3.13-slim

WORKDIR /app

RUN pip install --no-cache-dir aiohttp==3.11.11

COPY gateway.py .

CMD ["python", "gateway.py"]
