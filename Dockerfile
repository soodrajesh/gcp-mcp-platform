FROM python:3.13-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 PYTHONPATH=/srv
WORKDIR /srv
COPY app/requirements.txt .
RUN pip install -r requirements.txt
COPY app/mcpkit mcpkit
COPY app/servers servers
COPY app/main.py .
RUN useradd -r -u 10001 app
USER 10001
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "1", "--proxy-headers"]
