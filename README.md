# GlobalProtect VPN for the Omarchy bar

An [Omarchy](https://omarchy.org/) bar plugin for
[gpconnect](https://github.com/ladisk/gpconnect), the free GlobalProtect VPN
client for Linux. Connect, disconnect and enter the root password from a bar
panel, and see when the tunnel actually carries traffic.

## What it shows

The bar icon is dim while the VPN is off. While the tunnel comes up, the icon
shows a running timer. openconnect reports "connected" before any traffic
flows: it first tries the fast UDP tunnel (ESP) and falls back to HTTPS if UDP
is blocked, and that fallback can take minutes. The timer goes away when
traffic flows. The icon turns red when the connection failed, or when the root
password or a fingerprint is needed.

Clicking the icon opens a panel with:

- the status, with the timer while connecting;
- the portal, editable while the VPN is off;
- the VPN address, the transport (ESP, or HTTPS when UDP is blocked), how long
  the tunnel took to come up, and since when it is ready;
- until when the session is valid, and the gateway's idle timeout;
- warnings: a session that ends within 30 minutes, a gateway that asks for a
  HIP report, the reason for a failed connection;
- a root password field when sudo needs one, like the Wi-Fi panel's
  passphrase field;
- **Connect** / **Disconnect** and **Log** (the full output in a floating
  terminal).

Keys in the panel: `c` connects, `d` disconnects (or cancels a connection that
is coming up), Enter does whichever applies, `e` edits the portal, `l` opens
the log, Esc closes. A hint line at the bottom of the panel lists the keys
that apply. Esc in the root password field cancels the connection.

## Setup

Needs [gpconnect](https://github.com/ladisk/gpconnect) and Python 3.

```bash
omarchy plugin add https://github.com/ladisk/omarchy-gpconnect.git --enable
```

Or clone it into `~/.config/omarchy/plugins/io.github.ladisk.gpconnect` and add
it to the bar in `~/.config/omarchy/shell.json`, e.g. under `bar.layout.right`:

```json
{ "id": "io.github.ladisk.gpconnect", "arguments": "--webview --remember" }
```

Then open the panel, click **Edit** next to the portal, type the address (a
pasted URL works too) and press Enter.

### Settings

All are optional, on the widget's entry in `shell.json`:

| key | default | meaning |
|---|---|---|
| `arguments` | `--webview` | extra arguments for `gpconnect connect`; openconnect options go after `--`, e.g. `--webview -- --no-dtls` |
| `portal` | none | default portal until one is picked in the panel |
| `command` | `gpconnect` | the gpconnect executable, if it is not on `PATH` |

The portal picked in the panel, and the last five portals used, are kept in
`~/.local/state/omarchy/gpconnect/settings.json`. Previously used portals show
as buttons under the edit field, so switching between them is one click.

## How it works

`gpvpn.py` starts gpconnect in its own session, outside the shell, so a shell
restart or a plugin reload does not drop the VPN. It reads gpconnect's status
lines and keeps the state in `$XDG_RUNTIME_DIR/omarchy-gpconnect/state.json`.
The widget polls `gpvpn.py status`: every second while something changes or
the panel is open, every five seconds otherwise. The full output goes to
`~/.local/state/omarchy/gpconnect/log`, which is rewritten on every connect.
The session expiry and idle timeout are read from it.

Root comes from sudo. With no terminal, sudo runs `askpass`, which waits on a
named pipe in `$XDG_RUNTIME_DIR`. The panel's password field writes into it
through `gpvpn.py password` on stdin, so the password never appears on a
command line or in a process list. If sudo uses pam_fprintd, it first waits
for a finger. sudo holds back fprintd's prompt, so the widget reads fprintd's
`finger-needed` flag over D-Bus instead: the panel shows the prompt and the
icon turns red until you touch the reader or it times out, then the password
field follows. sudo keeps running as you, so disconnecting is an ordinary
signal and needs no second password.

The same commands work from a terminal:

```bash
./gpvpn.py portal vpn.example.org
./gpvpn.py connect --portal vpn.example.org --args "--webview"
./gpvpn.py status
./gpvpn.py disconnect
```

## Limitations

- Tested on one portal (PAN-OS with Microsoft Entra ID).
- The state comes from gpconnect's and openconnect's messages; a different
  openconnect version may word them differently.
- The session lifetime is what the gateway reports. The gateway can still end
  the session earlier, for example after the idle timeout.

## License

MIT — see [LICENSE](LICENSE).
