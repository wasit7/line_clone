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
