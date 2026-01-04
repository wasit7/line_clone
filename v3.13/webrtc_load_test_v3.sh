#!/bin/bash
set -e

TARGET_URL=${1:-"https://localhost"}
CONCURRENT_USERS=${2:-500}
ADMIN_USER="admin"
ADMIN_PASS="password"

echo "🔥 Starting WEBRTC SIGNALING stress test against $TARGET_URL..."

if ! command -v python3 &> /dev/null; then echo "❌ Python3 required."; exit 1; fi
python3 -m pip install --user --quiet aiohttp numpy yarl

cat <<EOF > _webrtc_perf_runner.py
import asyncio
import aiohttp
import sys
import json
import time
import statistics
import yarl

BASE_URL = "$TARGET_URL"
if "https" in BASE_URL:
    WS_URL = BASE_URL.replace("https", "wss") + "/ws/chat"
else:
    WS_URL = BASE_URL.replace("http", "ws") + "/ws/chat"

USERNAME = "$ADMIN_USER"
PASSWORD = "$ADMIN_PASS"
CONCURRENT_USERS = $CONCURRENT_USERS
TARGET_ROOM = "load_test_room"

results = { "signal_times": [], "errors": [] }

async def webrtc_bot(session, user_id):
    uri = f"{WS_URL}/{TARGET_ROOM}/"
    headers = {'Origin': BASE_URL}

    try:
        async with session.ws_connect(uri, ssl=False, headers=headers) as ws:
            # Huge 4KB SDP payload to stress Redis
            sdp_data = "v=0\r\no=- 48674368725835678 2 IN IP4 127.0.0.1\r\n" + ("a=candidate:fake 1 UDP 2130706431 192.168.1.1 50000 typ host\r\n" * 40)
            
            signal_payload = json.dumps({
                "type": "call_offer",
                "offer": {"sdp": sdp_data, "type": "offer"},
                "message": "" 
            })
            
            t_start = time.perf_counter()
            await ws.send_str(signal_payload)
            await ws.send_str(json.dumps({"message": "ping", "type": "text"})) 
            
            async for msg in ws:
                if msg.type == aiohttp.WSMsgType.TEXT:
                    data = json.loads(msg.data)
                    if data.get('message') == 'ping':
                        break
            
            results["signal_times"].append((time.perf_counter() - t_start) * 1000)
            
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

        print(f"🚀 Stressing Signaling with {CONCURRENT_USERS} calls...")
        tasks = []
        for i in range(CONCURRENT_USERS):
            tasks.append(asyncio.create_task(webrtc_bot(session, i)))
            await asyncio.sleep(0.01) # Gentle ramp-up

        await asyncio.gather(*tasks)

        print("\n" + "="*40)
        print(f"🎥 WEBRTC SIGNALING REPORT")
        print("="*40)
        
        if results["signal_times"]:
            avg_sig = statistics.mean(results["signal_times"])
            max_sig = max(results["signal_times"])
            print(f"📡 Avg Latency:     {avg_sig:.2f} ms")
            print(f"⚠️ Max Latency:     {max_sig:.2f} ms")
        
        print(f"📉 Failures:        {len(results['errors'])}")
        print("="*40)

if __name__ == "__main__":
    asyncio.run(main())
EOF

python3 _webrtc_perf_runner.py
rm _webrtc_perf_runner.py