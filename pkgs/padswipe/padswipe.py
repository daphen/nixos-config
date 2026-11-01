# Proof of concept: two-trackpad swipe typing on the Steam Deck. LT is the left thumb's pen, RT the right's.
# JSON lines on stdout drive the overlay.
import json, math, os, select, subprocess, sys, threading, time

DECODER, ASSETS, LOG = sys.argv[1], sys.argv[2], sys.argv[3]
ROWS = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]; OFF = [0, .25, .75]
REGION = {"L": (0.0, 5.75), "R": (5.0, 10.0)}
REACH = 0.6            # pad travel that spans the whole half-keyboard; smaller is more sensitive
WORD_GAP_MS = 300      # both pens up this long ends the word
TAP_KEYS = 0.35        # a stroke that moves less than this is a tap on one letter
STEP_KEYS = 0.3        # a held thumb must move this far to add a point, so resting wobble does not zigzag the trace
BLOCK_PROFILE = os.environ["PADSWIPE_PROFILE"]
PEN = {"L": 0x02, "R": 0x01}          # report byte 8: L2 / R2 digital bits
A, B, X, R1, MENU = 0x80, 0x20, 0x40, 0x04, 1 << 14
DPAD_RIGHT, DPAD_LEFT = 1 << 9, 1 << 10

import ctypes, signal
ctypes.CDLL(None).prctl(1, signal.SIGTERM)   # PR_SET_PDEATHSIG: die with the overlay, or the mapping keeper would block the controller forever
def emit(**o): print(json.dumps(o), flush=True)
def ip(*a): return subprocess.run(["inputplumber", "device", "0", *a], capture_output=True, text=True).stdout
typed = ""              # what this keyboard has typed since it opened; the target field itself cannot be read
def wtype(*a):
    global typed
    subprocess.run(["wtype", *a])
    if a[0] != "-k": typed += a[0]
    elif a[1] == "Return": typed = ""
    elif a[1] == "BackSpace": typed = typed[:-1]
    emit(type="text", text=typed)

ip("profile", "load", BLOCK_PROFILE)

def keep_profile():
    # The Deck's mode sync can reload the normal mapping at any time; each check costs ~200 ms, so it runs off the input loop.
    while True:
        if BLOCK_PROFILE not in ip("profile", "path"):
            ip("profile", "load", BLOCK_PROFILE)
        time.sleep(0.5)
threading.Thread(target=keep_profile, daemon=True).start()

dec = subprocess.Popen([DECODER, ASSETS], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                       env={**os.environ, "QT_QPA_PLATFORM": "offscreen"}, stderr=subprocess.DEVNULL)
def controller():
    # InputPlumber hides the device from users, hence sudo; the hidraw number is not stable across boots.
    for h in sorted(os.listdir("/sys/class/hidraw")):
        dev = os.path.realpath(f"/sys/class/hidraw/{h}/device")
        uevent = open(f"{dev}/uevent").read()
        iface = os.path.join(dev, "..", "bInterfaceNumber")
        if "HID_ID=0003:000028DE:00001205" in uevent and os.path.exists(iface) and open(iface).read().strip() == "02":
            return f"/dev/{h}"
    sys.exit("Steam Deck controller not found")
hid = subprocess.Popen(["sudo", "-n", "cat", controller()], stdout=subprocess.PIPE, bufsize=0)
log = open(LOG, "a", buffering=1)

def to_kb(side, x, y):
    a, b = REGION[side]
    x = max(-1, min(1, x / REACH)); y = max(-1, min(1, y / REACH))
    return a + (x + 1) / 2 * (b - a), (1 - y) / 2 * 3

def nearest(p):
    r = max(0, min(2, int(p[1])))
    return min(ROWS[r], key=lambda c: abs(OFF[r] + ROWS[r].index(c) + .5 - p[0]))

pos = {"L": None, "R": None}
pen = {"L": False, "R": False}
tip = {"L": None, "R": None}       # latest position of each held pen, added on lift only if it reached a new key
strokes = []            # [side, [(x, y, t), ...]] in the order the pens went down
t0 = None; idle_since = None
last = {"text": None, "alts": [], "alt": 0}
buttons = None

