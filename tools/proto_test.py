#!/usr/bin/env python3
"""Firmware acceptance over CDC (docs/03-protocol.md §3.4, checklist docs/04-firmware.md §4.9).

  python3 tools/proto_test.py                 # automatic checks, ~20 s
  python3 tools/proto_test.py --manual        # + checks done by eye and by hand
  python3 tools/proto_test.py --pending       # only manual checks that haven't passed yet
  python3 tools/proto_test.py --only buttons  # selected checks (comma-separated)
  python3 tools/proto_test.py --list          # all checks and their latest result

The latest result of each check is written to tools/proto_test-results.json.

The daemon holds the port and catches !BTN — it has to be stopped. --stop-daemon does that itself
and starts it again on exit. HID isn't tested here: the daemon tests it itself.
"""
import argparse, atexit, datetime, glob, json, os, queue, re, subprocess, sys, threading, time

import serial

LABEL = "dev.grisha-gu.agentlight.daemon"
PLIST = os.path.expanduser(f"~/Library/LaunchAgents/{LABEL}.plist")
COLORS = ["red", "yellow", "green"]
SLOTS = 4
LEDS = 12
WD_TIMEOUT = 3.0
RESULTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "proto_test-results.json")

# power= — since fw 0.6.0 (power switch on GP26)
IDENT = re.compile(r"agentlight proto=1 fw=(\d+\.\d+\.\d+) slots=4 uid=([0-9A-F]{16})(?: power=(on|off))?$")
PONG = re.compile(r"OK PONG (\d+) uptime=(\d+) wd=([01])$")


class Fail(Exception):
    pass


class Skip(Exception):
    pass


def check(cond, msg):
    if not cond:
        raise Fail(msg)


class Device:
    """CDC port: command replies (OK/ERR) and asynchronous events (!…) are sorted into queues.
    Heartbeat is a separate thread, like in the real host; without it everything goes dark after the first PING."""

    def __init__(self, port):
        self.port = port
        self.lock = threading.RLock()
        self.resp = queue.Queue()
        self.events = queue.Queue()
        self.ser = None
        self.seq = 0
        self.last_ping = 0.0
        self.heartbeat = threading.Event()
        threading.Thread(target=self._beat, daemon=True).start()

    def open(self):
        # The firmware sends !READY on the DTR edge, and pyserial flushes the input buffer in open() —
        # so open with DTR low and raise it once the reader is running.
        self.ser = serial.Serial(None, 115200, timeout=0.05)
        self.ser.port = self.port
        self.ser.dtr = False
        self.ser.open()
        self.stop = threading.Event()
        self.reader = threading.Thread(target=self._read, args=(self.ser, self.stop), daemon=True)
        self.reader.start()
        time.sleep(0.05)
        self.ser.dtr = True

    def close(self):
        # Wait for the reader first: otherwise it may wake up on a new port
        # with the same descriptor number and eat the !READY.
        with self.lock:
            if not self.ser:
                return
            self.stop.set()
            self.reader.join()
            self.ser.close()
            self.ser = None

    def _read(self, ser, stop):
        buf = b""
        while not stop.is_set():
            try:
                chunk = ser.read(256)
            except (serial.SerialException, OSError, TypeError):
                break
            buf += chunk
            while b"\n" in buf:
                raw, buf = buf.split(b"\n", 1)
                line = raw.decode("ascii", "replace").strip()
                if not line:
                    continue
                (self.events if line.startswith("!") else self.resp).put((time.monotonic(), line))

    def _beat(self):
        while True:
            time.sleep(0.1)
            if self.heartbeat.is_set() and self.ser and time.monotonic() - self.last_ping >= 1.0:
                try:
                    self.ping()
                except Exception:
                    pass

    def write(self, line):
        self.ser.write((line + "\n").encode())

    def cmd(self, line, timeout=1.0):
        with self.lock:
            self.write(line)
            try:
                return self.resp.get(timeout=timeout)[1]
            except queue.Empty:
                raise Fail(f"no reply to {line!r}")

    def ok(self, line):
        r = self.cmd(line)
        check(r == "OK", f"{line!r} → {r!r}, expected OK")

    def ping(self):
        with self.lock:
            self.seq += 1
            seq = self.seq
            r = self.cmd(f"PING {seq}")
            self.last_ping = time.monotonic()
        m = PONG.match(r)
        check(m and int(m.group(1)) == seq, f"PING {seq} → {r!r}")
        return int(m.group(2)), int(m.group(3))

    def drain(self):
        for q in (self.resp, self.events):
            while not q.empty():
                q.get_nowait()

    def wait_event(self, pattern, timeout):
        deadline = time.monotonic() + timeout
        while (left := deadline - time.monotonic()) > 0:
            try:
                t, line = self.events.get(timeout=left)
            except queue.Empty:
                break
            if re.match(pattern, line):
                return t, line
        return None

    def collect_events(self, seconds):
        time.sleep(seconds)
        out = []
        while not self.events.empty():
            out.append(self.events.get_nowait())
        return out


