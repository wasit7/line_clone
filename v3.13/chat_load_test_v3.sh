#!/bin/bash
set -e

TARGET_URL=${1:-"https://localhost"}
CONCURRENT_USERS=${2:-1000}
ADMIN_USER="admin"
ADMIN_PASS="password"

echo "🔥 Starting CHAT WRITE-BEHIND stress test against $TARGET_URL..."

if ! command -v python3 &> /dev/null; then echo "❌ Python3 required."; exit 1; fi
python3 -m pip install --user --quiet aiohttp numpy yarl

cat <<EOF > _chat_perf_runner.py
import asyncio
import aiohttp
import sys
import json
import time
import statistics
import yarl
import random

BASE_URL = "$TARGET_URL"
if "https" in BASE_URL:
    WS_URL = BASE_URL.replace("https", "wss") + "/ws/chat"
else:
    WS_URL = BASE_URL.replace("http", "ws") + "/ws/chat"

USERNAME = "$ADMIN_USER"
PASSWORD = "$ADMIN_PASS"
CONCURRENT_USERS = $CONCURRENT_USERS
TARGET_ROOM = "load_test_room"

results = {
    "connect_times": [],
    "rtt_times": [],
    "errors": [],
    "successful": 0
}

async def chat_bot(session, user_id):
    uri = f"{WS_URL}/{TARGET_ROOM}/"
    headers = {'Origin': BASE_URL}

    try:
        t_start = time.perf_counter()
        async with session.ws_connect(uri, ssl=False, headers=headers) as ws:
            results["connect_times"].append((time.perf_counter() - t_start) * 1000)
            results["successful"] += 1
            
            payload = json.dumps({"message": f"ping_{user_id}", "type": "text"})
            
            t_rtt_start = time.perf_counter()
            await ws.send_str(payload)
            
            async for msg in ws:
                if msg.type == aiohttp.WSMsgType.TEXT:
                    break 
            
            # In Write-Behind, this should be near instant because we don't wait for DB
            results["rtt_times"].append((time.perf_counter() - t_rtt_start) * 1000)
            
    except Exception as e:
        results["errors"].append(str(e))

async def main():
    print(f"🔑 Authenticating...")
    connector = aiohttp.TCPConnector(limit=0, ssl=False)
    async with aiohttp.ClientSession(connector=connector) as session:
        try:
            async with session.get(BASE_URL + "/login/") as resp:
                await resp.text()
                csrf = session.cookie_jar.filter_cookies(yarl.URL(BASE_URL)).get('csrftoken').value
            
            await session.post(BASE_URL + "/login/", 
                data={'username': USERNAME, 'password': PASSWORD, 'csrfmiddlewaretoken': csrf},
                headers={'Referer': BASE_URL + "/login/"})
        except Exception as e:
            print(f"❌ Auth Failed: {e}")
            sys.exit(1)

        print(f"🚀 Measuring WRITE-BEHIND latency with {CONCURRENT_USERS} users...")
        tasks = []
        for i in range(CONCURRENT_USERS):
            tasks.append(asyncio.create_task(chat_bot(session, i)))
            await asyncio.sleep(0.01) # Gentle ramp-up

        await asyncio.gather(*tasks)

        print("\n" + "="*40)
        print(f"💬 CHAT PERFORMANCE REPORT (Async DB Write)")
        print("="*40)
        
        if results["connect_times"]:
            avg_conn = statistics.mean(results["connect_times"])
            print(f"🔌 Connect Latency: {avg_conn:.2f} ms")
        
        if results["rtt_times"]:
            avg_rtt = statistics.mean(results["rtt_times"])
            max_rtt = max(results["rtt_times"])
            print(f"📨 Message RTT:     {avg_rtt:.2f} ms (Avg)")
            print(f"🚀 Max Lag:         {max_rtt:.2f} ms")
            if avg_rtt < 100: print("✅ EXCELLENT PERFORMANCE")
            else: print("⚠️  Latency detected")
        
        print(f"✅ Success Rate:     {results['successful']}/{CONCURRENT_USERS}")

if __name__ == "__main__":
    asyncio.run(main())
EOF

python3 _chat_perf_runner.py
rm _chat_perf_runner.py