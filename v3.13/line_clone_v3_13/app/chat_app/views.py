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