# --- automatic checks ------------------------------------------------------

def t_hello(d):
    r = d.cmd("HELLO")
    m = IDENT.match(r[3:]) if r.startswith("OK ") else None
    check(m, f"HELLO → {r!r}")
    check(d.cmd("hello") == r, "commands must be case-insensitive")
    return f"fw={m.group(1)} uid={m.group(2)}" + (f" power={m.group(3)}" if m.group(3) else "")


def t_commands(d):
    names = ["off", "idle", "busy", "attn"]
    for slot in range(SLOTS):
        for st in names + ["BUSY"]:
            d.ok(f"SET {slot} {st}")
    d.ok("SETALL idle busy attn off")
    d.ok("setall OFF off Off off")
    for slot in range(SLOTS):
        d.ok(f"WELCOME {slot}")
    d.ok("WELCOME ALL")
    d.ok("welcome all")
    for b in (0, 40, 255):
        d.ok(f"BRIGHT {b}")
    d.ok("CONFIG busy_pulse=1 idle_pulse=0")
    d.ok("CONFIG idle_pulse=1")
    d.ok("CONFIG busy_pulse=1 idle_pulse=0")
    d.ok("CONFIG")
    d.ok("RAW ff 00 00 00 ff 00 00 00 ff 80 80 80")
    d.ok("RAW " + " ".join(["0"] * LEDS))
    d.ok("SELFTEST")
    d.ok("SET 0 off")           # interrupts SELFTEST, returns to states
    d.ok("SETALL off off off off")
    d.ok("  SET\t1   idle  ")   # spaces and tabs between tokens
    d.ok("SET 1 off")


BAD = [
    ("SET 9 busy", "bad slot"),
    ("SET 4 idle", "bad slot"),
    ("SET 0 foo", "bad args"),
    ("SET 0", "bad args"),
    ("SET", "bad args"),
    ("SET x idle", "bad args"),
    ("SET 0 idle extra", "bad args"),
    ("SETALL idle busy", "bad args"),
    ("SETALL idle busy attn off off", "bad args"),
    ("SETALL idle busy attn nope", "bad args"),
    ("WELCOME 4", "bad slot"),
    ("WELCOME x", "bad slot"),
    ("WELCOME", "bad args"),
    ("WELCOME 0 1", "bad args"),
    ("BRIGHT 256", "bad args"),
    ("BRIGHT -1", "bad args"),
    ("BRIGHT", "bad args"),
    ("BRIGHT 1 2", "bad args"),
    ("PING", "bad args"),
    ("PING x", "bad args"),
    ("PING 4294967296", "bad args"),
    ("PING -1", "bad args"),
    ("SET -1 idle", "bad args"),
    ("BRIGHT +5", "bad args"),
    ("CONFIG foo=1", "bad args"),
    ("CONFIG attn_blink=1", "bad args"),   # red blinking was removed entirely
    ("CONFIG busy_pulse=2", "bad args"),
    ("CONFIG busy_pulse", "bad args"),
    ("RAW " + " ".join(["0"] * 11), "bad args"),
    ("RAW " + " ".join(["0"] * 13), "bad args"),
    ("RAW 100 " + " ".join(["0"] * 11), "bad args"),
    ("RAW zz " + " ".join(["0"] * 11), "bad args"),
    ("FOO", "unknown command"),
    ("SELF", "unknown command"),
]


