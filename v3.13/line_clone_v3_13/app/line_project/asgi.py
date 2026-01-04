import os, django
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'line_project.settings')
django.setup()
from django.core.asgi import get_asgi_application
from channels.routing import ProtocolTypeRouter, URLRouter
from channels.auth import AuthMiddlewareStack
from chat_app.routing import websocket_urlpatterns
application = ProtocolTypeRouter({"http": get_asgi_application(), "websocket": AuthMiddlewareStack(URLRouter(websocket_urlpatterns))})
