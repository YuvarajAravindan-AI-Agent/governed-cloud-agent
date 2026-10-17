FROM python:3.13-slim
RUN pip install --no-cache-dir google-cloud-storage && useradd -m app
COPY entrypoint.py /entrypoint.py
USER app
ENV PYTHONUNBUFFERED=1
CMD ["python", "/entrypoint.py"]
