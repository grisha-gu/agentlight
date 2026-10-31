#!/usr/bin/env python3
"""Приёмка прошивки по CDC (docs/03-protocol.md §3.4, чеклист docs/04-firmware.md §4.9).

  python3 tools/proto_test.py                 # автоматические проверки, ~20 с
  python3 tools/proto_test.py --manual        # + пункты, которые проверяются глазами и руками
  python3 tools/proto_test.py --pending       # только ручные, которые ещё не прошли
  python3 tools/proto_test.py --only buttons  # отдельные проверки (через запятую)
  python3 tools/proto_test.py --list          # все проверки и их последний результат

Последний результат каждой проверки пишется в tools/proto_test-results.json.

Демон держит порт и ловит !BTN — его надо остановить. --stop-daemon делает это сам
и запускает обратно на выходе. HID здесь не проверяется: его проверяет сам демон.
"""
import argparse, atexit, datetime, glob, json, os, queue, re, subprocess, sys, threading, time

import serial

LABEL = "com.agentlight.daemon"
PLIST = os.path.expanduser(f"~/Library/LaunchAgents/{LABEL}.plist")
COLORS = ["красный", "жёлтый", "зелёный"]
SLOTS = 4
LEDS = 12
WD_TIMEOUT = 3.0
RESULTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "proto_test-results.json")

# power= — с fw 0.6.0 (выключатель на GP26)
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
    """CDC-порт: ответы на команды (OK/ERR) и асинхронные события (!…) разносятся по очередям.
    Heartbeat — отдельный поток, как у настоящего хоста; без него после первого PING всё гаснет."""

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
        # Прошивка шлёт !READY по фронту DTR, а pyserial в open() чистит входной буфер —
        # поэтому открываем с опущенным DTR и поднимаем, когда читатель уже работает.
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
        # Сначала дождаться читателя: иначе он может проснуться на новом порту
        # с тем же номером дескриптора и съесть !READY.
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
                raise Fail(f"нет ответа на {line!r}")

    def ok(self, line):
        r = self.cmd(line)
        check(r == "OK", f"{line!r} → {r!r}, ждали OK")

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


# --- автоматические проверки -------------------------------------------------

def t_hello(d):
    r = d.cmd("HELLO")
    m = IDENT.match(r[3:]) if r.startswith("OK ") else None
    check(m, f"HELLO → {r!r}")
    check(d.cmd("hello") == r, "команды должны быть регистронезависимыми")
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
    d.ok("SET 0 off")           # прерывает SELFTEST, возвращает состояния
    d.ok("SETALL off off off off")
    d.ok("  SET\t1   idle  ")   # пробелы и табы между токенами
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
    ("CONFIG attn_blink=1", "bad args"),   # мигание красного удалено совсем
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
        check(r == f"ERR {err}", f"{line!r} → {r!r}, ждали 'ERR {err}'")
    # пустые строки (\n, \r\n) молча пропускаются; строка из пробелов — ERR unknown command
    r = d.cmd("   ")
    check(r == "ERR unknown command", f"строка из пробелов → {r!r}")
    with d.lock:
        d.write("")
        d.write("\r")
        try:
            r = d.resp.get(timeout=0.3)[1]
            raise Fail(f"на пустую строку пришёл ответ {r!r}")
        except queue.Empty:
            pass
    d.ok("SET 0 off")   # после ошибок парсер жив
    return f"{len(BAD)} невалидных команд"


def t_ping(d):
    up1, _ = d.ping()
    time.sleep(0.2)
    up2, _ = d.ping()
    check(up2 > up1, f"uptime не растёт: {up1} → {up2}")
    r = d.cmd("PING 4294967295")
    check(PONG.match(r) and r.startswith("OK PONG 4294967295 "), f"max seq → {r!r}")
    d.last_ping = time.monotonic()


def t_stress(d, seconds=5.0, rate=200):
    """SET 0 busy ↔ SET 0 idle 200 раз/с без ожидания ответов; PING внутри потока."""
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
    check(not bad, f"лишние ответы: {bad[:3]}")
    check(oks == n and pongs == pings, f"ответов OK {oks}/{n}, PONG {pongs}/{pings}")
    check(not wd, "во время стресса сработал watchdog")
    d.ok("SET 0 off")
    return f"{n} команд за {sent_for:.1f} с ({n / sent_for:.0f}/с)"


def t_reconnect(d):
    """Закрыть и снова открыть порт (DTR) → !READY с той же идентификацией."""
    hello = d.cmd("HELLO")[3:]
    d.close()
    time.sleep(0.5)
    d.drain()
    d.open()
    ev = d.wait_event(r"!READY ", 2.0)
    check(ev, "после переоткрытия порта нет !READY")
    check(ev[1][len("!READY "):] == hello, f"!READY {ev[1]!r} не совпадает с HELLO {hello!r}")


