FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y gcc libpq-dev netcat-openbsd && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir django daphne channels channels-redis psycopg2-binary uvicorn whitenoise redis
COPY . .
RUN mkdir -p staticfiles
RUN python manage.py collectstatic --noinput