def t_errors(d):
    for line, err in BAD:
        r = d.cmd(line)
        check(r == f"ERR {err}", f"{line!r} → {r!r}, expected 'ERR {err}'")
    # empty lines (\n, \r\n) are skipped silently; a line of spaces — ERR unknown command
    r = d.cmd("   ")
    check(r == "ERR unknown command", f"line of spaces → {r!r}")
    with d.lock:
        d.write("")
        d.write("\r")
        try:
            r = d.resp.get(timeout=0.3)[1]
            raise Fail(f"an empty line got a reply {r!r}")
        except queue.Empty:
            pass
    d.ok("SET 0 off")   # the parser is alive after errors
    return f"{len(BAD)} invalid commands"


def t_ping(d):
    up1, _ = d.ping()
    time.sleep(0.2)
    up2, _ = d.ping()
    check(up2 > up1, f"uptime isn't growing: {up1} → {up2}")
    r = d.cmd("PING 4294967295")
    check(PONG.match(r) and r.startswith("OK PONG 4294967295 "), f"max seq → {r!r}")
    d.last_ping = time.monotonic()


def t_stress(d, seconds=5.0, rate=200):
    """SET 0 busy ↔ SET 0 idle 200 times/s without waiting for replies; PING inside the stream."""
    n = int(seconds * rate)
    with d.lock:
        d.drain()
        start = time.monotonic()
        pings = 0
        for i in range(n):
            target = start + i / rate
            while (dt := target - time.monotonic()) > 0:
                time.sleep(min(dt, 0.002))
            d.write(f"SET 0 {'busy' if i % 2 == 0 else 'idle'}")
            if i % rate == 0:
                pings += 1
                d.write(f"PING {i}")
        sent_for = time.monotonic() - start
        oks = pongs = 0
        bad = []
        deadline = time.monotonic() + 2.0
        while oks + pongs + len(bad) < n + pings and time.monotonic() < deadline:
            try:
                line = d.resp.get(timeout=0.2)[1]
            except queue.Empty:
                continue
            if line == "OK":
                oks += 1
            elif line.startswith("OK PONG"):
                pongs += 1
            else:
                bad.append(line)
        d.last_ping = time.monotonic()
    wd = [l for _, l in list(d.events.queue) if l.startswith("!WD")]
    check(not bad, f"unexpected replies: {bad[:3]}")
    check(oks == n and pongs == pings, f"OK replies {oks}/{n}, PONG {pongs}/{pings}")
    check(not wd, "the watchdog tripped during the stress test")
    d.ok("SET 0 off")
    return f"{n} commands in {sent_for:.1f} s ({n / sent_for:.0f}/s)"


def t_reconnect(d):
    """Close and reopen the port (DTR) → !READY with the same identification."""
    hello = d.cmd("HELLO")[3:]
    d.close()
    time.sleep(0.5)
    d.drain()
    d.open()
    ev = d.wait_event(r"!READY ", 2.0)
    check(ev, "no !READY after reopening the port")
    check(ev[1][len("!READY "):] == hello, f"!READY {ev[1]!r} doesn't match HELLO {hello!r}")


def t_watchdog(d):
    d.heartbeat.set()
    d.ok("SETALL idle busy attn idle")
    d.ping()
    d.heartbeat.clear()
    time.sleep(0.3)   # the heartbeat thread may have already decided to send a PING
    with d.lock:
        t0 = d.last_ping
    d.drain()
    print(f"    heartbeat stopped, waiting {WD_TIMEOUT:.0f} s + 3 s…", flush=True)
    events = d.collect_events(WD_TIMEOUT + 3.0)
    trips = [t for t, l in events if l == "!WD trip"]
    check(len(trips) == 1, f"!WD trip arrived {len(trips)} times, expected exactly 1")
    after = trips[0] - t0
    check(WD_TIMEOUT - 0.1 <= after <= WD_TIMEOUT + 0.4, f"!WD trip after {after:.2f} s, expected ~{WD_TIMEOUT:.0f} s")
    _, wd = d.ping()
    check(wd == 1, "the first PONG after a trip must carry wd=1")
    _, wd = d.ping()
    check(wd == 0, "the second PONG must carry wd=0")
    d.heartbeat.set()
    return f"!WD trip after {after:.2f} s, once"


AUTO = [
    ("hello", "HELLO: version and uid", t_hello),
    ("commands", "all commands answer OK", t_commands),
    ("errors", "invalid arguments → ERR", t_errors),
    ("ping", "PING/PONG, uptime", t_ping),
    ("stress", "200 switches/s", t_stress),
    ("reconnect", "port reopen → !READY", t_reconnect),
    ("watchdog", "heartbeat loss → !WD trip", t_watchdog),
]