def t_watchdog(d):
    d.heartbeat.set()
    d.ok("SETALL idle busy attn idle")
    d.ping()
    d.heartbeat.clear()
    time.sleep(0.3)   # поток heartbeat мог уже решить слать PING
    with d.lock:
        t0 = d.last_ping
    d.drain()
    print(f"    heartbeat остановлен, ждём {WD_TIMEOUT:.0f} с + 3 с…", flush=True)
    events = d.collect_events(WD_TIMEOUT + 3.0)
    trips = [t for t, l in events if l == "!WD trip"]
    check(len(trips) == 1, f"!WD trip пришёл {len(trips)} раз, ждали ровно 1")
    after = trips[0] - t0
    check(WD_TIMEOUT - 0.1 <= after <= WD_TIMEOUT + 0.4, f"!WD trip через {after:.2f} с, ждали ~{WD_TIMEOUT:.0f} с")
    _, wd = d.ping()
    check(wd == 1, "первый PONG после срабатывания должен нести wd=1")
    _, wd = d.ping()
    check(wd == 0, "второй PONG должен нести wd=0")
    d.heartbeat.set()
    return f"!WD trip через {after:.2f} с, один раз"


AUTO = [
    ("hello", "HELLO: версия и uid", t_hello),
    ("commands", "все команды отвечают OK", t_commands),
    ("errors", "невалидные аргументы → ERR", t_errors),
    ("ping", "PING/PONG, uptime", t_ping),
    ("stress", "200 переключений/с", t_stress),
    ("reconnect", "переоткрытие порта → !READY", t_reconnect),
    ("watchdog", "обрыв heartbeat → !WD trip", t_watchdog),
]


# --- ручные проверки ---------------------------------------------------------

def ask(question):
    while True:
        a = input(f"    {question} [y/n/s] ").strip().lower()
        if a in ("y", "д", "да", "yes"):
            return
        if a in ("n", "н", "нет", "no"):
            note = input("    что не так? ").strip()
            raise Fail(note or "не прошло на глаз")
        if a in ("s", "skip"):
            raise Skip("пропущено")


def led_name(i):
    return f"слот {i // 3} {COLORS[i % 3]}"


def raw_one(i, level):
    levels = ["0"] * LEDS
    levels[i] = f"{level:x}"
    return "RAW " + " ".join(levels)


def m_raw_order(d):
    print("    зажигаю по одному, по 1 с; слот 0 — левый, сверху вниз красный/жёлтый/зелёный")
    for i in range(LEDS):
        print(f"      GP{i:<2} {led_name(i)}", flush=True)
        d.ok(raw_one(i, 0xFF))
        time.sleep(1.0)
    d.ok("SETALL off off off off")
    ask("каждый раз горел ровно тот светодиод, что напечатан?")


def m_fade(d):
    """Плавность проверяем на анимациях: они считаются во float до самого PWM.
    RAW для этого не годится — его вход 8 бит до гаммы, и внизу соседние уровни
    отличаются по яркости в разы (5 → 4 — это −40 %), ступени там неизбежны."""
    d.ok("CONFIG busy_pulse=1")
    fails = []
    for bright in (255, 30):
        print(f"    пульс busy на всех слотах, BRIGHT {bright}, 3 периода (6.6 с)", flush=True)
        d.ok(f"BRIGHT {bright}")
        d.ok("SETALL busy busy busy busy")
        time.sleep(6.6)
        d.ok("SETALL off off off off")
        time.sleep(0.5)
        try:
            ask(f"пульс на BRIGHT {bright} плавный, без рывков и ступенек?")
        except Fail as e:
            fails.append(f"пульс {bright}: {e}")
    print("    BRIGHT 30: зелёный загорается и гаснет (crossfade 220 мс), 3 раза", flush=True)
    for _ in range(3):
        d.ok("SETALL idle idle idle idle")
        time.sleep(1.0)
        d.ok("SETALL off off off off")
        time.sleep(1.0)
    d.ok("BRIGHT 255")
    try:
        ask("загорается и гаснет плавно, без скачка в самом конце?")
    except Fail as e:
        fails.append(f"crossfade: {e}")
    if fails:
        raise Fail("; ".join(fails))


def m_camera(d):
    print("    включи камеру телефона на светофоры: 8 с busy pulse + 100 % RAW")
    d.ok("CONFIG busy_pulse=1")
    d.ok("SETALL busy busy busy busy")
    time.sleep(4)
    d.ok("RAW " + " ".join(["ff"] * LEDS))
    time.sleep(4)
    d.ok("SETALL off off off off")
    ask("на экране телефона нет полос и мерцания?")


