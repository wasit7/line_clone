#!/bin/bash
set -e

# ==============================================================================
# 🚀 LINE CLONE ULTIMATE - VERSION 3.13 (1K SCALED EDITION)
# ==============================================================================
#
# PERFORMANCE TUNING (Post-Load Test):
#   ⚡ Scaling: Increased Web Nodes to 5 to handle Auth handshake load.
#   ⚡ Database: Max Connections -> 1000 to prevent starvation.
#   ⚡ Nginx: Increased timeouts to prevent 502/504 during storms.
#   ✅ Deduplication: Clears chat log on sync to prevent UUID/Int ID conflicts.
#   ✅ UX: Mobile UI, Video Handoff, and Smart Notifications included.
# ==============================================================================

PROJECT_ROOT="line_clone_v3_13"

echo "✨ Starting v3.13 Scaled Installation for: $PROJECT_ROOT"

# --- STEP 0: Clean Slate ---
echo "🧹 Cleaning up old containers..."
docker stop line_backend line_db line_redis line_nginx 2>/dev/null || true
docker rm line_backend line_db line_redis line_nginx 2>/dev/null || true

# --- STEP 1: Directory Structure ---
echo "📂 Creating directory structure..."
mkdir -p "$PROJECT_ROOT"
cd "$PROJECT_ROOT"

mkdir -p app/line_project
mkdir -p app/chat_app
mkdir -p app/templates
mkdir -p nginx/certs
mkdir -p app/chat_app/management/commands

# --- STEP 2: SSL & Infrastructure ---

echo "🔐 Generating Self-Signed SSL Certificates..."
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout nginx/certs/selfsigned.key \
    -out nginx/certs/selfsigned.crt \
    -subj "/C=US/ST=Dev/L=Lab/O=LineClone/OU=IT/CN=localhost" 2>/dev/null

echo "🐳 Generating Dockerfile..."
cat > app/Dockerfile <<'EOF'
FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y gcc libpq-dev netcat-openbsd && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir django daphne channels channels-redis psycopg2-binary uvicorn whitenoise redis
COPY . .
RUN mkdir -p staticfiles
RUN python manage.py collectstatic --noinput
EOF

echo "🐳 Generating docker-compose.yml (Scaled x5)..."
cat > docker-compose.yml <<'EOF'
version: '3.8'

services:
  # Load Balancer
  nginx:
    build: ./nginx
    container_name: line_nginx
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/certs:/etc/nginx/certs:ro
    depends_on:
      - web

  # Web Server (Scaled x5 for Auth Throughput)
  web:
    build: ./app
    # Boot: Wait DB -> Migrate -> Create Admin -> Start Daphne
    command: >
      sh -c "echo '⏳ Waiting for Database...' &&
             while ! nc -z db 5432; do sleep 1; done &&
             echo '✅ DB started. Running migrations...' &&
             python manage.py makemigrations chat_app &&
             python manage.py migrate &&
             echo '👤 Ensuring Admin User exists...' &&
             echo \"from django.contrib.auth import get_user_model; User = get_user_model(); User.objects.filter(username='admin').exists() or User.objects.create_superuser('admin', 'admin@example.com', 'password')\" | python manage.py shell &&
             echo '🚀 Starting Daphne...' &&
             daphne -b 0.0.0.0 -p 8000 line_project.asgi:application"
    volumes:
      - ./app:/app
    depends_on:
      - db
      - redis
    deploy:
      replicas: 5
    environment:
      - DEBUG=1
      - SECRET_KEY=prod-v3-13-scaled-secret
      - POSTGRES_DB=line_db
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=password
      - POSTGRES_HOST=db
      - ALLOWED_HOSTS=*
      - REDIS_HOST=redis
      # We rely on settings.py Middleware for CSRF

  # Background Worker (Scaled x2 for DB Writes)
  worker:
    build: ./app
    command: python manage.py run_chat_worker
    volumes:
      - ./app:/app
    depends_on:
      - db
      - redis
    deploy:
      replicas: 2
    environment:
      - DEBUG=1
      - SECRET_KEY=prod-v3-13-scaled-secret
      - POSTGRES_DB=line_db
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=password
      - POSTGRES_HOST=db
      - REDIS_HOST=redis

  db:
    image: postgres:15-alpine
    container_name: line_db
    environment:
      POSTGRES_DB: line_db
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: password
      POSTGRES_MAX_CONNECTIONS: 1000 # Increased for 1000 users + 5 replicas
    volumes:
      - postgres_data:/var/lib/postgresql/data

  redis:
    image: redis:7-alpine
    container_name: line_redis

volumes:
  postgres_data:
EOF

echo "🌐 Generating Nginx Config (Tuned Timeouts)..."
cat > nginx/Dockerfile <<'EOF'
FROM nginx:alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
EOF

cat > nginx/nginx.conf <<'EOF'
upstream django_app {
    least_conn; 
    server web:8000;
}

