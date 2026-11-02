FROM python:3.12-slim

RUN pip install --no-cache-dir flask docker

WORKDIR /app
COPY app.py /app/app.py
COPY templates /app/templates

CMD ["python", "-u", "app.py"]