def m_stress(d):
    print("    смотри на слот 0: через 2 с — 5 с SET busy ↔ idle 200 раз/с, потом OFF")
    time.sleep(2)
    print("      старт", flush=True)
    note = t_stress(d)
    print(f"      конец — {note}")
    ask("слот 0 не дёргался, не моргал, не было вспышек (если были — когда и на каком слоте)?")


def m_welcome(d):
    print("    1) WELCOME ALL, через 0.5 с SETALL busy idle attn idle")
    d.ok("SETALL off off off off")
    time.sleep(0.5)
    d.ok("WELCOME ALL")
    time.sleep(0.5)
    d.ok("SETALL busy idle attn idle")
    time.sleep(3)
    print("    2) WELCOME 0, через 0.3 с SET 0 attn")
    d.ok("WELCOME 0")
    time.sleep(0.3)
    d.ok("SET 0 attn")
    time.sleep(3)
    ask("анимация не ломалась, в конце: 1) жёлтый зелёный красный зелёный, 2) слот 0 красный?")
    d.ok("SETALL off off off off")


def m_idempotent(d):
    """Если бы повторный SET перезапускал crossfade, зелёный застрял бы тусклым у нуля."""
    print("    слот 0: SET idle каждые 50 мс в течение 3 с")
    d.ok("SET 0 off")
    time.sleep(0.5)
    for _ in range(60):
        d.ok("SET 0 idle")
        time.sleep(0.05)
    d.ok("SET 0 off")
    ask("зелёный за доли секунды плавно разгорелся до полной яркости и дальше горел ровно?")


def m_buttons(d):
    for slot in range(SLOTS):
        d.drain()
        print(f"    нажми кнопку слота {slot} (слева {slot + 1}-ю)", flush=True)
        ev = d.wait_event(r"!BTN ", 20.0)
        if not ev:
            raise Fail(f"кнопка {slot}: событий нет за 20 с")
        check(re.match(rf"!BTN {slot} press t=\d+$", ev[1]), f"ждали !BTN {slot} press, пришло {ev[1]!r}")
        extra = [l for _, l in d.collect_events(1.0) if l.startswith("!BTN")]
        check(not extra, f"кнопка {slot}: дребезг, лишние {extra}")
        print(f"      {ev[1]}")
    d.drain()
    input("    теперь 10 с стучи по столу и по корпусу, кнопки не трогай. Enter — начать ")
    extra = [l for _, l in d.collect_events(10.0) if l.startswith("!BTN")]
    check(not extra, f"ложные срабатывания: {extra}")
    return "4 кнопки, ложных нет"


def m_replug(d):
    d.heartbeat.clear()
    d.ok("SETALL idle busy attn idle")
    input("    сейчас горят светофоры. Выдерни USB, вставь обратно и нажми Enter ")
    d.close()
    d.drain()
    for _ in range(40):
        try:
            d.open()
            break
        except serial.SerialException:
            time.sleep(0.25)
    else:
        raise Fail("порт не появился после переподключения")
    ev = d.wait_event(r"!READY ", 3.0)
    check(ev, "нет !READY после переподключения")
    print(f"      {ev[1]}")
    ask("все светофоры погашены (команд ещё не было)?")
    d.heartbeat.set()


def m_power(d):
    def hello_power():
        m = IDENT.match(d.cmd("HELLO")[3:])
        return m and m.group(3)

    check(hello_power() == "on", "до проверки HELLO должен говорить power=on — GP26 ни к чему не подключён?")
    d.ok("SETALL idle busy attn idle")
    d.drain()
    print("    горят 4 огня, по одному на светофор: зелёный, жёлтый, красный, зелёный.", flush=True)
    print("    Замкни GP26 на GND проводом", flush=True)
    ev = d.wait_event(r"!POWER ", 30.0)
    check(ev and ev[1] == "!POWER off", f"ждали !POWER off, пришло {ev and ev[1]!r}")
    extra = [l for _, l in d.collect_events(1.0) if l.startswith("!POWER")]
    check(not extra, f"дребезг выключателя: лишние {extra}")
    check(hello_power() == "off", "HELLO в «выкл» должен говорить power=off")
    ask("все 4 огня плавно погасли, встроенный RGB на модуле тоже не горит?")

    d.drain()
    input("    нажми пару кнопок слотов (событий быть не должно), потом Enter ")
    btn = [l for _, l in d.collect_events(0.2) if l.startswith("!BTN")]
    check(not btn, f"в «выкл» кнопки молчат, а пришло {btn}")
    d.ok("SET 0 attn")   # состояние, присланное в «выкл», должно показаться при «вкл»

    print("    убери провод с GP26", flush=True)
    ev = d.wait_event(r"!POWER ", 30.0)
    check(ev and ev[1] == "!POWER on", f"ждали !POWER on, пришло {ev and ev[1]!r}")
    check(hello_power() == "on", "HELLO после «вкл» должен говорить power=on")
    ask("огни плавно разгорелись: красный, жёлтый, красный, зелёный (слот 0 стал красным в «выкл»)?")
    d.ok("SETALL off off off off")
    return "выкл/вкл, кнопки молчат"