# --- manual checks ---------------------------------------------------------

def ask(question):
    while True:
        a = input(f"    {question} [y/n/s] ").strip().lower()
        if a in ("y", "yes"):
            return
        if a in ("n", "no"):
            note = input("    what's wrong? ").strip()
            raise Fail(note or "failed by eye")
        if a in ("s", "skip"):
            raise Skip("skipped")


def led_name(i):
    return f"slot {i // 3} {COLORS[i % 3]}"


def raw_one(i, level):
    levels = ["0"] * LEDS
    levels[i] = f"{level:x}"
    return "RAW " + " ".join(levels)


def m_raw_order(d):
    print("    lighting one at a time, 1 s each; slot 0 is the leftmost, top to bottom red/yellow/green")
    for i in range(LEDS):
        print(f"      GP{i:<2} {led_name(i)}", flush=True)
        d.ok(raw_one(i, 0xFF))
        time.sleep(1.0)
    d.ok("SETALL off off off off")
    ask("was exactly the printed LED lit each time?")


def m_fade(d):
    """Smoothness is checked on animations: they're computed in float all the way to PWM.
    RAW won't do — its input is 8 bits before gamma, and at the bottom neighboring levels
    differ in brightness several-fold (5 → 4 is −40 %), so steps there are unavoidable."""
    d.ok("CONFIG busy_pulse=1")
    fails = []
    for bright in (255, 30):
        print(f"    busy pulse on all slots, BRIGHT {bright}, 3 periods (6.6 s)", flush=True)
        d.ok(f"BRIGHT {bright}")
        d.ok("SETALL busy busy busy busy")
        time.sleep(6.6)
        d.ok("SETALL off off off off")
        time.sleep(0.5)
        try:
            ask(f"is the pulse at BRIGHT {bright} smooth, no jerks or steps?")
        except Fail as e:
            fails.append(f"pulse {bright}: {e}")
    print("    BRIGHT 30: green fades in and out (220 ms crossfade), 3 times", flush=True)
    for _ in range(3):
        d.ok("SETALL idle idle idle idle")
        time.sleep(1.0)
        d.ok("SETALL off off off off")
        time.sleep(1.0)
    d.ok("BRIGHT 255")
    try:
        ask("does it fade in and out smoothly, no jump at the very end?")
    except Fail as e:
        fails.append(f"crossfade: {e}")
    if fails:
        raise Fail("; ".join(fails))


def m_camera(d):
    print("    point your phone camera at the traffic lights: 8 s busy pulse + 100 % RAW")
    d.ok("CONFIG busy_pulse=1")
    d.ok("SETALL busy busy busy busy")
    time.sleep(4)
    d.ok("RAW " + " ".join(["ff"] * LEDS))
    time.sleep(4)
    d.ok("SETALL off off off off")
    ask("no bands or flicker on the phone screen?")


def m_stress(d):
    print("    watch slot 0: in 2 s — 5 s of SET busy ↔ idle 200 times/s, then OFF")
    time.sleep(2)
    print("      start", flush=True)
    note = t_stress(d)
    print(f"      end — {note}")
    ask("slot 0 didn't twitch, blink or flash (if it did — when and on which slot)?")


def m_welcome(d):
    print("    1) WELCOME ALL, after 0.5 s SETALL busy idle attn idle")
    d.ok("SETALL off off off off")
    time.sleep(0.5)
    d.ok("WELCOME ALL")
    time.sleep(0.5)
    d.ok("SETALL busy idle attn idle")
    time.sleep(3)
    print("    2) WELCOME 0, after 0.3 s SET 0 attn")
    d.ok("WELCOME 0")
    time.sleep(0.3)
    d.ok("SET 0 attn")
    time.sleep(3)
    ask("the animation didn't break, at the end: 1) yellow green red green, 2) slot 0 red?")
    d.ok("SETALL off off off off")


def m_idempotent(d):
    """If a repeated SET restarted the crossfade, green would get stuck dim near zero."""
    print("    slot 0: SET idle every 50 ms for 3 s")
    d.ok("SET 0 off")
    time.sleep(0.5)
    for _ in range(60):
        d.ok("SET 0 idle")
        time.sleep(0.05)
    d.ok("SET 0 off")
    ask("did green smoothly reach full brightness within a fraction of a second and then stay steady?")


