#!/usr/bin/env python3
"""Run gpconnect in the background and keep its state where the bar can read it.

    gpvpn.py connect --portal vpn.example.org [--args "--webview"] [--command gpconnect]
    gpvpn.py disconnect
    gpvpn.py status            # one JSON line, for the bar
    gpvpn.py password          # hand the root password (one stdin line) to sudo
    gpvpn.py portal vpn.example.org   # remember the portal chosen in the panel

The connection runs outside the bar process, so a shell restart or a plugin
reload does not drop the VPN. Root comes from sudo, which has no terminal and
so asks through SUDO_ASKPASS. Our askpass waits on a FIFO (named pipe) that
the bar panel writes the password into; the password never appears in argv.
sudo keeps running as the user, so disconnecting is an ordinary signal and
needs no second password.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
RUNTIME = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "omarchy-gpconnect"
STATE_FILE = RUNTIME / "state.json"
LOG_DIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "omarchy" / "gpconnect"
LOG_FILE = LOG_DIR / "log"
SETTINGS_FILE = LOG_DIR / "settings.json"
#: How many previously used portals the panel offers.
RECENT = 5
ASKPASS_FIFO = RUNTIME / "askpass.fifo"
ASKPASS_REQUEST = RUNTIME / "askpass.json"
ASKPASS_COUNT = RUNTIME / "askpass.count"
#: How long sudo's password request waits for the panel before giving up.
ASKPASS_TIMEOUT = 300

#: gpconnect's own status lines (see gpconnect/vpn.py) and what they mean.
#: Matched in order; the first hit wins.
EVENTS = [
    ("starting openconnect against", "connecting"),
    ("connected to the gateway; waiting", "waiting"),
    ("tunnel ready over ESP", "ready"),
    ("tunnel ready over HTTPS", "ready"),
    ("link lost", "reconnecting"),
]
ADDRESS = re.compile(r"Connected as ([0-9a-fA-F.:]+)")
#: openconnect prints the gateway's session lifetime in local time, e.g.
#: "Session authentication will expire at Fri, 23 Oct 2026 02:38:56 CEST".
EXPIRES = re.compile(r"Session authentication will expire at \w+, (\d+ \w+ \d+ [\d:]+)")
IDLE = re.compile(r"Idle timeout is (\d+) minutes")
#: fprintd's D-Bus names. sudo's pam_fprintd prompt never reaches us in time
#: (sudo buffers it), so we ask fprintd whether a device waits for a finger.
FPRINT = ["net.reactivated.Fprint", "/net/reactivated/Fprint/Device/0",
          "net.reactivated.Fprint.Device"]


def read_state() -> dict:
    try:
        return json.loads(STATE_FILE.read_text())
    except (OSError, ValueError):
        return {}


def write_state(state: dict) -> None:
    RUNTIME.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state) + "\n")
    tmp.replace(STATE_FILE)


def alive(pid: int | None) -> bool:
    if not pid:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def current_state() -> dict:
    """The saved state, corrected to "off" when the runner is gone.

    While sudo waits for a password the state reads "password", with
    `attempt` counting up after a wrong one. While sudo waits for a finger
    instead, `fingerprint` holds the reader's name.
    """
    state = read_state()
    if state.get("state") not in (None, "off", "failed") and not alive(state.get("pid")):
        state = {"state": "off", "since": time.time()}
        write_state(state)
    try:
        request = json.loads(ASKPASS_REQUEST.read_text())
    except (OSError, ValueError):
        request = None
    if request and alive(request.get("pid")) and alive(state.get("pid")):
        state = dict(state, state="password", attempt=request.get("attempt", 1))
    elif state.get("state") == "connecting" and alive(state.get("pid")):
        reader = finger_needed(state["pid"])
        if reader:
            state = dict(state, fingerprint=reader)
    if state.get("state") not in (None, "off", "failed"):
        state = dict(state, **session_limits())
    return state or {"state": "off"}


def finger_needed(pid: int) -> str:
    """The reader's name while our sudo waits for a finger, else ""."""
    names = [name for _pid, name in descendants(pid)]
    if "sudo" not in names or "openconnect" in names or not shutil.which("busctl"):
        return ""

    def get(prop: str) -> str:
        try:
            out = subprocess.run(["busctl", "--system", "get-property", *FPRINT, prop],
                                 capture_output=True, text=True, timeout=2).stdout
        except (OSError, subprocess.TimeoutExpired):
            return ""
        return out.strip()

    if get("finger-needed") != "b true":
        return ""
    return get("name").removeprefix("s ").strip('"') or "fingerprint reader"