def m_current(d):
    print("    все 12 на полную (RAW ff ×12) — SELFTEST одновременно горит максимум 4,")
    print("    поэтому максимальный ток меряем так. Мультиметр в разрыв 5 В USB (USB-тестер тоже годится).")
    d.ok("RAW " + " ".join(["ff"] * LEDS))
    try:
        v = input("    ток в мА (Enter — пропустить): ").strip()
    finally:
        d.ok("SETALL off off off off")
    if not v:
        raise Skip("не мерили")
    ma = float(v.replace(",", "."))
    check(ma < 120, f"{ma:g} мА ≥ 120 мА")
    return f"{ma:g} мА"


def m_heat(d):
    print("    все 12 на полную 60 с, потом потрогай модуль и транзисторы")
    d.ok("RAW " + " ".join(["ff"] * LEDS))
    for left in range(60, 0, -10):
        print(f"      {left} с…", flush=True)
        time.sleep(10)
    d.ok("SETALL off off off off")
    ask("ничего не горячее, модуль RP2040 максимум тёплый?")


MANUAL = [
    ("raw-order", "12 LED по одному в нужном порядке", m_raw_order),
    ("fade", "пульс и crossfade без ступеней", m_fade),
    ("camera", "нет полос на камеру телефона", m_camera),
    ("stress-visual", "200 переключений/с без артефактов", m_stress),
    ("welcome", "welcome переживает новое состояние", m_welcome),
    ("idempotent", "повторный SET не перезапускает анимацию", m_idempotent),
    ("buttons", "4 кнопки, без ложных срабатываний", m_buttons),
    ("replug", "переподключение USB → !READY, всё погашено", m_replug),
    ("power", "выключатель GP26: гаснет, кнопки молчат, вкл — актуальная картина", m_power),
    ("current", "ток все 12 на полную < 120 мА", m_current),
    ("heat", "ничего не греется", m_heat),
]


# --- запуск ------------------------------------------------------------------

def find_port():
    ports = sorted(glob.glob("/dev/cu.usbmodem*"))
    if not ports:
        sys.exit("порт /dev/cu.usbmodem* не найден — плата подключена?")
    return ports[0]


def daemon_running():
    return subprocess.run(["launchctl", "print", f"gui/{os.getuid()}/{LABEL}"],
                          capture_output=True).returncode == 0


def stop_daemon():
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"], check=True)
    atexit.register(lambda: (print("демон запускается обратно"),
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
    ap.add_argument("--manual", action="store_true", help="добавить ручные проверки")
    ap.add_argument("--pending", action="store_true", help="только ручные проверки, которые ещё не прошли")
    ap.add_argument("--only", help="имена проверок через запятую")
    ap.add_argument("--stop-daemon", action="store_true", help="остановить демон на время теста")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    saved = load_results()

    if args.list:
        for name, title, _ in AUTO + MANUAL:
            r = saved.get(name)
            last = f"{r['status']} fw={r['fw']} {r['date']}" if r else "не запускалась"
            kind = "ручная" if (name, title, _) in MANUAL else "авто"
            print(f"  {name:<14} {kind:<6} {last:<28} {title}")
        return

    tests = AUTO + (MANUAL if args.manual else [])
    if args.pending:
        tests = [t for t in MANUAL if saved.get(t[0], {}).get("status") != "ok"]
        if not tests:
            print("все ручные проверки пройдены")
            return
    if args.only:
        want = args.only.split(",")
        known = {n: (n, t, f) for n, t, f in AUTO + MANUAL}
        bad = [w for w in want if w not in known]
        if bad:
            sys.exit(f"нет таких проверок: {', '.join(bad)} (см. --list)")
        tests = [known[w] for w in want]

    if daemon_running():
        if not args.stop_daemon:
            sys.exit("демон agentlightd держит порт — добавь --stop-daemon "
                     "(или launchctl bootout gui/$UID/com.agentlight.daemon)")
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
    print(f"порт {d.port}, fw {fw}\n")

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

    print("\nитог:")
    for name, status, note in results:
        print(f"  {status:<5} {name:<14} {note}")
    failed = sum(1 for _, s, _ in results if s == "FAIL")
    print(f"\n{len(results) - failed}/{len(results)} без ошибок")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