def finish():
    global strokes, t0
    taps = all(math.dist(s[1][0][:2], p[:2]) < TAP_KEYS for s in strokes for p in s[1])
    visits = []         # each pen's path as key visits, merged by arrival time, so two moving pens do not zigzag point by point
    for _, pts in strokes:
        for i, p in enumerate(pts):
            if i == 0 or nearest(p) != nearest(pts[i - 1]): visits.append(p)
    trace = sorted(visits, key=lambda p: p[2])
    if taps:
        text = "".join(nearest(s[1][0]) for s in strokes); alts = [text]
    else:
        dec.stdin.write(" ".join(f"{x:.3f} {y:.3f} {t:.0f}" for x, y, t in trace) + "\n"); dec.stdin.flush()
        alts = [w.rsplit(":", 1)[0] for w in dec.stdout.readline().split()]
        text = alts[0] + " " if alts else ""
        if text and last["text"] and not last["text"].endswith(" "): text = " " + text
    if text:
        wtype(text)
        last.update(text=text, alts=alts, alt=0)
    emit(type="word", words=alts)
    log.write(json.dumps({"at": time.strftime("%H:%M:%S"), "taps": taps, "words": alts,
                          "strokes": [[s[0], s[1]] for s in strokes]}) + "\n")
    strokes = []; t0 = None

emit(type="ready")
start = time.monotonic()
while True:
    ready, _, _ = select.select([hid.stdout], [], [], 0.02)
    now = (time.monotonic() - start) * 1000
    r = hid.stdout.read(64) if ready else b""
    if ready and not r:
        break
    if len(r) == 64 and r[2] == 0x09:
        b = r[8] | r[9] << 8
        pressed = b & ~buttons if buttons is not None else 0      # ☰ that opened the keyboard may still be held
        buttons = b
        if pressed & MENU:
            sys.exit(0)
        if pressed & B:
            wtype(" "); last.update(text=None)
        if pressed & A:
            wtype("-k", "Return"); last.update(text=None)
        if pressed & X:
            for _ in range(len(last["text"]) if last["text"] else 1): wtype("-k", "BackSpace")
            last.update(text=None); emit(type="word", words=[])
        step = 1 if pressed & (R1 | DPAD_RIGHT) else -1 if pressed & DPAD_LEFT else 0
        if step and last["text"] and len(last["alts"]) > 1:
            lead = " " if last["text"].startswith(" ") else ""
            for _ in range(len(last["text"])): wtype("-k", "BackSpace")
            last["alt"] = (last["alt"] + step) % len(last["alts"])
            last["text"] = lead + last["alts"][last["alt"]] + " "; wtype(last["text"])
            emit(type="word", words=last["alts"][last["alt"]:] + last["alts"][:last["alt"]])
        lx = int.from_bytes(r[16:18], "little", signed=True); ly = int.from_bytes(r[18:20], "little", signed=True)
        rx = int.from_bytes(r[20:22], "little", signed=True); ry = int.from_bytes(r[22:24], "little", signed=True)
        for side, down, x, y in (("L", bool(r[10] & 8), lx, ly), ("R", bool(r[10] & 16), rx, ry)):
            if down:
                pos[side] = to_kb(side, x / 32768, y / 32768)
                emit(type="pt", side=side, x=round(pos[side][0], 3), y=round(pos[side][1], 3), owner=pen[side])
            elif pos[side] is not None:
                pos[side] = None; emit(type="up", side=side)
            held = bool(r[8] & PEN[side])
            if held and not pen[side] and pos[side]:
                if t0 is None: t0 = now; emit(type="draw", on=True)
                strokes.append([side, []])
            was = pen[side]
            pen[side] = held and (was or pos[side] is not None)
            stroke = next((s for s in reversed(strokes) if s[0] == side), None)
            if pen[side] and pos[side]:
                p = (*pos[side], now - t0)
                new = not stroke[1]
                if new or math.dist(stroke[1][-1][:2], p[:2]) > STEP_KEYS: stroke[1].append(p)
                tip[side] = p
                emit(type="trail", side=side, x=round(p[0], 3), y=round(p[1], 3), new=new)
            elif was and tip[side]:
                if nearest(tip[side]) != nearest(stroke[1][-1]): stroke[1].append(tip[side])
                tip[side] = None
    if strokes:
        if pen["L"] or pen["R"]:
            idle_since = None
        else:
            idle_since = idle_since or now
            if now - idle_since >= WORD_GAP_MS:
                finish(); idle_since = None; emit(type="draw", on=False)
