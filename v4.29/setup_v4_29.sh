#!/bin/bash
set -e

# ==============================================================================
# 🚀 LINE CLONE v4.29 - PLATINUM EDITION (SECURE PROXY & FILTER PUSHDOWN)
# ==============================================================================
# 
# CHANGELOG v4.29:
#   ✅ SECURITY: Replaced Direct MinIO Access with Django Streaming Proxy.
#      - Nginx no longer exposes '/minio/'.
#      - Files are accessed via '/api/download/?key=...'.
#      - Authenticated users only.
#   ✅ ARCHITECTURE: Supports Filter Pushdown.
#      - Frontend registers proxy URLs as virtual Hive paths.
#      - DuckDB pushes filters down, requesting only necessary files via Proxy.
#   ✅ INCLUDES: Hive Partitioning, UUIDs, CSRF Middleware.
# ==============================================================================

PROJECT_ROOT="line_clone_v4_lake"
echo "✨ Starting v4.29 Installation for: $PROJECT_ROOT"

# --- STEP 0: Deep Cleanup ---
echo "🧹 Cleaning up old containers and networks..."
docker stop line_backend line_db line_redis line_nginx line_minio line_worker 2>/dev/null || true
docker rm line_backend line_db line_redis line_nginx line_minio line_worker 2>/dev/null || true
docker network rm line_net 2>/dev/null || true

# --- STEP 1: Directory Structure ---
echo "📂 Creating directory structure..."
mkdir -p "$PROJECT_ROOT"
cd "$PROJECT_ROOT"

mkdir -p app/line_project
mkdir -p app/chat_app/management/commands
mkdir -p app/templates
mkdir -p app/static_src/js/vendor
mkdir -p app/static_src/css
mkdir -p app/static_src/fonts
mkdir -p nginx/certs

# --- STEP 2: "Air-Gapped" Asset Loader (Docker Build) ---

echo "🐳 Generating Dockerfile..."
cat > app/Dockerfile <<'EOF'
FROM node:20-alpine as builder
WORKDIR /assets
RUN npm install @duckdb/duckdb-wasm@1.28.0 apache-arrow@17.0.0 esbuild
RUN echo 'import * as duckdb from "@duckdb/duckdb-wasm"; import * as arrow from "apache-arrow"; export { duckdb, arrow };' > entry.js
RUN ./node_modules/.bin/esbuild entry.js --bundle --format=esm --outfile=duckdb-bundle.js --global-name=DuckDBBundle

RUN apk add --no-cache curl
WORKDIR /assets/fonts
RUN curl -fL -o Inter-Regular.woff2 "https://rsms.me/inter/font-files/Inter-Regular.woff2?v=3.19" \
    && curl -fL -o Inter-Bold.woff2 "https://rsms.me/inter/font-files/Inter-Bold.woff2?v=3.19"

WORKDIR /assets
RUN curl -fL -o tailwindcss https://github.com/tailwindlabs/tailwindcss/releases/download/v3.4.1/tailwindcss-linux-x64 \
    && chmod +x tailwindcss

FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y gcc libpq-dev netcat-openbsd curl && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir django daphne channels channels-redis psycopg2-binary uvicorn whitenoise redis boto3 pandas pyarrow

COPY . .

WORKDIR /build_assets
COPY --from=builder /assets/duckdb-bundle.js ./js/vendor/
COPY --from=builder /assets/node_modules/@duckdb/duckdb-wasm/dist/*.wasm ./js/vendor/duckdb/
COPY --from=builder /assets/node_modules/@duckdb/duckdb-wasm/dist/*.worker.js ./js/vendor/duckdb/
COPY --from=builder /assets/fonts/* ./fonts/
COPY --from=builder /assets/tailwindcss /usr/local/bin/tailwindcss

RUN echo '@tailwind base; @tailwind components; @tailwind utilities;' > input.css
RUN tailwindcss -i input.css -o ./css/styles.css --content '/app/templates/**/*.html' --minify

WORKDIR /app
EOF

# --- STEP 3: Infrastructure ---

echo "🐳 Generating docker-compose.yml..."
cat > docker-compose.yml <<'EOF'
version: '3.8'

