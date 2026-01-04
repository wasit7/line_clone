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
