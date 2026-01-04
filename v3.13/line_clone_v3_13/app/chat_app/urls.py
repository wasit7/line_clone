from django.urls import path
from . import views
urlpatterns = [
    path('', views.index_view, name='index'), path('login/', views.auth_view, {'auth_type': 'login'}, name='login'),
    path('signup/', views.auth_view, {'auth_type': 'signup'}, name='signup'), path('logout/', views.logout_view, name='logout'),
    path('dm/<str:username>/', views.start_dm, name='start_dm'), path('chat/<str:room_name>/', views.room_view, name='chat_room'),
    path('api/history/<str:room_name>/', views.history_api, name='history_api'),
]
