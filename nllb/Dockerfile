FROM nvidia/cuda:12.4.0-runtime-ubuntu22.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-pip && \
    rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir \
    "transformers>=4.45" torch sentencepiece fastapi uvicorn accelerate

COPY server.py /app/server.py

EXPOSE 5001

CMD ["python3", "/app/server.py"]