def m_buttons(d):
    for slot in range(SLOTS):
        d.drain()
        print(f"    press the slot {slot} button ({slot + 1} from the left)", flush=True)
        ev = d.wait_event(r"!BTN ", 20.0)
        if not ev:
            raise Fail(f"button {slot}: no events in 20 s")
        check(re.match(rf"!BTN {slot} press t=\d+$", ev[1]), f"expected !BTN {slot} press, got {ev[1]!r}")
        extra = [l for _, l in d.collect_events(1.0) if l.startswith("!BTN")]
        check(not extra, f"button {slot}: bounce, extra {extra}")
        print(f"      {ev[1]}")
    d.drain()
    input("    now knock on the table and the case for 10 s, don't touch the buttons. Enter to start ")
    extra = [l for _, l in d.collect_events(10.0) if l.startswith("!BTN")]
    check(not extra, f"false triggers: {extra}")
    return "4 buttons, no false triggers"


def m_replug(d):
    d.heartbeat.clear()
    d.ok("SETALL idle busy attn idle")
    input("    the traffic lights are on. Unplug USB, plug it back in and press Enter ")
    d.close()
    d.drain()
    for _ in range(40):
        try:
            d.open()
            break
        except serial.SerialException:
            time.sleep(0.25)
    else:
        raise Fail("the port didn't come back after reconnecting")
    ev = d.wait_event(r"!READY ", 3.0)
    check(ev, "no !READY after reconnecting")
    print(f"      {ev[1]}")
    ask("are all traffic lights off (no commands yet)?")
    d.heartbeat.set()


def m_power(d):
    def hello_power():
        m = IDENT.match(d.cmd("HELLO")[3:])
        return m and m.group(3)

    check(hello_power() == "on", "before the check HELLO must say power=on — is GP26 connected to anything?")
    d.ok("SETALL idle busy attn idle")
    d.drain()
    print("    4 lights are on, one per traffic light: green, yellow, red, green.", flush=True)
    print("    Short GP26 to GND with a wire", flush=True)
    ev = d.wait_event(r"!POWER ", 30.0)
    check(ev and ev[1] == "!POWER off", f"expected !POWER off, got {ev and ev[1]!r}")
    extra = [l for _, l in d.collect_events(1.0) if l.startswith("!POWER")]
    check(not extra, f"power switch bounce: extra {extra}")
    check(hello_power() == "off", "HELLO while \"off\" must say power=off")
    ask("did all 4 lights fade out smoothly, and the onboard RGB on the module is off too?")

    d.drain()
    input("    press a couple of slot buttons (there must be no events), then Enter ")
    btn = [l for _, l in d.collect_events(0.2) if l.startswith("!BTN")]
    check(not btn, f"buttons must be silent while \"off\", but got {btn}")
    d.ok("SET 0 attn")   # a state sent while "off" must show up when "on"

    print("    remove the wire from GP26", flush=True)
    ev = d.wait_event(r"!POWER ", 30.0)
    check(ev and ev[1] == "!POWER on", f"expected !POWER on, got {ev and ev[1]!r}")
    check(hello_power() == "on", "HELLO after \"on\" must say power=on")
    ask("did the lights fade back in: red, yellow, red, green (slot 0 turned red while \"off\")?")
    d.ok("SETALL off off off off")
    return "off/on, buttons silent"


def m_current(d):
    print("    all 12 at full (RAW ff ×12) — SELFTEST lights at most 4 at once,")
    print("    so this is how max current is measured. Multimeter in series with USB 5 V (a USB tester works too).")
    d.ok("RAW " + " ".join(["ff"] * LEDS))
    try:
        v = input("    current in mA (Enter to skip): ").strip()
    finally:
        d.ok("SETALL off off off off")
    if not v:
        raise Skip("not measured")
    ma = float(v.replace(",", "."))
    check(ma < 120, f"{ma:g} mA ≥ 120 mA")
    return f"{ma:g} mA"


def m_heat(d):
    print("    all 12 at full for 60 s, then touch the module and the transistors")
    d.ok("RAW " + " ".join(["ff"] * LEDS))
    for left in range(60, 0, -10):
        print(f"      {left} s…", flush=True)
        time.sleep(10)
    d.ok("SETALL off off off off")
    ask("nothing is hot, the RP2040 module is warm at most?")


