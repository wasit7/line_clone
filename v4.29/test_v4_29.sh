#!/bin/bash
set -e

# ==============================================================================
# 🧪 LINE CLONE v4.29 - DATA INTEGRITY TEST (STAGGERED TIMESTAMPS)
# ==============================================================================
#
# UPDATES:
#   ✅ TIMESTAMP FIX: Removed bulk update() that flattened timestamps.
#      Now generates staggered timestamps (T + i*100ms) for correct ordering.
#   ✅ CHRONOLOGICAL GENERATION: Cycle 1 = Oldest (T-5m), Cycle 5 = Newest (T-1m).
#      This mimics real history build-up.
# ==============================================================================

PROJECT_ROOT="line_clone_v4_lake"
CONTAINER_NAME="${PROJECT_ROOT}-web-1"
TEST_SCRIPT_NAME="stress_test_integrity.py"

echo "🚀 Starting v4.29 Integrity Test..."

if ! docker ps | grep -q "$CONTAINER_NAME"; then
    echo "❌ Error: Container '$CONTAINER_NAME' is not running."
    exit 1
fi

echo "📝 Generating test payload..."
cat > "$TEST_SCRIPT_NAME" <<'EOF'
import os
import django
import time
import sys
import boto3
import datetime
from django.conf import settings
from django.utils import timezone
import pandas as pd
import io

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'line_project.settings')
django.setup()

from django.contrib.auth.models import User
from chat_app.models import Room, Message

ITERATIONS = 5
MESSAGES_PER_BATCH = 50
ROOM_NAME = "stress_test_integrity"
# We start 10 minutes ago to ensure everything is "old" enough for archiver
START_OFFSET_MINUTES = 10 

def get_s3_client():
    return boto3.client(
        's3',
        endpoint_url=f"http://{settings.MINIO_ENDPOINT}",
        aws_access_key_id=settings.MINIO_ACCESS_KEY,
        aws_secret_access_key=settings.MINIO_SECRET_KEY
    )

def clean_cold_storage():
    print("   🧹 Cleaning Cold Storage...")
    s3 = get_s3_client()
    bucket = settings.AWS_S3_BUCKET_NAME
    try:
        s3.head_bucket(Bucket=bucket)
        paginator = s3.get_paginator('list_objects_v2')
        for page in paginator.paginate(Bucket=bucket):
            if 'Contents' in page:
                delete_keys = [{'Key': o['Key']} for o in page['Contents']]
                s3.delete_objects(Bucket=bucket, Delete={'Objects': delete_keys})
    except: pass

def generate_traffic(iteration):
    # Generates history in chronological order:
    # Cycle 1: T - 9m (Oldest)
    # Cycle 2: T - 8m
    # ...
    # Cycle 5: T - 5m (Newest Cold Data)
    
    current_offset = START_OFFSET_MINUTES - iteration
    base_time = timezone.now() - datetime.timedelta(minutes=current_offset)
    
    print(f"   🔥 Generating Warm Traffic (Cycle {iteration} @ {base_time.strftime('%H:%M')})...")
    room, _ = Room.objects.get_or_create(name=ROOM_NAME)
    user, _ = User.objects.get_or_create(username="tester")
    
    msgs = []
    for i in range(MESSAGES_PER_BATCH):
        # Stagger timestamps by 100ms to ensure correct ordering
        msg_time = base_time + datetime.timedelta(milliseconds=i*100)
        msgs.append(Message(
            room=room, 
            sender=user, 
            content=f"C{iteration}-{i} {msg_time}", 
            timestamp=msg_time
        ))

    Message.objects.bulk_create(msgs)
    print(f'{sys._getframe().f_code.co_name}: finished!!')
    return room

def verify_warm_to_cold(room):
    print("   ⏳ Waiting for Archiver...")
    for i in range(40): 
        time.sleep(2)
        if Message.objects.filter(room=room).count() == 0:
            print("\n      ✅ Archived.")
            return True
        sys.stdout.write(".")
        sys.stdout.flush()
    print(f'{sys._getframe().f_code.co_name}: finished!!')
    return False

def verify_data_integrity(expected_total):
    print(f"   🧊 Verifying Message Count (Expect >= {expected_total})...")
    s3 = get_s3_client()
    bucket = settings.AWS_S3_BUCKET_NAME
    room = Room.objects.get(name=ROOM_NAME)
    prefix = f"chat_archive/room_{room.id}/"
    
    try:
        total_rows = 0
        paginator = s3.get_paginator('list_objects_v2')
        found_any = False
        for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
            if 'Contents' in page:
                found_any = True
                for obj in page['Contents']:
                    # Download and count rows in Parquet
                    obj_body = s3.get_object(Bucket=bucket, Key=obj['Key'])['Body'].read()
                    df = pd.read_parquet(io.BytesIO(obj_body))
                    total_rows += len(df)
        
        print(f"      - Actual Rows in Cold Storage: {total_rows}")
        
        if not found_any and expected_total > 0:
             print("      ❌ Error: No files found in MinIO prefix.")
             return False

        if total_rows >= expected_total:
            return True
        return False
    except Exception as e:
        print(f"      ❌ Error: {e}")
        return False

def run():
    clean_cold_storage()
    Message.objects.filter(room__name=ROOM_NAME).delete()
    
    total_expected = 0
    for i in range(1, ITERATIONS + 1):
        print(f"\n👉 CYCLE {i}")
        room = generate_traffic(i)
        total_expected += MESSAGES_PER_BATCH
        
        if not verify_warm_to_cold(room):
            print('why do i exit?') 
            exit(1)
        if not verify_data_integrity(total_expected): 
            print("      ❌ DATA LOSS DETECTED.")
            exit(1)
        print(f"   ✅ Cycle {i} OK.")
        time.sleep(1)
    print("\n🎉 SUCCESS!")

if __name__ == "__main__":
    run()
EOF

echo "📦 Copying payload..."
docker cp "$TEST_SCRIPT_NAME" "$CONTAINER_NAME:/app/"
echo "▶️  Executing..."
docker exec -it "$CONTAINER_NAME" python "$TEST_SCRIPT_NAME"
rm "$TEST_SCRIPT_NAME"
echo "✅ Done."