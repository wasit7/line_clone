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