server {
    listen 80;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name _;

    ssl_certificate /etc/nginx/certs/selfsigned.crt;
    ssl_certificate_key /etc/nginx/certs/selfsigned.key;

    # TUNING: Allow long waits for "Thundering Herd" auth
    proxy_connect_timeout 75s;
    proxy_read_timeout 86400s;
    proxy_send_timeout 86400s;
    client_max_body_size 20M;

    location / {
        proxy_pass http://django_app;
        
        # SPOOF ORIGIN for Network Flexibility
        proxy_set_header Host $http_host;
        proxy_set_header Origin "https://$http_host"; 
        
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_redirect off;
    }

    location /ws/ {
        proxy_pass http://django_app;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_set_header Host $http_host;
        proxy_set_header Origin "https://$http_host";
        
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF

# --- STEP 3: Django Settings ---

echo "⚙️ Generating Django Settings..."
touch app/line_project/__init__.py
cat > app/manage.py <<'EOF'
#!/usr/bin/env python
import os, sys
def main():
    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'line_project.settings')
    try:
        from django.core.management import execute_from_command_line
    except ImportError as exc: raise ImportError("Couldn't import Django.") from exc
    execute_from_command_line(sys.argv)
if __name__ == '__main__': main()
EOF

cat > app/line_project/settings.py <<'EOF'
from pathlib import Path
import os

BASE_DIR = Path(__file__).resolve().parent.parent
SECRET_KEY = os.environ.get('SECRET_KEY', 'dev')
DEBUG = int(os.environ.get('DEBUG', 0))
ALLOWED_HOSTS = ['*']

CSRF_TRUSTED_ORIGINS = ['https://localhost', 'https://127.0.0.1']
SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')
CONN_MAX_AGE = 60 

class OriginSpoofMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response
    def __call__(self, request):
        if request.is_secure():
            request.META['HTTP_ORIGIN'] = 'https://localhost'
        return self.get_response(request)

INSTALLED_APPS = [
    'daphne',
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    'channels',
    'chat_app',
]

MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'whitenoise.middleware.WhiteNoiseMiddleware',
    'line_project.settings.OriginSpoofMiddleware', 
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]

ROOT_URLCONF = 'line_project.urls'
TEMPLATES = [{'BACKEND': 'django.template.backends.django.DjangoTemplates', 'DIRS': [BASE_DIR / 'templates'], 'APP_DIRS': True, 'OPTIONS': {'context_processors': ['django.template.context_processors.debug', 'django.template.context_processors.request', 'django.contrib.auth.context_processors.auth', 'django.contrib.messages.context_processors.messages']}}]
ASGI_APPLICATION = 'line_project.asgi.application'
CHANNEL_LAYERS = {"default": {"BACKEND": "channels_redis.core.RedisChannelLayer", "CONFIG": {"hosts": [("redis", 6379)]}}}
DATABASES = {'default': {'ENGINE': 'django.db.backends.postgresql', 'NAME': os.environ.get('POSTGRES_DB'), 'USER': os.environ.get('POSTGRES_USER'), 'PASSWORD': os.environ.get('POSTGRES_PASSWORD'), 'HOST': os.environ.get('POSTGRES_HOST'), 'PORT': '5432'}}
LANGUAGE_CODE = 'en-us'
TIME_ZONE = 'UTC'
USE_I18N = True
USE_TZ = True
STATIC_URL = 'static/'
STATIC_ROOT = BASE_DIR / 'staticfiles'
STATICFILES_STORAGE = 'whitenoise.storage.CompressedManifestStaticFilesStorage'
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

# --- STEP 4: Backend Logic ---

echo "💾 Generating Models..."
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
    sender = models.ForeignKey(User, on_delete=models.CASCADE, related_name='messages')
    content = models.TextField()
    timestamp = models.DateTimeField(auto_now_add=True)
    class Meta: ordering = ['timestamp']
    
    def to_json(self):
        return {
            'id': self.id,
            'username': self.sender.username,
            'message': self.content,
            'timestamp': self.timestamp.isoformat(),
            'msg_type': 'sticker' if (len(self.content) <= 2 or 'http' in self.content) else 'text'
        }
EOF

echo "🧠 Generating Views..."
cat > app/chat_app/views.py <<'EOF'
from django.shortcuts import render, redirect
from django.http import JsonResponse, HttpResponseForbidden
from django.contrib.auth import login, logout
from django.contrib.auth.forms import UserCreationForm, AuthenticationForm
from django.contrib.auth.decorators import login_required
from django.contrib.auth.models import User
from .models import Room, Message

def index_view(request):
    return redirect('chat_room', room_name='lobby') if request.user.is_authenticated else redirect('login')

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

@login_required
def start_dm(request, username):
    try: other = User.objects.only('id').get(username=username)
    except: return redirect('chat_room', room_name='lobby')
    u1, u2 = sorted([request.user.id, other.id])
    return redirect('chat_room', room_name=f"dm_{u1}_{u2}")

def check_permission(user, room_name):
    if not room_name.startswith("dm_"): return True
    try:
        parts = room_name.split('_')
        return user.id == int(parts[1]) or user.id == int(parts[2])
    except: return False

@login_required
def room_view(request, room_name):
    if not check_permission(request.user, room_name): return redirect('chat_room', room_name='lobby')
    display_name = room_name
    if room_name.startswith("dm_"):
        try:
            ids = [int(x) for x in room_name.split('_')[1:]]
            target_id = ids[1] if ids[0] == request.user.id else ids[0]
            display_name = User.objects.values_list('username', flat=True).get(id=target_id)
        except: display_name = "User"
    friends = User.objects.exclude(id=request.user.id).only('username')[:20]
    return render(request, 'room.html', {'room_name': room_name, 'display_name': display_name, 'friends': friends, 'groups': ["lobby", "general"], 'user': request.user})

@login_required
def history_api(request, room_name):
    if not check_permission(request.user, room_name): return JsonResponse({'messages': []}, status=403)
    try:
        room = Room.objects.get(name=room_name)
        msgs = Message.objects.filter(room=room).select_related('sender').order_by('-timestamp')[:100]
        return JsonResponse({'messages': [m.to_json() for m in reversed(msgs)]})
    except Room.DoesNotExist:
        return JsonResponse({'messages': []})
EOF

