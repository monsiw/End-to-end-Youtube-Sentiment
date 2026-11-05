FROM python:3.11-slim-buster

WORKDIR /app

COPY . /app

RUN pip install -r requirements.txt

RUN apt-get update && \
    apt-get install -y --no-install-recommends libgomp1 && \
    rm -rf /var/lib/apt/lists/*
    
CMD ["python3", "app.py"]