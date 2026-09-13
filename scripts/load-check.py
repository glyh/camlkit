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

# One library by name brings what it depends on. Filtering dune's whole list
# by name dropped them, and camlkit alone failed on Yojson__Safe.
one = call(5, "load", {"session": "one", "path": project, "libraries": ["camlkit"]})
one_used = call(6, "eval", {"session": "one", "code": "Camlkit.Render.bytes 2048;;"})

# A swap through a real load: the rewritten build, not the fixture the suite
# compiles by hand. transcript calls bytes inside Render, which is the call
# overwriting a module's field cannot reach. See docs/wayfinder/tickets/054.
swapped = call(7, "eval", {"session": "one", "code":
    '[%swap Camlkit.Render.bytes (fun _ -> "SWAPPED")];;\n'
    'Camlkit.Render.transcript "" [ { Wire.Msg.rendering = ""; warnings = ""; '
    'out_start = 0; out_len = 0; dropped = 0; ran = None; watched = []; '
    'cost = Some { Wire.Msg.wall_ms = 1.; allocated_bytes = 2048 } } ];;'})

# The wrapper half of `context`, which needs a dune project and so cannot be
# reached from dune test either: dune passes -open for a wrapped library, and
# that open is the one a reader cannot guess.
render = os.path.join(project, "lib", "render.ml")
opens = call(3, "context", {"file": render})
in_context = call(4, "eval", {"session": "s", "code": opens + "\ninfrastructure_failure;;"})

# A dune that cannot answer must not fall through to scanning the build tree.
# The scan finds the project's own libraries plus anything else built there,
# and none of the externals, which reads as a complete answer and is not one;
# see docs/wayfinder/tickets/040. Reproduced the way a client causes it: no
# dune on PATH and no switch to put one back.
blind = subprocess.Popen(
    [server], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
    bufsize=1, env=dict(os.environ, CAMLKIT_WORKER=worker,
                        PATH="/usr/bin:/bin", CAMLKIT_SWITCH="none"))
blind.stdin.write(json.dumps(
    {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
     "params": {"name": "load", "arguments": {"session": "s", "path": project}}}) + "\n")
blind.stdin.flush()
refused = json.loads(blind.stdout.readline())["result"]
try: blind.terminate(); blind.wait(timeout=5)
except Exception: blind.kill()
refused_text = refused["content"][0]["text"].strip()
refused_ok = (refused["structuredContent"].get("status") == "failed"
              and "dune could not say" in refused_text)

print("load said     :", loaded)
print("without dune  :", refused_text.split("\n")[0],
      "(expect a refusal, not a partial load)")
print("next phrase   :", after, "(expect a Warnings.loc value)")
print("one library   :", one, "/", one_used, "(expect camlkit with its deps)")
print("swap          :", swapped.replace("\n", " "), "(expect SWAPPED allocated)")
print("context said  :", opens.replace("\n", " "))
print("in context    :", in_context, "(expect a function, not Unbound value)")
ok = ("ocamltoplevel" not in loaded and "loc_ghost" in after
      and refused_ok and "not loaded" not in one and "2.0 kB" in one_used
      and "SWAPPED allocated" in swapped
      and "open Camlkit.Render;;" in opens and "Unbound" not in in_context)
print("PASS" if ok else "FAIL")
try: p.terminate(); p.wait(timeout=5)
except Exception: p.kill()
sys.exit(0 if ok else 1)
