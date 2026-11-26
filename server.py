#!/usr/bin/env python3
"""Local Web UI and build controller. Bind to localhost by default."""
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse
from pathlib import Path
import json, os, subprocess, threading, time, queue, hashlib, mimetypes, urllib.parse

ROOT = Path(__file__).resolve().parent
WEB = ROOT / "web"
CONFIG = ROOT / "builder-config.json"
OUTPUT = ROOT / "output"
BUILD_SCRIPT = ROOT / "build.sh"
events = queue.Queue()
state = {"running": False, "status": "idle", "percent": 0, "message": "Ready"}
lock = threading.Lock()
proc = None

def emit(message, percent=None, status=None):
    with lock:
        state["message"] = message
        if percent is not None: state["percent"] = percent
        if status: state["status"] = status
        snapshot = dict(state)
    events.put({"type":"state","data":snapshot})

def run_build():
    global proc
    with lock:
        state.update(running=True,status="running",percent=1,message="Starting build")
    events.put({"type":"state","data":dict(state)})
    env=os.environ.copy()
    env["CONFIG_JSON"]=str(CONFIG)
    env["OUTPUT_DIR"]=str(OUTPUT)
    try:
        proc=subprocess.Popen([str(BUILD_SCRIPT),"build"],cwd=ROOT,env=env,
            stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
        for line in proc.stdout:
            line=line.rstrip()
            events.put({"type":"log","data":line})
            low=line.lower()
            if "clone openwrt" in low: emit("Mengunduh source OpenWrt",8)
            elif "fetch source" in low: emit("Memperbarui source OpenWrt",8)
            elif "update -a" in low or "feeds" in low: emit("Menyiapkan feeds dan paket",18)
            elif "download source packages" in low: emit("Mengunduh source paket",35)
            elif "compile firmware" in low: emit("Compile firmware (lihat log untuk detail)",45)
            elif "build selesai" in low: emit("Build selesai",100,"success")
        code=proc.wait()
        if code == 0:
            emit("Build berhasil",100,"success")
        else:
            emit(f"Build gagal (exit code {code})",100,"failed")
    except Exception as e:
        emit(f"Kesalahan menjalankan build: {e}",100,"failed")
    finally:
        with lock:
            state["running"]=False
            if state["status"]=="running": state["status"]="failed"
        proc=None
        events.put({"type":"state","data":dict(state)})

class Handler(SimpleHTTPRequestHandler):
    def __init__(self,*args,**kwargs):
        super().__init__(*args,directory=str(WEB),**kwargs)
    def log_message(self,fmt,*args): pass
    def do_GET(self):
        parsed=urlparse(self.path)
        if parsed.path=="/api/config":
            self.send_json(json.loads(CONFIG.read_text()) if CONFIG.exists() else {})
        elif parsed.path=="/api/status":
            with lock: self.send_json(dict(state))
        elif parsed.path=="/api/files":
            files=[]
            if OUTPUT.exists():
                for p in sorted(OUTPUT.iterdir()):
                    if p.is_file():
                        h=hashlib.sha256(p.read_bytes()).hexdigest()
                        files.append({"name":p.name,"size":p.stat().st_size,"sha256":h,"url":"/files/"+urllib.parse.quote(p.name)})
            self.send_json(files)
        elif parsed.path=="/api/events":
            self.send_response(200); self.send_header("Content-Type","text/event-stream")
            self.send_header("Cache-Control","no-cache"); self.send_header("Connection","keep-alive")
            self.end_headers()
            deadline=time.time()+20
            try:
                while time.time()<deadline:
                    try: item=events.get(timeout=2)
                    except queue.Empty: item={"type":"ping","data":{}}
                    self.wfile.write(("data: "+json.dumps(item)+"\n\n").encode()); self.wfile.flush()
            except (BrokenPipeError,ConnectionResetError): pass
        elif parsed.path.startswith("/files/"):
            name=Path(urllib.parse.unquote(parsed.path[len("/files/"):])).name
            p=OUTPUT/name
            if not p.is_file(): self.send_error(404); return
            data=p.read_bytes()
            self.send_response(200); self.send_header("Content-Type","application/octet-stream")
            self.send_header("Content-Disposition",f'attachment; filename="{name}"')
            self.send_header("Content-Length",str(len(data))); self.end_headers(); self.wfile.write(data)
        else:
            super().do_GET()
    def do_POST(self):
        global proc
        path=urlparse(self.path).path
        length=int(self.headers.get("Content-Length","0"))
        if length>1_000_000: self.send_error(413); return
        try: payload=json.loads(self.rfile.read(length) or b"{}")
        except Exception: self.send_error(400,"Invalid JSON"); return
        if path=="/api/config":
            # Basic input validation before persisting configuration.
            if payload.get("filesystem") not in ("squashfs","ext4"): self.send_error(400,"Invalid filesystem"); return
            if payload.get("boot",{}).get("bios") is False and payload.get("boot",{}).get("uefi") is False:
                self.send_error(400,"Select BIOS and/or UEFI"); return
            if not 256 <= int(payload.get("rootfs_size_mb",1024)) <= 65536: self.send_error(400,"Invalid rootfs size"); return
            CONFIG.write_text(json.dumps(payload,indent=2)+"\n")
            self.send_json({"ok":True})
        elif path=="/api/build":
            with lock:
                if state["running"]: self.send_error(409,"Build already running"); return
                state.update(running=True,status="queued",percent=0,message="Queued")
            t=threading.Thread(target=run_build,daemon=True); t.start()
            self.send_json({"ok":True})
        else: self.send_error(404)
    def send_json(self,obj):
        data=json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(data))); self.end_headers(); self.wfile.write(data)

if __name__=="__main__":
    import argparse
    ap=argparse.ArgumentParser()
    ap.add_argument("--host",default="127.0.0.1")
    ap.add_argument("--port",type=int,default=8787)
    args=ap.parse_args()
    print(f"OpenWrt Builder UI: http://{args.host}:{args.port}")
    print("Security: keep this bound to localhost; do not expose it to the public internet.")
    ThreadingHTTPServer((args.host,args.port),Handler).serve_forever()
