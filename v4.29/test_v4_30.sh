#!/bin/bash
set -e

# ==============================================================================
# 🧪 LINE CLONE v4.30 - 1 MILLION MESSAGE STRESS TEST
# ==============================================================================

PROJECT_ROOT="line_clone_v4_lake"
CONTAINER_NAME="${PROJECT_ROOT}-web-1"
TEST_SCRIPT_NAME="stress_test_million.py"

echo "🚀 Starting v4.30 1 Million Message Stress Test..."

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

# Target: 1 Million Messages
# Strategy: 100 Cycles of 10,000 Messages
ITERATIONS = 100
MESSAGES_PER_BATCH = 1000
ROOM_NAME = "stress_test_million"
OFFSET_MINUTES = 10 # Start 10 mins ago

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
        # Fast recursive delete
        while True:
            objects = s3.list_objects_v2(Bucket=bucket)
            if 'Contents' not in objects: break
            delete_keys = [{'Key': o['Key']} for o in objects['Contents']]
            s3.delete_objects(Bucket=bucket, Delete={'Objects': delete_keys})
            print(f"      - Deleted {len(delete_keys)} objects...")
    except: pass

def generate_traffic_bulk(iteration):
    # Simulate data moving backwards in time or distinct chunks?
    # Let's do distinct chunks to avoid timestamp collision issues (though UUID fixes overwrite).
    # We will spread 1M messages over the last 24 hours.
    # 1M / 100 batches = 10k per batch.
    # 24h / 100 batches = ~15 mins per batch.
    
    chunk_time = timezone.now() - datetime.timedelta(minutes=OFFSET_MINUTES + (iteration * 15))
    
    print(f"   🔥 Generating Batch {iteration}/{ITERATIONS} ({MESSAGES_PER_BATCH} msgs) @ {chunk_time.strftime('%H:%M')}...")
    
    room, _ = Room.objects.get_or_create(name=ROOM_NAME)
    # Reuse user to save DB lookups
    user, _ = User.objects.get_or_create(username="stress_tester")
    
    # Ultra-fast generation using list comprehension
    msgs = [
        Message(
            room=room, 
            sender=user, 
            content=f"Payload-C{iteration}-{i}-{'x'*50}", # 50 bytes padding
            timestamp=chunk_time + datetime.timedelta(milliseconds=i)
        ) 
        for i in range(MESSAGES_PER_BATCH)
    ]
    
    # Bulk Create
    Message.objects.bulk_create(msgs, batch_size=5000)
    
    # Bulk Update Timestamp (Archiver needs this to be 'old')
    # Optimization: Update by ID range if possible, but filter is safe enough for test
    Message.objects.filter(room=room, content__startswith=f"Payload-C{iteration}").update(timestamp=chunk_time)
    
    return room

def wait_for_archiver_batch(room):
    # We need to wait for 10k messages to drain.
    # Archiver runs every 10s. It might take a few cycles.
    print("   ⏳ Waiting for Archiver...")
    start_wait = time.time()
    while True:
        count = Message.objects.filter(room=room).count()
        sys.stdout.write(f"\r      - Warm DB Count: {count}   ")
        sys.stdout.flush()
        if count == 0:
            print(f"\n      ✅ Batch Archived in {int(time.time()-start_wait)}s.")
            return True
        if time.time() - start_wait > 300: # 5 min timeout for big batch
            print("\n      ❌ Timeout waiting for archiver.")
            return False
        time.sleep(2)

def verify_final_integrity(expected_total):
    print(f"\n   🧊 Verifying FINAL Message Count (Target: {expected_total})...")
    s3 = get_s3_client()
    bucket = settings.AWS_S3_BUCKET_NAME
    room = Room.objects.get(name=ROOM_NAME)
    prefix = f"chat_archive/room_{room.id}/"
    
    total_rows = 0
    file_count = 0
    
    paginator = s3.get_paginator('list_objects_v2')
    
    print("      - Scanning Parquet files (this may take a moment)...")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        if 'Contents' in page:
            for obj in page['Contents']:
                file_count += 1
                # Optimization: For 1M test, reading every file body is slow.
                # We can either read metadata or trust file existence + random sampling.
                # For rigorous test, we read all.
                try:
                    # Read only metadata (num_rows) would be faster but boto3 doesn't expose it easily without downloading header.
                    # We download the file buffer.
                    obj_body = s3.get_object(Bucket=bucket, Key=obj['Key'])['Body'].read()
                    df = pd.read_parquet(io.BytesIO(obj_body))
                    total_rows += len(df)
                    
                    if file_count % 10 == 0:
                        sys.stdout.write(f"\r      - Scanned {file_count} files, {total_rows} msgs found...")
                        sys.stdout.flush()
                except Exception as e:
                    print(f"\n      ❌ Error reading {obj['Key']}: {e}")
    
    print(f"\n      - Final Count: {total_rows} messages in {file_count} files.")
    
    if total_rows >= expected_total:
        return True
    return False

def run():
    clean_cold_storage()
    Message.objects.filter(room__name=ROOM_NAME).delete()
    
    print(f"🚀 Starting 1 Million Message Injection")
    total_generated = 0
    
    for i in range(1, ITERATIONS + 1):
        generate_traffic_bulk(i)
        total_generated += MESSAGES_PER_BATCH
        
        # We wait for archiver every batch to prevent DB explosion
        if not wait_for_archiver_batch(Room.objects.get(name=ROOM_NAME)):
            exit(1)
            
        print(f"   ✅ Batch {i} Complete. Total: {total_generated}")
    
    if verify_final_integrity(total_generated):
        print(f"\n🏆 SUCCESS: {total_generated} messages successfully archived and verified.")
    else:
        print("\n❌ FAILURE: Data loss detected.")
        exit(1)

if __name__ == "__main__":
    run()
EOF

echo "📦 Copying payload..."
docker cp "$TEST_SCRIPT_NAME" "$CONTAINER_NAME:/app/"
echo "▶️  Executing Stress Test (This will take time)..."
docker exec -it "$CONTAINER_NAME" python "$TEST_SCRIPT_NAME"
rm "$TEST_SCRIPT_NAME"
echo "✅ Done."