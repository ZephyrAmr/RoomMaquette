import urllib.request
import json
import time
import sys

run_id = 45424994270
url = f"https://api.github.com/repos/ZephyrAmr/RoomMaquette/actions/runs/{run_id}"
headers = {'User-Agent': 'Antigravity-Agent'}

start = time.time()
print(f"Monitoring GitHub Actions Run {run_id}...")

while True:
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req) as response:
            data = json.loads(response.read().decode('utf-8'))
            status = data.get('status')
            conclusion = data.get('conclusion')
            elapsed = int(time.time() - start)
            print(f"[{elapsed}s] Status: {status}, Conclusion: {conclusion}")
            
            if status == 'completed':
                print(f"Run completed with conclusion: {conclusion}")
                
                # Check artifacts
                artifacts_url = data.get('artifacts_url')
                if artifacts_url:
                    req_art = urllib.request.Request(artifacts_url, headers=headers)
                    with urllib.request.urlopen(req_art) as resp_art:
                        art_data = json.loads(resp_art.read().decode('utf-8'))
                        artifacts = art_data.get('artifacts', [])
                        print("Artifacts generated:")
                        for a in artifacts:
                            size_mb = a['size_in_bytes'] / (1024 * 1024)
                            print(f" - {a['name']}: {size_mb:.2f} MB (ID: {a['id']})")
                
                if conclusion == 'success':
                    sys.exit(0)
                else:
                    sys.exit(1)
    except Exception as e:
        print(f"Query error: {e}")
    
    if time.time() - start > 500:
        print("Timeout waiting for build to complete.")
        sys.exit(2)
        
    time.sleep(15)
