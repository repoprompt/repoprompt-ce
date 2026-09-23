#!/usr/bin/env python3
"""Minimal ACP probe for `devin acp`: records session/new metadata, set_mode results,
and permission-request options. Never approves anything (answers `cancelled`)."""
import json, subprocess, sys, threading, queue, os, time, argparse
p = argparse.ArgumentParser()
p.add_argument("--pre", default="", help="args before acp (space separated)")
p.add_argument("--cwd", default="/tmp/devin-acp-probe/ws")
p.add_argument("--set-mode", nargs="*", default=[])
p.add_argument("--prompt")
p.add_argument("--load")
p.add_argument("--picker-meta", action="store_true")
p.add_argument("--midturn-mode")
p.add_argument("--enumerate-models", action="store_true")
p.add_argument("--cfg", nargs="*", default=[], help="id=value config option sets")
p.add_argument("--timeout", type=float, default=90)
a = p.parse_args()
os.makedirs(a.cwd, exist_ok=True)
cmd = ["devin", *a.pre.split(), "acp"]
proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open("/tmp/devin-acp-probe/devin-stderr.log","w"), text=True, bufsize=1)
q = queue.Queue()
threading.Thread(target=lambda: [q.put(json.loads(l)) for l in proc.stdout if l.strip()], daemon=True).start()
nid = [0]
stash = {}
out = {"cmd": cmd, "permission_requests": [], "set_mode": {}, "notifications": []}
def send(o): proc.stdin.write(json.dumps(o) + "\n"); proc.stdin.flush()
def call(method, params, timeout=a.timeout):
    nid[0] += 1; my = nid[0]; send({"jsonrpc": "2.0", "id": my, "method": method, "params": params})
    return wait(my, method, timeout)
def wait(my, method, timeout=a.timeout):
    end = time.time() + timeout
    while time.time() < end:
        if my in stash: return stash.pop(my)
        try: m = q.get(timeout=1)
        except queue.Empty: continue
        if "method" not in m and "id" in m:
            if m["id"] == my: return m
            stash[m["id"]] = m; continue
        if "method" in m and "id" in m:  # agent -> client request
            if m["method"] == "session/request_permission":
                pr = m["params"]; out["permission_requests"].append({"toolCall": {k: pr.get("toolCall", {}).get(k) for k in ("title", "kind")}, "options": pr.get("options"), "full": pr})
                out.setdefault("perm_times", []).append(time.time()); send({"jsonrpc": "2.0", "id": m["id"], "result": {"outcome": {"outcome": "cancelled"}}})
            else:
                send({"jsonrpc": "2.0", "id": m["id"], "error": {"code": -32601, "message": "not supported"}})
        elif "method" in m:
            u = m.get("params", {}).get("update", {})
            kind = u.get("sessionUpdate")
            if kind in ("current_mode_update", "config_option_update", "config_options_update"): out["notifications"].append(u)
            if kind in ("tool_call", "tool_call_update"): out.setdefault("tool_calls", []).append({"t": time.time(), "u": u})
    return {"timeout": method}
init = call("initialize", {"protocolVersion": 1, "clientCapabilities": dict({"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False}, **({"_meta": {"parameterizedModelPicker": True}} if a.picker_meta else {}))})
out["initialize"] = init.get("result", init)
if a.load:
    new = call("session/load", {"sessionId": a.load, "cwd": a.cwd, "mcpServers": []})
    r = new.get("result", new.get("error", new)); out["session_new"] = r; out["loaded"] = True
    sid = a.load
else:
    new = call("session/new", {"cwd": a.cwd, "mcpServers": []})
    r = new.get("result", new); out["session_new"] = r
    sid = r.get("sessionId")
for mode in a.set_mode:
    res = call("session/set_mode", {"sessionId": sid, "modeId": mode}, 20)
    res2 = call("session/set_config_option", {"sessionId": sid, "configId": "mode", "value": mode}, 20)
    out["set_mode"][mode] = {"set_mode": res.get("result", res.get("error")), "set_config_option": res2.get("result", res2.get("error"))}
out["cfg"]={}
for kv in a.cfg:
    k,v=kv.split("=",1)
    res=call("session/set_config_option", {"sessionId": sid, "configId": k, "value": v}, 20)
    r2=res.get("result", res.get("error", res))
    if isinstance(r2,dict) and "configOptions" in r2: r2={o["id"]:(o.get("currentValue"), [x.get("value") for x in o.get("options",[])] if o["id"]!="model" else None) for o in r2["configOptions"]}
    out["cfg"][kv]=r2
if a.enumerate_models and sid:
    opts=[o for o in r["configOptions"] if o["id"]=="model"][0]["options"]
    t0=time.time(); res_map={}
    for o in opts:
        t=time.time(); res=call("session/set_config_option", {"sessionId": sid, "configId": "model", "value": o["value"]}, 30)
        rr=res.get("result", {}); tl=[x for x in rr.get("configOptions",[]) if x["id"]=="thought_level"]
        res_map[o["value"]]={"ms": round((time.time()-t)*1000), "ok": "result" in res, "tl": (tl[0].get("currentValue"), [x["value"] for x in tl[0]["options"]]) if tl else None}
    out["enumerate"]={"count": len(opts), "total_ms": round((time.time()-t0)*1000), "models": res_map}
if a.midturn_mode and a.prompt and sid:
    nid[0]+=1; pid=nid[0]; send({"jsonrpc":"2.0","id":pid,"method":"session/prompt","params":{"sessionId":sid,"prompt":[{"type":"text","text":a.prompt}]}})
    time.sleep(4)
    res=call("session/set_config_option", {"sessionId": sid, "configId": "mode", "value": a.midturn_mode}, 30)
    out["midturn"]={"result": (lambda r2: {o["id"]:o.get("currentValue") for o in r2.get("configOptions",[])} if isinstance(r2,dict) else r2)(res.get("result", res.get("error", res)))}
    pr=wait(pid, "session/prompt"); out["prompt_result"]=pr.get("result", pr.get("error", pr))
    a.prompt=None
if a.prompt and sid:
    res = call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": a.prompt}]})
    out["prompt_result"] = res.get("result", res.get("error", res))
proc.terminate()
try: proc.wait(5)
except Exception: proc.kill()
out["stderr_tail"] = open("/tmp/devin-acp-probe/devin-stderr.log").read()[-1500:]
print(json.dumps(out, indent=1))
