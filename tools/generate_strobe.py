import json, os, glob, subprocess, socket

import os as _os
bpm = 150
palette = ["#FF2D95","#25F4EE","#FEE440","#00F5D4","#9B5DE5","#F15BB5","#FF6B35","#01FFC3"]
W, H = 1500, 900

# pacing (seconds between events per lane) — tune density vs sync here
P = {
    "color":  float(_os.environ.get("P_COLOR",  "0.08")),
    "text":   float(_os.environ.get("P_TEXT",   "0.28")),
    "code":   float(_os.environ.get("P_CODE",   "0.55")),
    "stats":  float(_os.environ.get("P_STATS",  "0.65")),
    "image":  float(_os.environ.get("P_IMAGE",  "0.42")),
    "alert":  float(_os.environ.get("P_ALERT",  "0.26")),
    "move":   float(_os.environ.get("P_MOVE",   "0.13")),
    "cursor": float(_os.environ.get("P_CURSOR", "0.14")),
    "flash":  float(_os.environ.get("P_FLASH",  "0.15")),
    "flyers": int(_os.environ.get("N_FLYERS", "4")),
}
events = []
def add(t, typ, params): events.append({"t": round(t,3), "type": typ, "params": params})
def clampx(x, w): return max(20, min(x, W - w - 20))
def clampy(y, h): return max(20, min(y, H - h - 20))

def sh(cmd, default="n/a"):
    try:
        return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL, timeout=5).strip()
    except Exception:
        return default

# PERSONALIZE=1 pulls REAL system stats + images from ~/Desktop (local use only —
# do NOT commit the result). Default is sanitized placeholders, safe to publish.
PERSONALIZE = _os.environ.get("PERSONALIZE") == "1"

# --- desktop images (personalized only) ---
imgs = []
if PERSONALIZE:
    desktop = os.path.expanduser("~/Desktop")
    for ext in ("png","jpg","jpeg","heic","gif"):
        imgs += glob.glob(os.path.join(desktop, f"*.{ext}"))
        imgs += glob.glob(os.path.join(desktop, f"*.{ext.upper()}"))
    imgs = sorted(set(imgs))[:12]

# --- system stats ---
if PERSONALIZE:
    host   = socket.gethostname()
    cname  = sh("scutil --get ComputerName", host)
    osver  = sh("sw_vers -productVersion"); osbuild = sh("sw_vers -buildVersion")
    model  = sh("sysctl -n hw.model")
    ncpu   = sh("sysctl -n hw.ncpu")
    try:    memgb = f"{int(sh('sysctl -n hw.memsize','0'))/(1024**3):.0f} GB"
    except: memgb = "n/a"
    up     = sh("uptime")
    disk   = sh("df -h / | tail -1 | awk '{print $3\" used / \"$2\" (\"$5\")\"}'")
    ip     = sh("ipconfig getifaddr en0", "127.0.0.1")
    loadv  = sh("sysctl -n vm.loadavg | tr -d '{}'")
else:  # generic placeholders — no personal data
    host, cname = "your-mac", "Your-Mac"
    osver, osbuild = "15.0", "24A000"
    model, ncpu, memgb = "Mac", "10", "16 GB"
    up = "22:22  up 3 days,  4:20, 2 users, load averages: 1.20 3.40 5.60"
    disk = "420G used / 994G (44%)"
    ip = "192.168.0.42"
    loadv = " 1.20 3.40 5.60 "
_os_user = "you" if not PERSONALIZE else os.environ.get('USER','user')

stats_blocks = [
    f"$ whoami\n{_os_user}@{cname}\n\nhost   : {host}\nmodel  : {model}\nmacOS  : {osver} ({osbuild})\ncpu    : {ncpu} cores\nmemory : {memgb}\nloadavg:{loadv}",
    f"$ uptime\n{up}\n\ndisk / : {disk}\nen0    : {ip}\n\n[ system integrity: questionable ]",
    f"PID   COMMAND        %CPU\n1     launchd         0.0\n420   WindowServer   88.3\n666   chaos_daemon   ???\n1337  havoc.app      MAX\n\n> everything is fine",
]

