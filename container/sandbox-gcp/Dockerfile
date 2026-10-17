FROM python:3.13-slim
RUN pip install --no-cache-dir flask fastapi uvicorn requests google-cloud-firestore google-cloud-storage && useradd -m sbx
COPY entry.py /entry.py
USER sbx
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
CMD ["python", "/entry.py"]
