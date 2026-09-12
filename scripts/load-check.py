#!/usr/bin/env python3
"""Load a dune project that depends on what the worker is itself built from,
and check the session survives it. Unreachable from `dune test`: the load
shells out to `dune top`, which will not run inside another dune. Usage:
     python3 load-check.py /path/to/camlkit /path/to/camlkit-worker [project]"""
import json, subprocess, sys, os

server, worker = sys.argv[1], sys.argv[2]
project = sys.argv[3] if len(sys.argv) > 3 else os.getcwd()
env = dict(os.environ, CAMLKIT_WORKER=worker)
p = subprocess.Popen([server], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     text=True, bufsize=1, env=env)

def call(i, tool, args):
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": "tools/call",
                              "params": {"name": tool, "arguments": args}}) + "\n")
    p.stdin.flush()
    return json.loads(p.stdout.readline())["result"]["content"][0]["text"].strip()

loaded = call(1, "load", {"session": "s", "path": project})
# compiler-libs is the fatal one: loading ocamltoplevel.cma over the live
# Toploop left the worker dead on the next phrase.
after = call(2, "eval", {"session": "s", "code": "Location.none;;"})

# The wrapper half of `context`, which needs a dune project and so cannot be
# reached from dune test either: dune passes -open for a wrapped library, and
# that open is the one a reader cannot guess.
render = os.path.join(project, "lib", "render.ml")
opens = call(3, "context", {"file": render})
in_context = call(4, "eval", {"session": "s", "code": opens + "\ninfrastructure_failure;;"})

print("load said     :", loaded)
print("next phrase   :", after, "(expect a Warnings.loc value)")
print("context said  :", opens.replace("\n", " "))
print("in context    :", in_context, "(expect a function, not Unbound value)")
ok = ("ocamltoplevel" not in loaded and "loc_ghost" in after
      and "open Camlkit.Render;;" in opens and "Unbound" not in in_context)
print("PASS" if ok else "FAIL")
try: p.terminate(); p.wait(timeout=5)
except Exception: p.kill()
sys.exit(0 if ok else 1)