code_blocks = [
    "func chaos() {\n  while true {\n    window.open(.random)\n    cursor.flee()\n  }\n}",
    "for (;;) {\n  spawn(alert);\n  desktop.shake();\n  // TODO: stop\n}",
    "def escape():\n    while trapped:\n        panic()\n    return None  # never",
    "if (reality == stable)\n    reality = undefined;\nrender(pandemonium);",
    "$ sudo rm -rf /calm\n$ ./summon --windows=∞\nsummoning... done.",
    "let vibes = try? load(.critical)\nguard vibes else {\n  fatalError(\"too calm\")\n}",
    "0x48 0x45 0x4C 0x50\nsegmentation fault\n(core dumped) 💀",
    "npm install chaos\n+ chaos@6.6.6\nadded 9001 packages\nfound ∞ vulnerabilities",
]

alerts = [
    ("KERNEL PANIC?", "just kidding. or am i?", ["ok", "OK?!"]),
    ("VIBES OVERFLOW", "buffer of good vibes exceeded at 0xC0FFEE", ["flush", "MORE"]),
    ("SEGMENTATION FAULT", "of the heart", ["core dump", "cry"]),
    ("UPDATE AVAILABLE", "reality.app 2.0 wants to install itself", ["not now", "never"]),
    ("MOUSE ESCAPED", "your cursor has left the building", ["catch it", "let it go"]),
    ("TOO MANY WINDOWS", "the windows are multiplying", ["close all", "open more"]),
    ("SYSTEM HONESTY", "you have 4,000 unread thoughts", ["ignore", "panic"]),
    ("DISK ALMOST FULL", "of screenshots, specifically", ["delete?", "hoard"]),
    ("ARE YOU STILL THERE?", "the desktop misses you", ["yes", "no"]),
    ("ACHIEVEMENT UNLOCKED", "witnessed maximum chaos", ["nice", "again"]),
    ("wetware error", "operator not found", ["retry", "abort"]),
    ("REMINDER", "you were supposed to be working", ["lol", "ok"]),
    ("NULL POINTER", "pointing at nothing, as usual", ["deref", "meh"]),
    ("do you trust me?", "no reason. just asking.", ["yes", "also yes"]),
]

texts = ["HELLO","YOU","LOOK","OVER HERE","404","RUN","NO ESCAPE","BEEP","CHAOS",
         "01001000","STARE","WAKE UP","CLICK","::::","glitch","∞","why","▓▓▓▓","AGAIN"]

# ---------- SCHEDULE ----------

# base color strobe (0–15s), dense
i, t = 0, 0.0
while t < 15.0:
    wid = f"c{i%8}"; col = palette[i%len(palette)]
    w = 180 + (i*53)%150; h = 150 + (i*37)%120
    x = clampx(120 + (i*173)%1200, w); y = clampy(80 + (i*127)%680, h)
    add(t, "openWindow", {"id":wid,"content":{"kind":"color","hex":col},"frame":[x,y,w,h],"animate":{"kind":"none"}})
    i += 1; t += P["color"]

# text windows
i, t = 0, 0.2
while t < 15.0:
    msg = texts[i%len(texts)]; w, h = 360, 170
    x = clampx(150 + (i*211)%1150, w); y = clampy(90 + (i*149)%660, h)
    add(t, "openWindow", {"id":f"tx{i%3}","content":{"kind":"text","text":msg},"frame":[x,y,w,h],"animate":{"kind":"none"}})
    i += 1; t += P["text"]

# code windows
i, t = 0, 0.5
while t < 15.0:
    code = code_blocks[i%len(code_blocks)]; w, h = 470, 300
    x = clampx(80 + (i*307)%1050, w); y = clampy(80 + (i*191)%560, h)
    add(t, "openWindow", {"id":f"kd{i%2}","content":{"kind":"code","text":code},"frame":[x,y,w,h],"animate":{"kind":"none"}})
    i += 1; t += P["code"]

# system-stats windows
i, t = 0, 0.9
while t < 15.0:
    blk = stats_blocks[i%len(stats_blocks)]; w, h = 440, 280
    x = clampx(120 + (i*263)%1000, w); y = clampy(90 + (i*173)%560, h)
    add(t, "openWindow", {"id":f"ss{i%2}","content":{"kind":"code","text":blk},"frame":[x,y,w,h],"animate":{"kind":"fadeIn"}})
    i += 1; t += P["stats"]

