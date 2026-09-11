#!/usr/bin/env python3
"""Exercise notifications/cancelled against camlkit. Usage:
     python3 cancel-check.py /path/to/camlkit /path/to/camlkit-worker"""
import json, subprocess, sys, time, os

server, worker = sys.argv[1], sys.argv[2]
env = dict(os.environ, CAMLKIT_WORKER=worker)
p = subprocess.Popen([server], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE, text=True, bufsize=1, env=env)
say = lambda o: (p.stdin.write(json.dumps(o) + "\n"), p.stdin.flush())
call = lambda i, t, a: say({"jsonrpc": "2.0", "id": i, "method": "tools/call",
                            "params": {"name": t, "arguments": a}})

call(1, "eval", {"session": "s", "code": "let rec spin n = spin (n+1) in spin 0;;"})
time.sleep(1)
say({"jsonrpc": "2.0", "method": "notifications/cancelled",
     "params": {"requestId": 1, "reason": "tester"}})
time.sleep(1)

call(2, "eval", {"session": "s", "code": "40 + 2;;"})
reply = json.loads(p.stdout.readline())
text = reply["result"]["content"][0]["text"].strip()

print("id of first reply seen:", reply["id"], "(expect 2: no reply for the cancelled call)")
print("session still usable   :", text, "(expect val _N : int = 42)")
ok = reply["id"] == 2 and "42" in text
print("PASS" if ok else "FAIL")
try: p.terminate(); p.wait(timeout=5)
except Exception: p.kill()
sys.exit(0 if ok else 1)