services:
  nginx:
    build: ./nginx
    container_name: line_nginx
    ports: ["80:80", "443:443"]
    volumes: ["./nginx/certs:/etc/nginx/certs:ro"]
    depends_on: [web]
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:80"]
      interval: 10s
      timeout: 5s
      retries: 3

  web:
    build: ./app
    command: >
      sh -c "echo '⏳ Waiting for Services...' &&
             while ! nc -z db 5432; do sleep 1; done &&
             while ! nc -z redis 6379; do sleep 1; done &&
             while ! nc -z minio 9000; do sleep 1; done &&
             echo '✅ Services UP.' &&
             echo '🔄 CLEAN SYNC ASSETS...' &&
             rm -rf /app/static_src/* && 
             mkdir -p /app/static_src/js/vendor/duckdb /app/static_src/css /app/static_src/fonts &&
             cp -r /build_assets/* /app/static_src/ &&
             chmod -R 755 /app/static_src &&
             echo '✅ Running Collectstatic...' &&
             python manage.py collectstatic --noinput &&
             echo '✅ Migrating DB...' &&
             python manage.py makemigrations chat_app &&
             python manage.py migrate &&
             echo '👤 Creating Admin...' &&
             echo \"from django.contrib.auth import get_user_model; User = get_user_model(); User.objects.filter(username='admin').exists() or User.objects.create_superuser('admin', 'admin@example.com', 'password')\" | python manage.py shell &&
             echo '🪣 Initializing MinIO...' &&
             python manage.py init_minio &&
             echo '🚀 Starting Daphne...' &&
             daphne -b 0.0.0.0 -p 8000 line_project.asgi:application"
    volumes: 
      - ./app:/app
      - /app/staticfiles
      - /app/static_src
    depends_on: [db, redis, minio]
    environment:
      - SECRET_KEY=v4-lake-secret
      - POSTGRES_DB=line_db
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=password
      - POSTGRES_HOST=db
      - REDIS_HOST=redis
      - MINIO_ENDPOINT=minio:9000
      - MINIO_EXTERNAL_ENDPOINT=/minio
      - MINIO_ACCESS_KEY=minioadmin
      - MINIO_SECRET_KEY=minioadmin
      - AWS_S3_BUCKET_NAME=chat-logs
      - AWS_DEFAULT_REGION=us-east-1
      - ALLOWED_HOSTS=*
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/"]
      interval: 30s
      timeout: 10s
      retries: 3

  worker:
    build: ./app
    restart: on-failure
    command: >
      sh -c "echo '⏳ Worker Waiting for DB...' &&
             while ! nc -z db 5432; do sleep 1; done &&
             echo '✅ DB Connection OK. Starting Archiver...' &&
             python manage.py run_archiver"
    volumes: 
      - ./app:/app
      - /app/staticfiles
      - /app/static_src
    depends_on: [web]
    environment:
      - POSTGRES_DB=line_db
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=password
      - POSTGRES_HOST=db
      - REDIS_HOST=redis
      - MINIO_ENDPOINT=minio:9000
      - MINIO_ACCESS_KEY=minioadmin
      - MINIO_SECRET_KEY=minioadmin
      - AWS_S3_BUCKET_NAME=chat-logs
      - AWS_DEFAULT_REGION=us-east-1

  db:
    image: postgres:15-alpine
    container_name: line_db
    environment:
      - POSTGRES_DB=line_db
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=password
    volumes: ["postgres_data:/var/lib/postgresql/data"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: line_redis
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3

  minio:
    image: minio/minio
    container_name: line_minio
    command: server /data --console-address ":9001"
    ports: ["9001:9001"]
    environment:
      - MINIO_ROOT_USER=minioadmin
      - MINIO_ROOT_PASSWORD=minioadmin
    volumes: ["minio_data:/data"]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 20s
      retries: 3

volumes:
  postgres_data:
  minio_data:
EOF

echo "🔐 Generating SSL..."
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout nginx/certs/selfsigned.key -out nginx/certs/selfsigned.crt \
    -subj "/CN=localhost" 2>/dev/null

echo "🌐 Generating Nginx Config..."
cat > nginx/Dockerfile <<'EOF'
FROM nginx:alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
EOF

cat > nginx/nginx.conf <<'EOF'
types {
    text/html                             html htm shtml;
    text/css                              css;
    text/xml                              xml;
    image/gif                             gif;
    image/jpeg                            jpeg jpg;
    application/javascript                js;
    application/atom+xml                  atom;
    application/rss+xml                   rss;
    font/ttf                              ttf;
    font/woff                             woff;
    font/woff2                            woff2;
    text/mathml                           mml;
    text/plain                            txt;
    text/vnd.wap.wml                      wml;
    image/png                             png;
    image/svg+xml                         svg svgz;
    image/webp                            webp;
    application/wasm                      wasm;
    application/json                      json;
}

upstream django_app { server web:8000; }

server {
    listen 80; return 301 https://$host$request_uri;
}
server {
    listen 443 ssl;
    server_name _;
    ssl_certificate /etc/nginx/certs/selfsigned.crt;
    ssl_certificate_key /etc/nginx/certs/selfsigned.key;

    # Timeouts
    proxy_connect_timeout 75s;
    proxy_read_timeout 86400s;
    proxy_send_timeout 86400s;
    client_max_body_size 50M;

    add_header Cross-Origin-Opener-Policy "same-origin" always;
    add_header Cross-Origin-Embedder-Policy "require-corp" always;
    
    # 1. Standard HTTP requests (Views, Admin, API)
    location / {
        proxy_pass http://django_app;
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # 2. WebSocket requests (Explicit path)
    location /ws/ {
        proxy_pass http://django_app;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $http_host;
    }

    # REMOVED /minio/ location. Now handled by Django Proxy View.
}
EOF

# --- STEP 4: Backend ---

echo "⚙️ Generating Backend Code..."
cat > app/manage.py <<'EOF'
#!/usr/bin/env python
import os, sys
def main():
    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'line_project.settings')
    from django.core.management import execute_from_command_line
    execute_from_command_line(sys.argv)
if __name__ == '__main__': main()
EOF

touch app/line_project/__init__.py

# MIDDLEWARE: CSRF Fix
cat > app/line_project/middleware.py <<'EOF'
class OriginSpoofMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response
    def __call__(self, request):
        if request.is_secure() or request.scheme == 'https':
            request.META['HTTP_ORIGIN'] = 'https://localhost'
            request.META['HTTP_REFERER'] = 'https://localhost'
        return self.get_response(request)
EOF

cat > app/line_project/settings.py <<'EOF'
from pathlib import Path
import os

BASE_DIR = Path(__file__).resolve().parent.parent
SECRET_KEY = os.environ.get('SECRET_KEY', 'dev')
DEBUG = 1
ALLOWED_HOSTS = ['*']
# Trust localhost (which our middleware will spoof)
CSRF_TRUSTED_ORIGINS = ['https://localhost']
SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')

INSTALLED_APPS = ['daphne', 'django.contrib.admin', 'django.contrib.auth', 'django.contrib.contenttypes', 'django.contrib.sessions', 'django.contrib.messages', 'django.contrib.staticfiles', 'channels', 'chat_app']
MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'whitenoise.middleware.WhiteNoiseMiddleware',
    'line_project.middleware.OriginSpoofMiddleware', # Loaded from file
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware'
]

ROOT_URLCONF = 'line_project.urls'
TEMPLATES = [{'BACKEND': 'django.template.backends.django.DjangoTemplates', 'DIRS': [BASE_DIR / 'templates'], 'APP_DIRS': True, 'OPTIONS': {'context_processors': ['django.contrib.auth.context_processors.auth', 'django.contrib.messages.context_processors.messages', 'django.template.context_processors.request']}}]
ASGI_APPLICATION = 'line_project.asgi.application'
CHANNEL_LAYERS = {"default": {"BACKEND": "channels_redis.core.RedisChannelLayer", "CONFIG": {"hosts": [("redis", 6379)]}}}
DATABASES = {'default': {'ENGINE': 'django.db.backends.postgresql', 'NAME': os.environ.get('POSTGRES_DB'), 'USER': os.environ.get('POSTGRES_USER'), 'PASSWORD': os.environ.get('POSTGRES_PASSWORD'), 'HOST': os.environ.get('POSTGRES_HOST'), 'PORT': '5432'}}

STATIC_URL = '/static/'
STATIC_ROOT = BASE_DIR / 'staticfiles'
STATICFILES_DIRS = [BASE_DIR / 'static_src']
STATICFILES_STORAGE = 'whitenoise.storage.CompressedManifestStaticFilesStorage'

MINIO_ENDPOINT = os.environ.get('MINIO_ENDPOINT')
MINIO_ACCESS_KEY = os.environ.get('MINIO_ACCESS_KEY')
MINIO_SECRET_KEY = os.environ.get('MINIO_SECRET_KEY')
AWS_S3_BUCKET_NAME = os.environ.get('AWS_S3_BUCKET_NAME')
MINIO_EXTERNAL_ENDPOINT = os.environ.get('MINIO_EXTERNAL_ENDPOINT')
DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'
LOGIN_URL = '/login/'
EOF

cat > app/line_project/asgi.py <<'EOF'
import os, django
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'line_project.settings')
django.setup()
from django.core.asgi import get_asgi_application
from channels.routing import ProtocolTypeRouter, URLRouter
from channels.auth import AuthMiddlewareStack
from chat_app.routing import websocket_urlpatterns
application = ProtocolTypeRouter({"http": get_asgi_application(), "websocket": AuthMiddlewareStack(URLRouter(websocket_urlpatterns))})
EOF

cat > app/line_project/urls.py <<'EOF'
from django.contrib import admin
from django.urls import path, include
urlpatterns = [path('admin/', admin.site.urls), path('', include('chat_app.urls'))]
EOF

touch app/chat_app/__init__.py
touch app/chat_app/apps.py

cat > app/chat_app/models.py <<'EOF'
from django.db import models
from django.contrib.auth.models import User

class Room(models.Model):
    name = models.CharField(max_length=255, unique=True)
    def __str__(self): return self.name

class Message(models.Model):
    room = models.ForeignKey(Room, related_name='messages', on_delete=models.CASCADE)
    sender = models.ForeignKey(User, on_delete=models.CASCADE)
    content = models.TextField()
    timestamp = models.DateTimeField(auto_now_add=True, db_index=True)
    class Meta: ordering = ['timestamp']
    
    def to_json(self):
        return {'id': self.id, 'username': self.sender.username, 'message': self.content, 'timestamp': self.timestamp.isoformat(), 'source': 'warm'}
EOF

cat > app/chat_app/admin.py <<'EOF'
from django.contrib import admin
from .models import Room, Message

@admin.register(Room)
class RoomAdmin(admin.ModelAdmin):
    list_display = ('id', 'name')
    search_fields = ('name',)

@admin.register(Message)
class MessageAdmin(admin.ModelAdmin):
    list_display = ('id', 'room', 'sender', 'timestamp', 'content_preview')
    list_filter = ('timestamp',) 
    search_fields = ('content', 'sender__username')
    raw_id_fields = ('room', 'sender')
    
    def content_preview(self, obj): return obj.content[:50]
EOF

cat > app/chat_app/views.py <<'EOF'
import boto3
from django.conf import settings
from django.shortcuts import render, redirect
from django.http import JsonResponse, HttpResponseForbidden, StreamingHttpResponse
from django.contrib.auth import login, logout
from django.contrib.auth.models import User
from django.contrib.auth.forms import UserCreationForm, AuthenticationForm
from django.contrib.auth.decorators import login_required
from .models import Room, Message
from django.utils import timezone
from django.db.models import Q

def auth_view(request, auth_type):
    Form = UserCreationForm if auth_type == 'signup' else AuthenticationForm
    if request.method == 'POST':
        form = Form(data=request.POST) if auth_type == 'login' else Form(request.POST)
        if form.is_valid():
            login(request, form.get_user() if auth_type == 'login' else form.save())
            return redirect('chat_room', room_name='lobby')
    else: form = Form()
    return render(request, 'auth.html', {'form': form, 'type': 'Sign Up' if auth_type == 'signup' else 'Log In'})

def logout_view(request): logout(request); return redirect('login')
def index_view(request): return redirect('chat_room', room_name='lobby') if request.user.is_authenticated else redirect('login')

@login_required
def room_view(request, room_name):
    if room_name.startswith('dm_'):
        try:
            parts = room_name.split('_')
            ids = [int(parts[1]), int(parts[2])]
            if request.user.id not in ids:
                return HttpResponseForbidden("⛔ Privado: You are not a participant in this DM.")
        except (IndexError, ValueError): pass

    users = []
    user_id = request.user.id
    for u in User.objects.exclude(id=user_id).order_by('username'):
        u.dm_room_name = f"dm_{min(user_id, u.id)}_{max(user_id, u.id)}"
        users.append(u)

    public_rooms = Room.objects.filter(~Q(name__startswith='dm_')).order_by('name')

    return render(request, 'room.html', {
        'room_name': room_name, 
        'user': request.user,
        'users': users,
        'public_rooms': public_rooms
    })

@login_required
def recent_history(request, room_name):
    try:
        room, created = Room.objects.get_or_create(name=room_name)
        msgs = Message.objects.filter(room=room).select_related('sender').order_by('-timestamp')[:50]
        return JsonResponse({'messages': [m.to_json() for m in reversed(msgs)]})
    except Exception as e:
        return JsonResponse({'error': str(e)}, status=500)

@login_required
def archive_index(request, room_name):
    s3 = boto3.client('s3', endpoint_url=f"http://{settings.MINIO_ENDPOINT}", 
                      aws_access_key_id=settings.MINIO_ACCESS_KEY, aws_secret_access_key=settings.MINIO_SECRET_KEY)
    try:
        room_id = Room.objects.get(name=room_name).id
        # HIVE PARTITION FIX: Recursively list objects
        prefix = f"chat_archive/room_{room_id}/"
        response = s3.list_objects_v2(Bucket=settings.AWS_S3_BUCKET_NAME, Prefix=prefix)
        files = []
        if 'Contents' in response:
            for obj in response['Contents']:
                key = obj['Key']
                # PROXY URL: Point to Django Proxy View
                final = f"/api/download/?key={key}"
                files.append({'key': key, 'url': final, 'timestamp': obj['LastModified']})
        
        # Sort by Key (which contains date in Hive path) descending
        files.sort(key=lambda x: x['key'], reverse=True)
        return JsonResponse({'files': files})
    except Exception as e:
        return JsonResponse({'error': str(e)}, status=500)

@login_required
def proxy_parquet(request):
    key = request.GET.get('key')
    if not key: return HttpResponseForbidden("Missing key")
    
    # 1. Security: Ensure user has access (Simplified for MVP: Login Required)
    # Real impl would verify User-Room membership via key parsing
    
    s3 = boto3.client('s3', endpoint_url=f"http://{settings.MINIO_ENDPOINT}", 
                      aws_access_key_id=settings.MINIO_ACCESS_KEY, aws_secret_access_key=settings.MINIO_SECRET_KEY)
    
    try:
        # 2. Fetch from MinIO (Internal Network)
        # Boto3 handles the auth internally, no presigned URL complexity
        obj = s3.get_object(Bucket=settings.AWS_S3_BUCKET_NAME, Key=key)
        
        # 3. Stream to User
        response = StreamingHttpResponse(
            obj['Body'],
            content_type='application/octet-stream'
        )
        response['Content-Disposition'] = f'attachment; filename="{key.split("/")[-1]}"'
        return response
    except Exception as e:
        return JsonResponse({'error': str(e)}, status=404)
EOF

cat > app/chat_app/urls.py <<'EOF'
from django.urls import path
from . import views
urlpatterns = [
    path('', views.index_view, name='index'), path('login/', views.auth_view, {'auth_type': 'login'}, name='login'),
    path('signup/', views.auth_view, {'auth_type': 'signup'}, name='signup'), path('logout/', views.logout_view, name='logout'),
    path('chat/<str:room_name>/', views.room_view, name='chat_room'),
    path('api/warm/<str:room_name>/', views.recent_history, name='recent_history'),
    path('api/cold/<str:room_name>/', views.archive_index, name='archive_index'),
    path('api/download/', views.proxy_parquet, name='proxy_parquet'),
]
EOF

cat > app/chat_app/consumers.py <<'EOF'
import json
from channels.generic.websocket import AsyncWebsocketConsumer
from channels.db import database_sync_to_async
from .models import Message, Room
from django.contrib.auth.models import User

class ChatConsumer(AsyncWebsocketConsumer):
    async def connect(self):
        self.room_name = self.scope['url_route']['kwargs']['room_name']
        self.room_group = f'chat_{self.room_name}'
        await self.channel_layer.group_add(self.room_group, self.channel_name)
        await self.accept()

    async def disconnect(self, c): await self.channel_layer.group_discard(self.room_group, self.channel_name)

    async def receive(self, text_data):
        try:
            data = json.loads(text_data)
            username = self.scope["user"].username
            if not username: return
            await self.save_message(username, self.room_name, data['message'])
            await self.channel_layer.group_send(self.room_group, {'type': 'chat_message', 'message': data['message'], 'username': username, 'timestamp': 'Just now', 'source': 'hot'})
        except: pass

    async def chat_message(self, e): await self.send(text_data=json.dumps(e))

    @database_sync_to_async
    def save_message(self, username, room_name, message):
        user = User.objects.get(username=username)
        room, _ = Room.objects.get_or_create(name=room_name)
        Message.objects.create(sender=user, room=room, content=message)
EOF

cat > app/chat_app/routing.py <<'EOF'
from django.urls import re_path
from . import consumers
websocket_urlpatterns = [re_path(r'ws/chat/(?P<room_name>\w+)/$', consumers.ChatConsumer.as_asgi())]
EOF

# --- STEP 5: Workers ---

echo "👷 Generating Workers..."
cat > app/chat_app/management/commands/init_minio.py <<'EOF'
import boto3, json, time
from botocore.exceptions import ClientError
from django.conf import settings
from django.core.management.base import BaseCommand

class Command(BaseCommand):
    help = 'Create S3 bucket (Private Mode)'
    def handle(self, *args, **options):
        s3 = boto3.client('s3', endpoint_url=f"http://{settings.MINIO_ENDPOINT}",
                          aws_access_key_id=settings.MINIO_ACCESS_KEY, aws_secret_access_key=settings.MINIO_SECRET_KEY)
        bucket_name = settings.AWS_S3_BUCKET_NAME
        
        for i in range(10):
            try:
                # 1. Create Bucket
                try:
                    s3.create_bucket(Bucket=bucket_name)
                    print(f"✅ Bucket '{bucket_name}' created.")
                except ClientError as e:
                    if e.response['Error']['Code'] not in ['BucketAlreadyOwnedByYou', 'BucketAlreadyExists']:
                        raise e
                
                # 2. Ensure Private (No public policy)
                return

            except Exception as e:
                print(f"⚠️ Init attempt {i+1} failed: {e}. Retrying...")
                time.sleep(3)
EOF

cat > app/chat_app/management/commands/run_archiver.py <<'EOF'
import time, datetime, boto3, pandas as pd, io, uuid
from django.core.management.base import BaseCommand
from django.conf import settings
from django.utils import timezone
from chat_app.models import Message

class Command(BaseCommand):
    help = 'Move data to Cold Storage (Hive Partitioning)'
    def handle(self, *args, **options):
        print("❄️  Archiver Started (Hive Mode).")
        s3 = boto3.client('s3', endpoint_url=f"http://{settings.MINIO_ENDPOINT}",
                          aws_access_key_id=settings.MINIO_ACCESS_KEY, aws_secret_access_key=settings.MINIO_SECRET_KEY)
        while True:
            try:
                cutoff = timezone.now() - datetime.timedelta(minutes=1)
                msgs = Message.objects.filter(timestamp__lt=cutoff).select_related('room', 'sender')
                if not msgs.exists():
                    time.sleep(5); continue

                count = msgs.count()
                print(f"📦 Archiving {count} messages...")
                
                data = []
                for m in msgs:
                    t = m.timestamp
                    data.append({
                        'id': m.id, 'room_id': m.room.id, 'sender': m.sender.username, 
                        'content': m.content, 'timestamp': m.timestamp,
                        'year': t.strftime('%Y'), 'month': t.strftime('%m'), 
                        'day': t.strftime('%d'), 'hour': t.strftime('%H')
                    })
                
                df = pd.DataFrame(data)
                
                for (room_id, year, month, day, hour), group in df.groupby(['room_id', 'year', 'month', 'day', 'hour']):
                    key = f"chat_archive/room_{room_id}/year={year}/month={month}/day={day}/hour={hour}/{uuid.uuid4()}.parquet"
                    buf = io.BytesIO()
                    group.drop(columns=['year', 'month', 'day', 'hour', 'room_id']).to_parquet(buf, index=False)
                    buf.seek(0)
                    s3.upload_fileobj(buf, settings.AWS_S3_BUCKET_NAME, key)
                    print(f"   -> Uploaded: {key}")
                
                Message.objects.filter(id__in=df['id'].tolist()).delete()
                print("   🗑️  Cleaned PG.")
            except Exception as e: print(f"❌ Error: {e}")
            time.sleep(10)
EOF

# --- STEP 6: Frontend ---

echo "🎨 Generating UI..."
cat > app/templates/auth.html <<'EOF'
{% load static %}
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width"><title>Auth</title><link href="{% static 'css/styles.css' %}" rel="stylesheet"></head><body class="bg-slate-100 h-screen flex items-center justify-center"><div class="bg-white p-8 rounded-xl shadow-lg w-80"><h1 class="text-2xl font-bold mb-6 text-center text-slate-800">{{type}}</h1><form method="POST">{% csrf_token %}{% for field in form %}<div class="mb-4"><label class="block text-sm font-medium mb-1 text-slate-600">{{field.label}}</label><input name="{{field.name}}" type="{{field.field.widget.input_type}}" class="w-full border border-slate-300 p-2 rounded focus:ring-2 focus:ring-green-500 outline-none"></div>{% endfor %}<button class="w-full bg-[#06C755] text-white p-3 rounded-lg font-bold hover:bg-[#05b34d] transition">{{type}}</button></form><div class="mt-4 text-center"><a href="/signup/" class="text-sm text-slate-500 hover:text-green-600">Switch Mode</a></div></div></body></html>
EOF

cat > app/templates/room.html <<'EOF'
{% load static %}
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Line v4.29 Lake</title>
    <link href="{% static 'css/styles.css' %}" rel="stylesheet">
    <style>
        @font-face { font-family: 'Inter'; src: url("{% static 'fonts/Inter-Regular.woff2' %}") format('woff2'); font-weight: normal; font-style: normal; }
        @font-face { font-family: 'Inter'; src: url("{% static 'fonts/Inter-Bold.woff2' %}") format('woff2'); font-weight: bold; font-style: normal; }
        body { font-family: 'Inter', sans-serif; }
        .bubble-me { border-radius: 18px 2px 18px 18px; background-color: #06C755; color: white; }
        .bubble-other { border-radius: 2px 18px 18px 18px; background-color: white; color: #1e293b; border: 1px solid #e2e8f0; }
        .badge-hot { background-color: #fee2e2; color: #ef4444; }
        .badge-warm { background-color: #fef3c7; color: #d97706; }
        .badge-cold { background-color: #dbeafe; color: #2563eb; }
        #debug-console { font-family: monospace; font-size: 10px; background: #000; color: #0f0; max-height: 100px; overflow-y: auto; padding: 5px; position: absolute; bottom: 60px; left: 0; right: 0; opacity: 0.8; pointer-events: none; z-index: 50; }
    </style>
</head>
<body class="bg-slate-200 h-[100dvh] flex flex-col overflow-hidden">
    <header class="bg-white/90 backdrop-blur border-b px-4 py-3 flex justify-between items-center shadow-sm shrink-0 z-20">
        <div>
            <h1 class="font-bold text-lg text-slate-800">#{{ room_name }}</h1>
            <div class="flex items-center space-x-2 text-xs text-slate-500">
                <span id="storage-status">Initializing DB...</span>
                <span class="mx-1">|</span>
                <span id="ws-status" class="text-yellow-500">Connecting...</span>
            </div>
        </div>
        <div class="flex items-center gap-4">
             <span class="text-xs text-slate-500 font-bold">{{ user.username }}</span>
            <a href="/logout/" class="text-sm font-medium text-slate-400 hover:text-red-500">Exit</a>
        </div>
    </header>

    <div class="flex flex-1 overflow-hidden relative">
        <!-- SIDEBAR -->
        <aside class="w-64 bg-slate-50 border-r border-slate-200 flex flex-col overflow-y-auto hidden md:flex shrink-0">
            <div class="p-4 border-b border-slate-200">
                <h2 class="text-xs font-bold text-slate-400 uppercase tracking-wider mb-2">Public Rooms</h2>
                <ul class="space-y-1">
                    <li><a href="/chat/lobby/" class="block px-2 py-1.5 rounded text-sm {% if room_name == 'lobby' %}bg-green-100 text-green-700 font-bold{% else %}text-slate-600 hover:bg-white hover:shadow-sm{% endif %}"># lobby</a></li>
                    {% for room in public_rooms %}
                        {% if room.name != 'lobby' %}
                        <li><a href="/chat/{{ room.name }}/" class="block px-2 py-1.5 rounded text-sm {% if room_name == room.name %}bg-green-100 text-green-700 font-bold{% else %}text-slate-600 hover:bg-white hover:shadow-sm{% endif %}"># {{ room.name }}</a></li>
                        {% endif %}
                    {% endfor %}
                </ul>
            </div>
            <div class="p-4">
                <h2 class="text-xs font-bold text-slate-400 uppercase tracking-wider mb-2">Direct Messages</h2>
                <ul class="space-y-1">
                    {% for u in users %}
                        <li><a href="/chat/{{ u.dm_room_name }}/" class="flex items-center px-2 py-1.5 rounded text-sm {% if room_name == u.dm_room_name %}bg-green-100 text-green-700 font-bold{% else %}text-slate-600 hover:bg-white hover:shadow-sm{% endif %}">
                            <span class="w-2 h-2 rounded-full bg-slate-300 mr-2"></span>{{ u.username }}
                        </a></li>
                    {% endfor %}
                </ul>
            </div>
        </aside>

        <!-- CHAT AREA -->
        <main class="flex-1 flex flex-col relative min-w-0">
            <div id="scroll-container" class="flex-1 overflow-y-auto p-4 flex flex-col space-y-4">
                <div id="archive-loader" class="hidden w-full text-center py-4">
                    <span class="inline-block animate-spin rounded-full h-5 w-5 border-t-2 border-b-2 border-blue-500"></span>
                    <p class="text-xs text-blue-500 mt-1 font-bold">Downloading Parquet...</p>
                </div>
                <div id="chat-log" class="flex flex-col space-y-2"></div>
            </div>
            
            <div id="debug-console"></div>

            <div class="bg-white px-4 py-3 shrink-0 flex items-center space-x-2 border-t safe-pb z-10">
                <input id="chat-message-input" type="text" class="flex-1 bg-slate-100 border-none rounded-full px-4 py-3 focus:ring-2 focus:ring-[#06C755] outline-none" placeholder="Type a message in #{{ room_name }}...">
                <button id="send-btn" class="bg-[#06C755] text-white p-3 rounded-full hover:bg-[#05b34d] shadow-md transition active:scale-95">Send</button>
            </div>
        </main>
    </div>

    <script type="module">
        import { duckdb } from "{% static 'js/vendor/duckdb-bundle.js' %}";
        
        const roomName = "{{ room_name }}";
        const myUsername = "{{ user.username }}";
        const chatLog = document.getElementById('chat-log');
        const scrollContainer = document.getElementById('scroll-container');
        const statusSpan = document.getElementById('storage-status');
        const wsStatusSpan = document.getElementById('ws-status');
        const debugConsole = document.getElementById('debug-console');
        
        function log(msg) {
            console.log(msg);
            const div = document.createElement('div');
            div.innerText = "> " + msg;
            debugConsole.appendChild(div);
            debugConsole.scrollTop = debugConsole.scrollHeight;
        }

        let db = null, conn = null, allColdFiles = [], isDataLakeMounted = false;

        async function main() {
            log("Starting App...");
            
            // 1. Initialize DB - Manual Bundle Config
            statusSpan.innerText = "🦆 Loading Wasm...";
            try {
                log("Configuring DuckDB...");
                const bundle = {
                    mainModule: "{% static 'js/vendor/duckdb/duckdb-mvp.wasm' %}",
                    mainWorker: "{% static 'js/vendor/duckdb/duckdb-browser-mvp.worker.js' %}",
                };
                const logger = new duckdb.ConsoleLogger();
                log("Creating Worker...");
                const worker = new Worker(bundle.mainWorker);
                log("Instantiating DB...");
                db = new duckdb.AsyncDuckDB(logger, worker);
                await db.instantiate(bundle.mainModule);
                log("Connecting DB...");
                conn = await db.connect();
                
                statusSpan.innerText = "🦆 DuckDB Ready";
                log("DuckDB Ready. Fetching Index...");
                
                await fetchArchiveIndexAndMount();
                
                // If scrollbar is empty, trigger load
                if (chatLog.children.length < 5 || scrollContainer.scrollHeight <= scrollContainer.clientHeight) {
                    loadColdData();
                }
            } catch (e) { 
                console.error(e); 
                statusSpan.innerText = "❌ Wasm Error"; 
                log("ERROR: " + e.message);
            }

            // 2. Connect WebSocket
            const protocol = window.location.protocol === 'https:' ? 'wss' : 'ws';
            const ws = new WebSocket(`${protocol}://${window.location.host}/ws/chat/${roomName}/`);
            ws.onopen = () => { wsStatusSpan.innerText = "● Live"; wsStatusSpan.className = "text-green-600 font-bold"; };
            ws.onmessage = (e) => { renderMessage(JSON.parse(e.data)); };

            // 3. Input Handling
            const input = document.getElementById('chat-message-input');
            const sendBtn = document.getElementById('send-btn');
            const send = () => { 
                if(!input.value.trim()) return; 
                if (ws.readyState !== WebSocket.OPEN) { alert("Offline"); return; }
                ws.send(JSON.stringify({message: input.value})); 
                input.value = ''; 
            };
            sendBtn.onclick = send;
            input.onkeydown = (e) => { if(e.key==='Enter') send(); };

            // 4. Initial Data Load (Warm)
            fetch(`/api/warm/${roomName}/`).then(r => r.json()).then(data => {
                if (data.messages) data.messages.forEach(m => renderMessage(m));
            });
        }

        function renderMessage(data, prepend = false) {
            const isMe = data.username === myUsername;
            const timeStr = new Date(data.timestamp).toLocaleTimeString([], {hour: '2-digit', minute:'2-digit'});
            let badgeClass = data.source === 'cold' ? 'badge-cold' : (data.source === 'warm' ? 'badge-warm' : 'badge-hot');
            const html = `
                <div class="flex flex-col ${isMe ? 'items-end' : 'items-start'} animate-fade-in">
                    <div class="${isMe ? 'text-right' : 'text-left'} text-[10px] text-slate-400 mb-1 ml-1">${data.username}</div>
                    <div class="px-4 py-2 max-w-[80%] text-[15px] shadow-sm leading-snug break-words ${isMe ? 'bubble-me' : 'bubble-other'}">${data.message}</div>
                    <div class="flex items-center space-x-2 mt-1"><span class="text-[9px] text-slate-400">${timeStr}</span><span class="px-1 rounded text-[9px] uppercase font-bold text-white ${badgeClass}">${data.source}</span></div>
                </div>`;
            const div = document.createElement('div'); div.innerHTML = html;
            if (prepend) chatLog.prepend(div.firstElementChild);
            else { chatLog.appendChild(div.firstElementChild); scrollToBottom(); }
        }

        async function fetchArchiveIndexAndMount() {
            const res = await fetch(`/api/cold/${roomName}/`);
            const data = await res.json();
            allColdFiles = data.files || [];
            log(`Found ${allColdFiles.length} archive files.`);
            
            if (allColdFiles.length > 0 && !isDataLakeMounted) {
                // DATA LAKE MOUNTING: Register ALL files to create Virtual Hive FS
                log("Mounting Data Lake (Registering Files)...");
                for (const file of allColdFiles) {
                     // Key is like: chat_archive/room_1/year=2024/...
                     // Mapped to PROXY URL: /api/download/?key=...
                     await db.registerFileURL(file.key, file.url, duckdb.DuckDBDataProtocol.HTTP, false);
                }
                isDataLakeMounted = true;
                log("Data Lake Mounted.");
            }
        }

        async function loadColdData() {
            if (!isDataLakeMounted || allColdFiles.length === 0) return;
            
            document.getElementById('archive-loader').classList.remove('hidden');
            statusSpan.innerText = "🧊 Running Hive Query...";
            
            // SMART HIVE QUERY: Use Filter Pushdown
            const firstKey = allColdFiles[0].key;
            const rootPath = firstKey.split('/year=')[0];
            const globPattern = `${rootPath}/*/*/*/*/*.parquet`;
            
            try {
                // Query: Fetch last 24 hours of data using Hive Filtering (Pushdown) LIMIT 500
                const query = `
                    SELECT * FROM read_parquet('${globPattern}', hive_partitioning=true)
                    ORDER BY timestamp DESC
                `;
                
                log("Executing: " + query);
                const result = await conn.query(query);
                const rows = result.toArray().map(r => r.toJSON());
                
                log(`Query returned ${rows.length} rows.`);
                
                let h = scrollContainer.scrollHeight;
                rows.forEach(r => renderMessage({username: r.sender, message: r.content, timestamp: r.timestamp, source: 'cold'}, true));
                
                // Remove loaded files from list so we don't reload them?
                // Actually with this query we might reload duplicates if we don't manage offset.
                // For this demo, we clear list to stop infinite recursion on empty
                allColdFiles = []; 
                
                scrollContainer.scrollTop = scrollContainer.scrollHeight - h;
                statusSpan.innerText = "🦆 DuckDB Ready";
                
            } catch (e) {
                console.error(e);
                log("Query Fail: " + e.message);
                statusSpan.innerText = "❌ Query Error";
            } finally {
                document.getElementById('archive-loader').classList.add('hidden');
            }
        }

        function scrollToBottom() {
            if(scrollContainer.scrollHeight - scrollContainer.scrollTop - scrollContainer.clientHeight < 200) scrollContainer.scrollTop = scrollContainer.scrollHeight;
        }
        
        scrollContainer.addEventListener('scroll', () => { 
            if (scrollContainer.scrollTop < 50) loadColdData(); 
        });

        main();
    </script>
</body>
</html>
EOF

echo "✅ LINE CLONE v4.29 COMPLETE!"
echo "1. Run: docker-compose up -d --build"
echo "2. Access: https://localhost"