# random desktop images (cache-bounded set), some fly around
if imgs:
    i, t = 0, 0.6
    while t < 15.0:
        p = imgs[i%len(imgs)]; w, h = 360, 260
        wid = f"im{i%3}"
        x = clampx(100 + (i*233)%1150, w); y = clampy(90 + (i*167)%600, h)
        add(t, "openWindow", {"id":wid,"content":{"kind":"image","path":p},"frame":[x,y,w,h],"animate":{"kind":"springIn"}})
        i += 1; t += P["image"]

# random alerts (fake dialogs) — dense
i, t = 0, 0.35
while t < 15.0:
    title, body, btns = alerts[i%len(alerts)]
    w, h = 420, 170
    x = clampx(120 + (i*281)%1000, w); y = clampy(100 + (i*199)%560, h)
    add(t, "fakeDialog", {"id":f"al{i%4}","title":title,"body":body,"buttons":btns,"frame":[x,y,w,h]})
    i += 1; t += P["alert"]

# dedicated flyer windows (opened once, moved around fast)
for j in range(P["flyers"]):
    add(0.4, "openWindow", {"id":f"m{j}","content":{"kind":"color","hex":palette[(j+2)%len(palette)]},
                            "frame":[180+j*260,300,220,180],"animate":{"kind":"springIn"}})
i, t = 0, 0.6
while t < 15.0:
    j = i%P["flyers"]; w, h = 220, 180
    x = clampx(100 + (i*221)%1200, w); y = clampy(90 + (i*163)%660, h)
    add(t, "moveWindow", {"id":f"m{j}","frame":[x,y],"durationSeconds":0.2,"easing":"easeInOut"})
    if i % 6 == 0:
        add(t+0.02, "jiggle", {"id":f"m{j}","durationSeconds":0.4,"amplitude":26,"frequency":15})
    i += 1; t += P["move"]

# colored flashes throughout + white/black strobe climax (11.5–14s)
t, k = 0.05, 0
while t < 15.0:
    add(t, "screenFlash", {"color": palette[k%len(palette)], "durationSeconds":0.08})
    t += P["flash"]; k += 1
t, k = 11.5, 0
while t < 14.0:
    add(t, "screenFlash", {"color":"#FFFFFF" if k%2==0 else "#000000","durationSeconds":0.07})
    t += 0.18; k += 1   # ~5.5Hz, out of worst seizure band

# cursor zig-zag throughout
pts = [[200,200],[1300,250],[300,800],[1250,780],[700,150],[150,700],[1300,520],[600,820]]
i, t = 0, 1.0
while t < 14.5:
    a, b = pts[i%len(pts)], pts[(i+1)%len(pts)]
    add(t, "cursorPath", {"path":"linear","points":[a,b],"durationSeconds":0.16,"easing":"easeInOut","mode":"warp"})
    i += 1; t += P["cursor"]

# end: clear everything + final flashes
for j in range(8): add(15.05, "closeWindow", {"id":f"c{j}"})
for j in range(3): add(15.05, "closeWindow", {"id":f"tx{j}"})
for j in range(2): add(15.05, "closeWindow", {"id":f"kd{j}"}); add(15.05, "closeWindow", {"id":f"ss{j}"})
for j in range(3): add(15.05, "closeWindow", {"id":f"im{j}"})
for j in range(4): add(15.05, "closeWindow", {"id":f"al{j}"})
for j in range(P["flyers"]): add(15.05, "closeWindow", {"id":f"m{j}"})
add(15.05, "screenFlash", {"color":"#FFFFFF","durationSeconds":0.2})
add(15.4, "screenFlash", {"color":"#000000","durationSeconds":0.6})

doc = {"meta":{"audioFile":"song.wav","bpm":bpm,"beatOffset":0.0,"timelineLatency":0.0}, "events": events}
# repo-relative: tools/ -> repo root -> examples/
_repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.join(_repo, "examples", "timeline_strobe.json")
with open(out,"w") as f: json.dump(doc, f, separators=(",",":"))
print(f"wrote {len(events)} events → {out}")
print(f"desktop images used: {len(imgs)}")
print("stats sample:", stats_blocks[0].split(chr(10))[3] if len(stats_blocks[0].split(chr(10)))>3 else "")
