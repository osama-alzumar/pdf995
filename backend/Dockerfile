# Waraqa processing server. Build: docker build -t waraqa-backend .
FROM python:3.12-slim-bookworm
ENV DEBIAN_FRONTEND=noninteractive PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      libreoffice-writer libreoffice-calc libreoffice-impress \
      tesseract-ocr tesseract-ocr-ara tesseract-ocr-eng qpdf ocrmypdf ghostscript poppler-utils \
      fonts-noto-core fonts-kacst fonts-hosny-amiri unpaper pngquant \
    && rm -rf /var/lib/apt/lists/*
RUN useradd --create-home --uid 10001 waraqa
WORKDIR /srv/waraqa
COPY requirements.lock .
RUN pip install --no-cache-dir -r requirements.lock
COPY app ./app
USER waraqa
ENV WARAQA_WORK_DIR=/tmp/waraqa-work
EXPOSE 8000
# One worker process: the job semaphore and rate limiter are in-process. Scale with more containers.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips", "*"]
