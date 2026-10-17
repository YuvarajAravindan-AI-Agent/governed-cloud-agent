FROM python:3.13-slim
RUN pip install --no-cache-dir boto3 && useradd -m app
COPY entrypoint.py /entrypoint.py
RUN mkdir /app && chown app /app
USER app
ENV PYTHONUNBUFFERED=1
CMD ["python", "/entrypoint.py"]