def load_settings() -> dict:
    try:
        settings = json.loads(SETTINGS_FILE.read_text())
    except (OSError, ValueError):
        settings = {}
    return {"portal": settings.get("portal", ""), "recent": settings.get("recent", [])}


def clean_portal(text: str) -> str:
    """Accept a pasted URL as well as a bare host: keep only the host[:port]."""
    text = text.strip()
    text = re.sub(r"^[a-z]+://", "", text, flags=re.I)
    return text.split("/", 1)[0].strip()


def session_limits() -> dict:
    """Session expiry (epoch seconds) and idle timeout (minutes) from the log.

    The log is rewritten for every connection, so whatever it holds belongs
    to the current session.
    """
    try:
        text = LOG_FILE.read_text(errors="replace")
    except OSError:
        return {}
    limits = {}
    match = EXPIRES.search(text)
    if match:
        try:
            limits["expires"] = time.mktime(time.strptime(match.group(1), "%d %b %Y %H:%M:%S"))
        except ValueError:
            pass
    match = IDLE.search(text)
    if match:
        limits["idle_timeout"] = int(match.group(1))
    return limits


def children(pid: int) -> list[tuple[int, str]]:
    """Direct children of `pid` as (pid, command name)."""
    found = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            stat = (entry / "stat").read_text()
        except OSError:
            continue
        # comm is in parentheses and may contain spaces; ppid follows it.
        comm = stat[stat.index("(") + 1:stat.rindex(")")]
        ppid = int(stat[stat.rindex(")") + 2:].split()[1])
        if ppid == pid:
            found.append((int(entry.name), comm))
    return found


def descendants(pid: int) -> list[tuple[int, str]]:
    out, todo = [], [pid]
    while todo:
        for child in children(todo.pop()):
            out.append(child)
            todo.append(child[0])
    return out


def find_gpconnect(command: str) -> str:
    path = os.path.expanduser(command)
    if os.sep in path:
        return path
    extra = os.pathsep.join([os.environ.get("PATH", ""), str(Path.home() / ".local/bin")])
    return shutil.which(path, path=extra) or path


# ---------------------------------------------------------------- the runner

class Runner:
    def __init__(self, portal: str, argv: list[str]):
        self.portal = portal
        self.argv = argv
        self.proc: subprocess.Popen | None = None
        self.stopping = False
        self.state = {"state": "login", "portal": portal, "pid": os.getpid(),
                      "since": time.time(), "started": time.time()}

    def update(self, **changes) -> None:
        self.state.update(changes)
        write_state(self.state)

    def stop(self, *_signal) -> None:
        """Bring the tunnel down: openconnect logs off on SIGTERM."""
        if self.stopping or not self.proc:
            return
        self.stopping = True
        self.update(state="disconnecting", since=time.time())
        try:   # a pending password request would otherwise wait out its timeout
            os.kill(json.loads(ASKPASS_REQUEST.read_text())["pid"], signal.SIGTERM)
        except (OSError, ValueError, KeyError):
            pass
        tree = descendants(self.proc.pid)
        # sudo runs as the user and relays the signal to openconnect.
        targets = [pid for pid, comm in tree if comm == "sudo"]
        if not targets:
            targets = [pid for pid, comm in tree if comm == "openconnect"]
        if not targets:
            targets = [self.proc.pid]   # still logging in: just end gpconnect
        for pid in targets:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            except PermissionError:
                # openconnect started through pkexec runs fully as root.
                subprocess.run(["pkexec", "kill", "-TERM", str(pid)])

    def run(self) -> int:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ, PYTHONUNBUFFERED="1", SUDO_ASKPASS=str(HERE / "askpass"))
        argv = [self.argv[0], "--elevate", "sudo"] + self.argv[1:]
        ASKPASS_COUNT.unlink(missing_ok=True)

        signal.signal(signal.SIGTERM, self.stop)
        signal.signal(signal.SIGINT, self.stop)
        self.update()
        error = ""
        with open(LOG_FILE, "w") as log:
            log.write(f"$ {shlex.join(argv)}\n")
            log.flush()
            try:
                self.proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL,
                                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                             text=True, bufsize=1, env=env)
            except OSError as exc:
                write_state({"state": "failed", "since": time.time(),
                             "detail": f"cannot run {argv[0]}: {exc.strerror}"})
                return 127
            for line in self.proc.stdout:
                log.write(line)
                log.flush()
                error = self.observe(line) or error
            code = self.proc.wait()

        if self.stopping or code == 0:
            write_state({"state": "off", "since": time.time()})
        else:
            self.update(state="failed", since=time.time(), pid=None,
                        detail=error or f"gpconnect exited with code {code}")
        return code

    def observe(self, line: str) -> str | None:
        """Update the state from one output line; return an error message if it is one."""
        if self.stopping:
            return None
        match = ADDRESS.search(line)
        if match:
            self.update(address=match.group(1))
        if "[gpconnect]" not in line:
            return None
        message = line.split("[gpconnect]", 1)[1].strip()
        if message.startswith("error:"):
            return message[len("error:"):].strip()
        if "HIP report" in message:
            self.update(hip=True)
        for marker, state in EVENTS:
            if marker in message:
                changes = {"state": state, "since": time.time(), "detail": message}
                if state == "ready":
                    changes["transport"] = "ESP" if "over ESP" in message else "HTTPS"
                self.update(**changes)
                break
        return None