MANUAL = [
    ("raw-order", "12 LEDs one at a time in the right order", m_raw_order),
    ("fade", "pulse and crossfade without steps", m_fade),
    ("camera", "no bands on a phone camera", m_camera),
    ("stress-visual", "200 switches/s without artifacts", m_stress),
    ("welcome", "welcome survives a new state", m_welcome),
    ("idempotent", "a repeated SET doesn't restart the animation", m_idempotent),
    ("buttons", "4 buttons, no false triggers", m_buttons),
    ("replug", "USB reconnect → !READY, everything off", m_replug),
    ("power", "GP26 power switch: goes dark, buttons silent, on — current picture", m_power),
    ("current", "current, all 12 at full < 120 mA", m_current),
    ("heat", "nothing heats up", m_heat),
]


# --- run ---------------------------------------------------------------------

def find_port():
    ports = sorted(glob.glob("/dev/cu.usbmodem*"))
    if not ports:
        sys.exit("port /dev/cu.usbmodem* not found — is the board connected?")
    return ports[0]


def daemon_running():
    return subprocess.run(["launchctl", "print", f"gui/{os.getuid()}/{LABEL}"],
                          capture_output=True).returncode == 0


def stop_daemon():
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"], check=True)
    atexit.register(lambda: (print("starting the daemon again"),
                             subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", PLIST])))
    time.sleep(1.0)


def load_results():
    try:
        with open(RESULTS) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def save_results(saved, results, fw):
    today = datetime.date.today().isoformat()
    for name, status, note in results:
        saved[name] = {"status": status, "fw": fw, "date": today, "note": note}
    with open(RESULTS, "w") as f:
        json.dump(saved, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port")
    ap.add_argument("--manual", action="store_true", help="add manual checks")
    ap.add_argument("--pending", action="store_true", help="only manual checks that haven't passed yet")
    ap.add_argument("--only", help="comma-separated check names")
    ap.add_argument("--stop-daemon", action="store_true", help="stop the daemon for the duration of the test")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    saved = load_results()

    if args.list:
        for name, title, _ in AUTO + MANUAL:
            r = saved.get(name)
            last = f"{r['status']} fw={r['fw']} {r['date']}" if r else "never run"
            kind = "manual" if (name, title, _) in MANUAL else "auto"
            print(f"  {name:<14} {kind:<6} {last:<28} {title}")
        return

    tests = AUTO + (MANUAL if args.manual else [])
    if args.pending:
        tests = [t for t in MANUAL if saved.get(t[0], {}).get("status") != "ok"]
        if not tests:
            print("all manual checks passed")
            return
    if args.only:
        want = args.only.split(",")
        known = {n: (n, t, f) for n, t, f in AUTO + MANUAL}
        bad = [w for w in want if w not in known]
        if bad:
            sys.exit(f"no such checks: {', '.join(bad)} (see --list)")
        tests = [known[w] for w in want]

    if daemon_running():
        if not args.stop_daemon:
            sys.exit("the agentlightd daemon holds the port — add --stop-daemon "
                     "(or launchctl bootout gui/$UID/dev.grisha-gu.agentlight.daemon)")
        stop_daemon()

    d = Device(args.port or find_port())
    d.open()
    time.sleep(0.3)
    d.drain()
    d.ok("SETALL off off off off")
    d.ok("BRIGHT 255")
    d.ok("CONFIG busy_pulse=1 idle_pulse=0")
    d.heartbeat.set()
    fw = IDENT.match(d.cmd("HELLO")[3:]).group(1)
    print(f"port {d.port}, fw {fw}\n")

    results = []
    for name, title, fn in tests:
        print(f"• {title} [{name}]", flush=True)
        try:
            note = fn(d)
            results.append((name, "ok", note or ""))
            print(f"  ok {note or ''}")
        except Fail as e:
            results.append((name, "FAIL", str(e)))
            print(f"  FAIL: {e}")
        except Skip as e:
            results.append((name, "skip", str(e)))
            print(f"  skip: {e}")
        d.heartbeat.set()

    try:
        d.ok("SETALL off off off off")
    except Fail:
        pass
    d.heartbeat.clear()
    d.close()
    save_results(saved, results, fw)

    print("\nsummary:")
    for name, status, note in results:
        print(f"  {status:<5} {name:<14} {note}")
    failed = sum(1 for _, s, _ in results if s == "FAIL")
    print(f"\n{len(results) - failed}/{len(results)} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