cat > app/chat_app/urls.py <<'EOF'
from django.urls import path
from . import views
urlpatterns = [
    path('', views.index_view, name='index'), path('login/', views.auth_view, {'auth_type': 'login'}, name='login'),
    path('signup/', views.auth_view, {'auth_type': 'signup'}, name='signup'), path('logout/', views.logout_view, name='logout'),
    path('dm/<str:username>/', views.start_dm, name='start_dm'), path('chat/<str:room_name>/', views.room_view, name='chat_room'),
    path('api/history/<str:room_name>/', views.history_api, name='history_api'),
]
EOF

echo "⚡ Fast Consumers (Write-Behind)..."
cat > app/chat_app/consumers.py <<'EOF'
import json, uuid, datetime, redis
from channels.generic.websocket import AsyncWebsocketConsumer
from channels.db import database_sync_to_async
from .models import Message, Room

r_conn = redis.Redis(host='redis', port=6379, db=0)

class NotifyConsumer(AsyncWebsocketConsumer):
    async def connect(self):
        self.user = self.scope["user"]
        if not self.user.is_authenticated: await self.close(); return
        self.group_name = f"notify_{self.user.id}"
        await self.channel_layer.group_add(self.group_name, self.channel_name)
        await self.accept()
    async def disconnect(self, c): await self.channel_layer.group_discard(self.group_name, self.channel_name)
    async def send_notification(self, e): await self.send(text_data=json.dumps(e))

class ChatConsumer(AsyncWebsocketConsumer):
    async def connect(self):
        self.user = self.scope["user"]
        if not self.user.is_authenticated: await self.close(); return
        self.room_name = self.scope['url_route']['kwargs']['room_name']
        if self.room_name.startswith("dm_"):
            try:
                p = self.room_name.split('_')
                if self.user.id != int(p[1]) and self.user.id != int(p[2]): await self.close(); return
            except: await self.close(); return
        self.room_group = f'chat_{self.room_name}'
        # Optimized: Don't check DB for room existence on connect (Lazy Creation in Worker)
        await self.channel_layer.group_add(self.room_group, self.channel_name)
        await self.accept()

    async def disconnect(self, c): await self.channel_layer.group_discard(self.room_group, self.channel_name)

    async def receive(self, text_data):
        try:
            d = json.loads(text_data)
            mtype = d.get('type', 'text')

            if mtype in ['call_offer', 'call_answer', 'new_ice_candidate', 'hang_up']:
                await self.channel_layer.group_send(self.room_group, {'type': 'signal', 'data': d, 'sender': self.user.username})
                if mtype == 'call_offer' and self.room_name.startswith("dm_"):
                    p = self.room_name.split('_'); tid = int(p[1]) if int(p[1]) != self.user.id else int(p[2])
                    await self.channel_layer.group_send(f"notify_{tid}", {'type': 'send_notification', 'room_name': self.room_name, 'caller': self.user.username, 'offer_data': d})
                return

            msg = d.get('message', '').strip()
            if not msg: return
            
            # WRITE-BEHIND
            ts = datetime.datetime.utcnow().isoformat()
            tid = str(uuid.uuid4())
            await self.channel_layer.group_send(self.room_group, {'type': 'chat_message', 'id': tid, 'message': msg, 'msg_type': mtype, 'username': self.user.username, 'timestamp': ts})
            
            task = {'room': self.room_name, 'user_id': self.user.id, 'content': msg}
            r_conn.rpush('chat_write_queue', json.dumps(task))
        except: pass

    async def signal(self, e): 
        if e['sender']!=self.user.username: await self.send(text_data=json.dumps(e['data']))
    async def chat_message(self, e): await self.send(text_data=json.dumps(e))
EOF

cat > app/chat_app/routing.py <<'EOF'
from django.urls import re_path
from . import consumers
websocket_urlpatterns = [re_path(r'ws/chat/(?P<room_name>[\w\-_]+)/$', consumers.ChatConsumer.as_asgi()), re_path(r'ws/notify/$', consumers.NotifyConsumer.as_asgi())]
EOF

echo "👷 Generating Background Worker..."
cat > app/chat_app/management/commands/run_chat_worker.py <<'EOF'
import json, redis, time
from django.core.management.base import BaseCommand
from django.contrib.auth.models import User
from chat_app.models import Room, Message

class Command(BaseCommand):
    help = 'Process chat messages from Redis queue'
    def handle(self, *args, **options):
        r = redis.Redis(host='redis', port=6379, db=0)
        print("👷 Worker started...")
        while True:
            try:
                item = r.blpop('chat_write_queue', 5)
                if item:
                    task = json.loads(item[1])
                    room, _ = Room.objects.get_or_create(name=task['room'])
                    user = User.objects.get(id=task['user_id'])
                    Message.objects.create(room=room, sender=user, content=task['content'])
            except Exception as e:
                print(f"❌ Error in worker: {e}")
                time.sleep(1)
EOF

# --- STEP 5: Frontend ---

echo "🎨 Generating Auth Template..."
cat > app/templates/auth.html <<'EOF'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Login</title><script src="https://cdn.tailwindcss.com"></script></head><body class="bg-gray-100 h-screen flex items-center justify-center"><div class="bg-white p-8 rounded shadow-md w-80"><h1 class="text-2xl mb-4 text-center">{{type}}</h1><form method="POST">{% csrf_token %}{% for field in form %}<div class="mb-4"><label class="block text-sm font-bold mb-2">{{field.label}}</label><input name="{{field.name}}" type="{{field.field.widget.input_type}}" class="w-full border p-2 rounded"></div>{% endfor %}<button class="w-full bg-green-500 text-white p-2 rounded">{{type}}</button></form><div class="mt-4 text-center"><a href="/signup/" class="text-sm text-blue-500">Switch Mode</a></div></div></body></html>
EOF