# ------------------------------------------------------------------ commands

def cmd_connect(args) -> int:
    state = current_state()
    if state.get("state") not in ("off", "failed"):
        print("already running", file=sys.stderr)
        return 0
    if not args.portal:
        write_state({"state": "failed", "since": time.time(),
                     "detail": "no portal set: enter one in the panel"})
        return 2
    argv = [find_gpconnect(args.command), "connect", args.portal] + shlex.split(args.args)
    # Detach into a new session: no controlling terminal, so sudo asks
    # through SUDO_ASKPASS, and the bar can come and go underneath.
    subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "_run", args.portal, "--"]
                     + argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    return 0


def cmd_run(args) -> int:
    return Runner(args.portal, args.argv).run()


def cmd_disconnect(_args) -> int:
    pid = current_state().get("pid")
    if alive(pid):
        os.kill(pid, signal.SIGTERM)
    return 0


def cmd_askpass(_args) -> int:
    """sudo's SUDO_ASKPASS: wait for the panel to send the password, print it."""
    try:
        attempt = int(ASKPASS_COUNT.read_text()) + 1
    except (OSError, ValueError):
        attempt = 1
    RUNTIME.mkdir(parents=True, exist_ok=True)
    ASKPASS_COUNT.write_text(str(attempt))
    ASKPASS_FIFO.unlink(missing_ok=True)
    os.mkfifo(ASKPASS_FIFO, 0o600)
    ASKPASS_REQUEST.write_text(json.dumps({"pid": os.getpid(), "attempt": attempt}))
    signal.signal(signal.SIGALRM, lambda *_: sys.exit(1))
    signal.alarm(ASKPASS_TIMEOUT)
    try:
        with open(ASKPASS_FIFO) as fifo:   # blocks until the panel writes
            password = fifo.readline().rstrip("\n")
    finally:
        ASKPASS_REQUEST.unlink(missing_ok=True)
        ASKPASS_FIFO.unlink(missing_ok=True)
    print(password)
    return 0


def cmd_password(_args) -> int:
    """Pass one line of stdin to a waiting askpass."""
    password = sys.stdin.readline()
    try:
        fd = os.open(ASKPASS_FIFO, os.O_WRONLY | os.O_NONBLOCK)
    except OSError:
        print("nothing is waiting for a password", file=sys.stderr)
        return 1
    with os.fdopen(fd, "w") as fifo:
        fifo.write(password if password.endswith("\n") else password + "\n")
    return 0


def cmd_status(_args) -> int:
    print(json.dumps(dict(current_state(), settings=load_settings())))
    return 0


def cmd_portal(args) -> int:
    portal = clean_portal(args.portal)
    if not portal or not re.fullmatch(r"[A-Za-z0-9.-]+(:\d+)?", portal):
        print(f"not a portal address: {args.portal!r}", file=sys.stderr)
        return 2
    settings = load_settings()
    recent = [portal] + [p for p in settings["recent"] if p != portal]
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    SETTINGS_FILE.write_text(json.dumps({"portal": portal, "recent": recent[:RECENT]}) + "\n")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="gpvpn")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("connect")
    p.add_argument("--portal", default="")
    p.add_argument("--args", default="--webview")
    p.add_argument("--command", default="gpconnect")
    p.set_defaults(func=cmd_connect)
    p = sub.add_parser("_run")
    p.add_argument("portal")
    p.add_argument("argv", nargs=argparse.REMAINDER)
    p.set_defaults(func=cmd_run)
    sub.add_parser("disconnect").set_defaults(func=cmd_disconnect)
    sub.add_parser("status").set_defaults(func=cmd_status)
    sub.add_parser("password").set_defaults(func=cmd_password)
    p = sub.add_parser("portal")
    p.add_argument("portal")
    p.set_defaults(func=cmd_portal)
    sub.add_parser("_askpass").add_argument("prompt", nargs="*")
    sub.choices["_askpass"].set_defaults(func=cmd_askpass)
    args = parser.parse_args()
    if args.cmd == "_run" and args.argv[:1] == ["--"]:
        args.argv = args.argv[1:]
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