echo "🎨 Generating Chat Template..."
cat > app/templates/room.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover, interactive-widget=resizes-content">
    <title>{{ display_name|title }}</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
    <style>
        body { font-family: 'Inter', sans-serif; }
        .no-scrollbar::-webkit-scrollbar { display: none; }
        .bubble-me::after { content: ""; position: absolute; top: 0px; right: -8px; border-style: solid; border-width: 10px 0 0 10px; border-color: transparent transparent transparent #98e165; }
        .bubble-other::after { content: ""; position: absolute; top: 0px; left: -8px; border-style: solid; border-width: 0 10px 10px 0; border-color: transparent #ffffff transparent transparent; }
        .sticker-bounce { animation: bounce 0.4s; } @keyframes bounce { 0%, 100% { transform: scale(1); } 50% { transform: scale(1.15); } }
        .safe-pb { padding-bottom: env(safe-area-inset-bottom); }
        #video-overlay { z-index: 9999; }
        /* FIX: Mirror ONLY local video */
        #local-video { transform: scaleX(-1); object-fit: cover; }
        #remote-video { object-fit: cover; }
        .icon-off { display: none; }
        .btn-active .icon-on { display: none; }
        .btn-active .icon-off { display: block; }
        .btn-active { background-color: #ef4444; }
    </style>
</head>
<body class="bg-gray-100 h-[100dvh] w-screen flex overflow-hidden text-gray-800">

    <!-- GLOBAL NOTIFICATION BANNER -->
    <div id="global-notify" class="fixed top-4 left-1/2 transform -translate-x-1/2 bg-white/95 backdrop-blur shadow-2xl rounded-2xl p-3 z-[10000] hidden flex-col md:flex-row items-center border border-[#06C755] animate-bounce w-[90%] max-w-sm cursor-pointer">
        <div class="flex items-center w-full md:w-auto mb-2 md:mb-0">
            <div class="w-10 h-10 rounded-full bg-green-100 flex items-center justify-center text-xl mr-3 flex-shrink-0">📞</div>
            <div class="flex-1 min-w-0">
                <h3 class="font-bold text-gray-800 text-sm">Incoming Call</h3>
                <p id="notify-caller" class="text-xs text-gray-500 truncate">User is calling...</p>
            </div>
        </div>
        <div class="flex w-full md:w-auto justify-end">
            <button id="notify-accept" class="bg-[#06C755] text-white px-4 py-2 rounded-full text-xs font-bold shadow hover:bg-green-600 transition flex-1 md:flex-none text-center">ACCEPT</button>
            <button onclick="document.getElementById('global-notify').classList.add('hidden')" class="ml-2 text-gray-400 hover:text-gray-600 px-2">✕</button>
        </div>
    </div>

    <!-- VIDEO OVERLAY -->
    <div id="video-overlay" class="fixed inset-0 bg-black hidden flex-col transition-opacity duration-300">
        <video id="remote-video" autoplay playsinline class="w-full h-full bg-gray-900"></video>
        <div class="absolute top-4 right-4 w-28 h-40 md:w-40 md:h-60 bg-gray-800 rounded-xl overflow-hidden shadow-2xl border-2 border-white/20 z-[10001]">
            <video id="local-video" autoplay playsinline muted></video>
        </div>

        <!-- CONTROLS BAR -->
        <div class="absolute bottom-12 left-0 w-full flex justify-center items-center space-x-6 safe-pb z-[10002]">
            <button onclick="toggleAudio()" id="btn-audio" class="bg-gray-700/80 p-4 rounded-full text-white backdrop-blur-sm hover:bg-gray-600 transition">
                <svg class="w-6 h-6 icon-on" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"></path></svg>
                <svg class="w-6 h-6 icon-off" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z" clip-rule="evenodd" /><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2"/></svg>
            </button>
            <button onclick="endCall()" class="bg-red-600 p-5 rounded-full text-white shadow-xl scale-110 hover:bg-red-700 transition">
                <svg class="w-8 h-8" fill="currentColor" viewBox="0 0 24 24"><path d="M12 9c-1.6 0-3.15.25-4.6.72v3.1c0 .39-.23.74-.56.9-.98.49-1.87 1.12-2.66 1.85-.18.18-.43.28-.7.28-.28 0-.53-.11-.71-.29L.29 13.08c-.18-.17-.29-.42-.29-.7 0-.28.11-.53.29-.71C3.34 8.78 7.46 7 12 7s8.66 1.78 11.71 4.67c.18.18.29.43.29.71 0 .28-.11.53-.29.71l-2.48 2.48c-.18.18-.43.29-.71.29-.27 0-.52-.11-.7-.28-.79-.74-1.69-1.36-2.67-1.85-.33-.16-.56-.5-.56-.9v-3.1C15.15 9.25 13.6 9 12 9z"/></svg>
            </button>
            <button onclick="toggleVideo()" id="btn-video" class="bg-gray-700/80 p-4 rounded-full text-white backdrop-blur-sm hover:bg-gray-600 transition">
                <svg class="w-6 h-6 icon-on" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"></path></svg>
                <svg class="w-6 h-6 icon-off" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728A9 9 0 015.636 5.636m12.728 12.728L5.636 5.636"/></svg>
            </button>
        </div>

        <button onclick="toggleSpeaker()" id="btn-speaker" class="absolute top-6 right-6 bg-gray-700/80 p-3 rounded-full text-white hidden z-[10002]">
            <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15.536 8.464a5 5 0 010 7.072m2.828-9.9a9 9 0 010 12.728M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"></path></svg>
        </button>

        <!-- INCOMING CALL MODAL -->
        <div id="incoming-call-modal" class="absolute inset-0 bg-black/90 flex flex-col items-center justify-center hidden z-[10005]">
            <div class="w-32 h-32 rounded-full bg-gray-800 animate-pulse mb-6 flex items-center justify-center text-6xl shadow-2xl border-4 border-green-500/30">📞</div>
            <h2 class="text-white text-3xl font-bold mb-10 tracking-tight">Incoming Call...</h2>
            <div class="flex space-x-12">
                <button onclick="answerCall()" class="bg-green-500 hover:bg-green-600 p-8 rounded-full shadow-2xl animate-bounce text-white transform transition hover:scale-110">
                    <svg class="w-10 h-10" fill="currentColor" viewBox="0 0 24 24"><path d="M6.62 10.79c1.44 2.83 3.76 5.14 6.59 6.59l2.2-2.2c.27-.27.67-.36 1.02-.24 1.12.37 2.33.57 3.57.57.55 0 1 .45 1 1V20c0 .55-.45 1-1 1-9.39 0-17-7.61-17-17 0-.55.45-1 1-1h3.5c.55 0 1 .45 1 1 1.25 0 2.45.2 3.57.57.35.13.46.52.24 1.02l-2.2 2.2z"/></svg>
                </button>
                <button onclick="endCall()" class="bg-red-600 hover:bg-red-700 p-8 rounded-full shadow-2xl text-white transform transition hover:scale-110">
                    <svg class="w-10 h-10" fill="currentColor" viewBox="0 0 24 24"><path d="M12 9c-1.6 0-3.15.25-4.6.72v3.1c0 .39-.23.74-.56.9-.98.49-1.87 1.12-2.66 1.85-.18.18-.43.28-.7.28-.28 0-.53-.11-.71-.29L.29 13.08c-.18-.17-.29-.42-.29-.7 0-.28.11-.53.29-.71C3.34 8.78 7.46 7 12 7s8.66 1.78 11.71 4.67c.18.18.29.43.29.71 0 .28-.11.53-.29.71l-2.48 2.48c-.18.18-.43.29-.71.29-.27 0-.52-.11-.7-.28-.79-.74-1.69-1.36-2.67-1.85-.33-.16-.56-.5-.56-.9v-3.1C15.15 9.25 13.6 9 12 9z"/></svg>
                </button>
            </div>
        </div>
    </div>

    <!-- SIDEBAR -->
    <aside id="sidebar" class="fixed inset-y-0 left-0 w-80 bg-white border-r border-gray-200 flex flex-col transform -translate-x-full md:relative md:translate-x-0 transition-transform duration-300 z-30 shadow-2xl md:shadow-none h-full">
        <div class="h-16 flex items-center justify-between px-4 border-b border-gray-100 bg-gray-50 shrink-0">
            <h2 class="font-bold text-lg text-gray-800">Chats</h2>
            <a href="/logout/" class="text-xs font-bold text-red-500 hover:text-red-700">LOGOUT</a>
        </div>
        <div class="flex-1 overflow-y-auto">
            <div class="px-4 py-3 text-[10px] font-bold text-gray-400 uppercase tracking-widest bg-gray-50/50">Groups</div>
            {% for group in groups %}
            <a href="/chat/{{ group }}/" class="flex items-center px-4 py-3 hover:bg-gray-50 transition border-l-4 {% if group == room_name %}bg-green-50 border-[#06C755]{% else %}border-transparent{% endif %}">
                <div class="w-10 h-10 rounded-xl bg-gray-200 flex items-center justify-center text-gray-500 font-bold mr-3">#</div>
                <h3 class="text-sm font-medium capitalize text-gray-700">{{ group }}</h3>
            </a>
            {% endfor %}
            <div class="px-4 py-3 text-[10px] font-bold text-gray-400 uppercase tracking-widest bg-gray-50/50 mt-2">Friends</div>
            {% for friend in friends %}
            <a href="/dm/{{ friend.username }}/" class="flex items-center px-4 py-3 hover:bg-gray-50 transition border-l-4 border-transparent">
                <div class="w-10 h-10 rounded-full flex items-center justify-center text-white font-bold mr-3 shadow-sm avatar-holder" data-username="{{ friend.username }}">{{ friend.username|slice:":1" }}</div>
                <h3 class="text-sm font-semibold text-gray-700">{{ friend.username }}</h3>
            </a>
            {% endfor %}
        </div>
        <div class="p-4 border-t border-gray-100 bg-gray-50 shrink-0 flex items-center">
            <div class="w-8 h-8 rounded-full bg-[#06C755] flex items-center justify-center text-white font-bold text-xs shadow-sm">{{ user.username|slice:":1"|upper }}</div>
            <div class="ml-3"><p class="text-xs font-bold text-gray-700">{{ user.username }}</p><p class="text-[10px] text-green-500 font-bold">● Online</p></div>
        </div>
    </aside>

    <!-- MAIN CHAT -->
    <main class="flex-1 flex flex-col h-full relative bg-[#8C97A6]">
        <header class="h-16 shrink-0 bg-white/95 backdrop-blur shadow-sm flex items-center justify-between px-4 z-10 border-b border-gray-200">
            <div class="flex items-center">
                <button onclick="toggleSidebar()" class="md:hidden mr-3 text-gray-600 hover:text-[#06C755] p-1"><svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16"></path></svg></button>
                <div>
                    <h1 class="font-bold text-lg leading-tight capitalize text-gray-800">{{ display_name }}</h1>
                    {% if "dm_" not in room_name %}<p class="text-[10px] text-gray-500 font-medium">Group Chat</p>{% endif %}
                </div>
            </div>
            <div class="flex items-center space-x-3">
                <!-- VIDEO CALL BUTTON (ONLY SHOW IN DM) -->
                {% if "dm_" in room_name %}
                <button onclick="startCall()" class="text-gray-600 hover:text-green-500 p-2 rounded-full hover:bg-gray-100">
                    <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"></path></svg>
                </button>
                {% endif %}
                <div id="status-dot" class="w-3 h-3 rounded-full bg-yellow-500 shadow-sm" title="Connecting..."></div>
            </div>
        </header>

        <div id="chat-log" class="flex-1 overflow-y-auto p-4 space-y-2"></div>

        <div id="sticker-drawer" class="hidden bg-gray-50 border-t p-4 grid grid-cols-6 gap-2 shrink-0 z-20">
            <button onclick="sendSticker('🐻')" class="text-3xl hover:bg-gray-200 p-2 rounded transition">🐻</button>
            <button onclick="sendSticker('❤️')" class="text-3xl hover:bg-gray-200 p-2 rounded transition">❤️</button>
            <button onclick="sendSticker('😂')" class="text-3xl hover:bg-gray-200 p-2 rounded transition">😂</button>
            <button onclick="sendSticker('🎉')" class="text-3xl hover:bg-gray-200 p-2 rounded transition">🎉</button>
            <button onclick="sendSticker('👻')" class="text-3xl hover:bg-gray-200 p-2 rounded transition">👻</button>
            <button onclick="sendSticker('🚀')" class="text-3xl hover:bg-gray-200 p-2 rounded transition">🚀</button>
        </div>

        <div id="input-area" class="bg-white px-3 py-3 shrink-0 flex items-end space-x-2 border-t border-gray-200 safe-pb transition-opacity duration-300 z-50 relative">
            <button onclick="document.getElementById('sticker-drawer').classList.toggle('hidden')" class="text-gray-400 p-3 hover:bg-gray-100 rounded-full hover:text-[#06C755] transition flex-shrink-0">
                <svg class="w-7 h-7" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14.828 14.828a4 4 0 01-5.656 0M9 10h.01M15 10h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path></svg>
            </button>
            <div class="flex-1 bg-gray-100 rounded-2xl flex items-center px-4 py-2 focus-within:ring-2 focus-within:ring-[#06C755] focus-within:bg-white transition-all border border-transparent">
                <textarea id="chat-message-input" rows="1" class="w-full bg-transparent border-none focus:ring-0 resize-none text-[16px] text-gray-800 placeholder-gray-400 py-1 max-h-32" placeholder="Type a message..."></textarea>
            </div>
            <button id="send-btn" class="bg-[#06C755] hover:bg-[#05a546] text-white p-3 rounded-full shadow-md transition transform active:scale-95 disabled:opacity-50 flex-shrink-0">
                <svg class="w-5 h-5 rotate-90 translate-x-[1px]" fill="currentColor" viewBox="0 0 20 20"><path d="M10.894 2.553a1 1 0 00-1.788 0l-7 14a1 1 0 001.169 1.409l5-1.429A1 1 0 009 15.571V11a1 1 0 112 0v4.571a1 1 0 00.725.962l5 1.428a1 1 0 001.17-1.408l-7-14z"></path></svg>
            </button>
        </div>
    </main>

    <script>
        const roomName = "{{ room_name }}";
        const myUsername = "{{ user.username }}";
        const chatLog = document.getElementById('chat-log');
        const statusDot = document.getElementById('status-dot');
        const inputArea = document.getElementById('input-area');
        const CACHE_KEY = `chat_history_${myUsername}_${roomName}`;
        const seenIds = new Set(); 
        
        let localStream, remoteStream, peerConnection;
        const rtcConfig = { iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] };
        const iceCandidatesQueue = [];

        function getAvatarColor(u) { let h=0; for(let i=0;i<u.length;i++) h=u.charCodeAt(i)+((h<<5)-h); return `hsl(${Math.abs(h)%360},65%,55%)`; }
        document.querySelectorAll('.avatar-holder').forEach(el=>el.style.backgroundColor=getAvatarColor(el.dataset.username));

        function toggleSidebar() {
            const sb=document.getElementById('sidebar'), ov=document.getElementById('mobile-overlay');
            if(sb.classList.contains('-translate-x-full')) { sb.classList.remove('-translate-x-full'); ov.classList.remove('hidden'); setTimeout(()=>ov.classList.remove('opacity-0'),10); }
            else { sb.classList.add('-translate-x-full'); ov.classList.add('opacity-0'); setTimeout(()=>ov.classList.add('hidden'),300); }
        }

        function scrollToBottom(force=false) {
            const isNear = chatLog.scrollHeight - chatLog.scrollTop - chatLog.clientHeight < 100;
            if (force || isNear) setTimeout(() => chatLog.scrollTop = chatLog.scrollHeight, 10);
        }

        function escapeHtml(text) {
            if (!text) return text;
            return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#039;");
        }

        function renderMessage(data) {
            if (data.id && seenIds.has(data.id)) return;
            if (data.id) seenIds.add(data.id);

            const isMe = data.username === myUsername;
            const letter = data.username ? data.username[0].toUpperCase() : "?";
            const time = data.timestamp ? new Date(data.timestamp).toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'}) : "";
            
            let content = data.msg_type === 'sticker' ? `<div class="text-5xl sticker-bounce mb-1">${escapeHtml(data.message)}</div>` 
                : `<div class="relative px-3 py-2 text-[15px] shadow-sm rounded-lg ${isMe ? 'rounded-tr-none bg-[#98e165] text-black bubble-me' : 'rounded-tl-none bg-white text-gray-800 bubble-other'} leading-snug break-words">${escapeHtml(data.message)}</div>`;

            const html = `
                <div class="flex w-full ${isMe ? 'justify-end' : 'justify-start'} mt-2 animate-fade-in-up">
                    ${!isMe ? `<div class="w-8 h-8 rounded-full border shadow-sm mr-2 flex items-center justify-center text-xs font-bold text-white uppercase mt-1" style="background-color:${getAvatarColor(data.username)}">${letter}</div>` : ''}
                    <div class="flex flex-col ${isMe ? 'items-end' : 'items-start'} max-w-[85%] md:max-w-[70%]">
                        ${!isMe ? `<span class="text-[10px] text-white/90 mb-1 ml-1 font-medium drop-shadow-md">${escapeHtml(data.username)}</span>` : ''}
                        ${content}
                        <div class="text-[9px] text-white/90 mt-1 ${isMe ? 'mr-1' : 'ml-1'} font-medium">${time}</div>
                    </div>
                </div>`;
            
            const div = document.createElement('div');
            div.innerHTML = html;
            chatLog.appendChild(div.firstElementChild);
            scrollToBottom();
        }

        const cached = localStorage.getItem(CACHE_KEY);
        if (cached) { JSON.parse(cached).forEach(m => renderMessage(m)); scrollToBottom(true); }

        window.onload = () => {
             fetch(`/api/history/${roomName}/`).then(r=>r.json()).then(data => {
                chatLog.innerHTML = ''; seenIds.clear(); // Reset to prevent UUID vs Int ID dupes
                data.messages.forEach(m => renderMessage(m));
                localStorage.setItem(CACHE_KEY, JSON.stringify(data.messages));
                // Handle pending call handoff
                const po = sessionStorage.getItem('pending_call_offer');
                if (po) {
                    sessionStorage.removeItem('pending_call_offer');
                    handleSignal(JSON.parse(po));
                }
            });
            if('setSinkId' in HTMLMediaElement.prototype) document.getElementById('btn-speaker').classList.remove('hidden');
        }

        // --- MEDIA CONTROLS ---
        function toggleVideo() {
            if(localStream) {
                const vidTrack = localStream.getVideoTracks()[0];
                vidTrack.enabled = !vidTrack.enabled;
                document.getElementById('btn-video').classList.toggle('btn-active');
            }
        }
        function toggleAudio() {
            if(localStream) {
                const audTrack = localStream.getAudioTracks()[0];
                audTrack.enabled = !audTrack.enabled;
                document.getElementById('btn-audio').classList.toggle('btn-active');
            }
        }
        async function toggleSpeaker() {
            const rv = document.getElementById('remote-video');
            if(!rv.sinkId) {
                const devices = await navigator.mediaDevices.enumerateDevices();
                const speakers = devices.filter(d => d.kind === 'audiooutput' && d.deviceId !== 'default');
                if(speakers.length > 0) await rv.setSinkId(speakers[0].deviceId);
            } else await rv.setSinkId('');
        }

        // --- NOTIFICATION SOCKET (Auto-Reconnect) ---
        let notifyWs;
        function connectNotify() {
             notifyWs = new WebSocket((window.location.protocol==='https:'?'wss':'ws')+'://'+window.location.host+'/ws/notify/');
             notifyWs.onmessage = (e) => {
                const d = JSON.parse(e.data);
                if(d.type === 'send_notification') {
                    if (d.room_name === roomName) return; 
                    const banner = document.getElementById('global-notify');
                    document.getElementById('notify-caller').innerText = d.caller + " is calling...";
                    
                    document.getElementById('notify-accept').onclick = () => {
                        sessionStorage.setItem('pending_call_offer', JSON.stringify({
                            type: 'call_offer',
                            offer: d.offer_data.offer,
                            sender: d.caller
                        }));
                        window.location.href = '/chat/' + d.room_name + '/';
                    };
                    
                    banner.classList.remove('hidden');
                    banner.classList.add('flex');
                    setTimeout(() => { banner.classList.add('hidden'); banner.classList.remove('flex'); }, 30000); 
                }
            };
            notifyWs.onclose = () => setTimeout(connectNotify, 3000); // Reconnect
        }
        connectNotify();

        // --- WEBRTC LOGIC ---
        async function startCall() {
            inputArea.classList.add('hidden'); // HIDE CHAT INPUT
            document.getElementById('video-overlay').classList.remove('hidden');
            document.getElementById('video-overlay').classList.add('flex');
            try {
                localStream = await navigator.mediaDevices.getUserMedia({ video: true, audio: true });
                document.getElementById('local-video').srcObject = localStream;
                createPeerConnection();
                localStream.getTracks().forEach(track => peerConnection.addTrack(track, localStream));
                const offer = await peerConnection.createOffer();
                await peerConnection.setLocalDescription(offer);
                sendSignal('call_offer', { offer: offer });
            } catch (err) { alert("Camera denied: " + err); endCall(); }
        }

        async function answerCall() {
            document.getElementById('incoming-call-modal').classList.add('hidden');
            try {
                localStream = await navigator.mediaDevices.getUserMedia({ video: true, audio: true });
                document.getElementById('local-video').srcObject = localStream;
                // Note: Tracks added inside handleSignal callback to ensure sequence
            } catch (err) { endCall(); }
        }

        function endCall() {
            if (peerConnection) peerConnection.close();
            if (localStream) localStream.getTracks().forEach(track => track.stop());
            document.getElementById('video-overlay').classList.add('hidden');
            document.getElementById('video-overlay').classList.remove('flex');
            document.getElementById('incoming-call-modal').classList.add('hidden');
            inputArea.classList.remove('hidden'); // SHOW CHAT INPUT
            sendSignal('hang_up', {});
            setTimeout(() => window.location.reload(), 500); 
        }

        function createPeerConnection() {
            peerConnection = new RTCPeerConnection(rtcConfig);
            peerConnection.onicecandidate = (event) => { if (event.candidate) sendSignal('new_ice_candidate', { candidate: event.candidate }); };
            peerConnection.ontrack = (event) => { 
                const rv = document.getElementById('remote-video');
                rv.srcObject = event.streams[0];
                rv.play().catch(e => console.log("Auto-play prevented"));
            };
        }

        async function handleSignal(data) {
            try {
                if (data.type === 'call_offer') {
                    // Only show incoming call if we are NOT the caller
                    inputArea.classList.add('hidden'); // HIDE CHAT INPUT
                    document.getElementById('video-overlay').classList.remove('hidden');
                    document.getElementById('video-overlay').classList.add('flex');
                    document.getElementById('incoming-call-modal').classList.remove('hidden');
                    document.getElementById('incoming-call-modal').classList.add('flex');
                    createPeerConnection();
                    await peerConnection.setRemoteDescription(new RTCSessionDescription(data.offer));
                    
                    const answerBtn = document.querySelector('#incoming-call-modal button.bg-green-500');
                    answerBtn.onclick = async () => {
                        document.getElementById('incoming-call-modal').classList.add('hidden');
                        localStream = await navigator.mediaDevices.getUserMedia({ video: true, audio: true });
                        document.getElementById('local-video').srcObject = localStream;
                        localStream.getTracks().forEach(track => peerConnection.addTrack(track, localStream));
                        const answer = await peerConnection.createAnswer();
                        await peerConnection.setLocalDescription(answer);
                        sendSignal('call_answer', { answer: answer });
                    };
                }
                else if (data.type === 'call_answer') {
                    await peerConnection.setRemoteDescription(new RTCSessionDescription(data.answer));
                    while(iceCandidatesQueue.length > 0) {
                        try { await peerConnection.addIceCandidate(new RTCIceCandidate(iceCandidatesQueue.shift())); } catch(e){}
                    }
                }
                else if (data.type === 'new_ice_candidate') {
                    const candidate = new RTCIceCandidate(data.candidate);
                    if (peerConnection && peerConnection.remoteDescription) {
                        await peerConnection.addIceCandidate(candidate);
                    } else {
                        iceCandidatesQueue.push(data.candidate);
                    }
                }
                else if (data.type === 'hang_up') endCall();
            } catch(e) { console.error("WebRTC Error", e); }
        }

        // WebSocket
        let ws;
        function connect() {
            const protocol = window.location.protocol === 'https:' ? 'wss' : 'ws';
            ws = new WebSocket(`${protocol}://${window.location.host}/ws/chat/${roomName}/`);
            ws.onopen = () => { statusDot.className = "w-3 h-3 rounded-full bg-green-500 shadow-green-500/50 shadow-lg"; inputArea.classList.remove('opacity-50', 'pointer-events-none'); };
            ws.onclose = () => { statusDot.className = "w-3 h-3 rounded-full bg-red-500 animate-pulse"; inputArea.classList.add('opacity-50', 'pointer-events-none'); setTimeout(connect, 3000); };
            ws.onmessage = (e) => {
                const data = JSON.parse(e.data);
                const signalType = data.type || data.msg_type;
                if (['call_offer', 'call_answer', 'new_ice_candidate', 'hang_up'].includes(signalType)) { 
                    handleSignal({ type: signalType, ...data }); 
                    return; 
                }
                renderMessage(data);
                let c = JSON.parse(localStorage.getItem(CACHE_KEY) || '[]');
                c.push(data); if(c.length>100) c=c.slice(-100);
                localStorage.setItem(CACHE_KEY, JSON.stringify(c));
            };
        }
        connect();

        function sendSignal(type, payload) { ws.send(JSON.stringify({ type: type, ...payload })); }

        const input = document.getElementById('chat-message-input');
        function send(msg, type='text') {
            if(!msg.trim()) return;
            if(ws.readyState === WebSocket.OPEN) {
                ws.send(JSON.stringify({message: msg, type: type}));
                if(type==='text') { input.value = ''; input.style.height='auto'; input.focus(); }
            }
        }
        document.getElementById('send-btn').onclick = () => send(input.value);
        window.sendSticker = (s) => { send(s, 'sticker'); document.getElementById('sticker-drawer').classList.add('hidden'); };
        
        input.addEventListener('input', function() { this.style.height='auto'; this.style.height=(this.scrollHeight)+'px'; });
        input.addEventListener('keydown', function(e) { if(e.key==='Enter' && !e.shiftKey) { e.preventDefault(); send(input.value); }});
    </script>
</body>
</html>
EOF

echo "✅ LINE CLONE v3.11 PERFORMANCE EDITION COMPLETE!"
echo "--------------------------------------------------------"
echo "1. Run: docker-compose up -d --scale web=3 --scale worker=2 --build"
echo "   (Running 3 Web Servers + 2 Background Workers)"
echo "2. URL: https://<YOUR_IP>"
echo "3. Test: Run chat_load_test_v3_12.sh"
echo "--------------------------------------------------------"