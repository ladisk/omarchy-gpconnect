import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// VPN pill plus a panel, backed by gpvpn.py, which runs gpconnect outside the
// shell and keeps its state in $XDG_RUNTIME_DIR/omarchy-gpconnect/state.json.
// The pill is dim when off, shows a running timer while the tunnel is still
// coming up (the minutes when "connected" carries no traffic yet), and is
// plain once traffic flows. Clicking it opens the panel: details, connect /
// disconnect, and the root password field when sudo asks for one.
BarWidget {
  id: root
  moduleName: "io.github.ladisk.gpconnect"

  readonly property string helper: String(Qt.resolvedUrl("gpvpn.py")).replace(/^file:\/\//, "")
  readonly property string logFile: Quickshell.env("HOME") + "/.local/state/omarchy/gpconnect/log"
  // The portal picked in the panel wins over the shell.json default.
  readonly property string defaultPortal: setting("portal", "")
  readonly property var saved: vpn.settings || ({})
  readonly property string portal: saved.portal || defaultPortal
  readonly property var recentPortals: saved.recent || []
  readonly property string extraArgs: setting("arguments", "--webview")
  readonly property string gpCommand: setting("command", "gpconnect")

  property var vpn: ({ state: "off" })
  property real now: Date.now()
  property bool popupOpen: false
  property string passwordText: ""
  property string actionError: ""
  // Only the bar instance that asked for the connection pops its panel open
  // for the password; there is one instance per monitor.
  property bool requestedHere: false
  property bool editingPortal: false
  property string portalDraft: ""

  readonly property string phase: vpn.state || "off"
  // fprintd's prompt while sudo waits for a finger, before it asks for the password.
  readonly property string fingerprint: vpn.fingerprint || ""
  readonly property bool idle: phase === "off" || phase === "failed"
  readonly property bool pending: ["login", "password", "connecting", "waiting", "reconnecting",
    "disconnecting"].indexOf(phase) >= 0
  // Time since the click for the first connect, since the drop for a reconnect.
  readonly property real pendingSince: (phase === "reconnecting" || phase === "disconnecting"
    ? vpn.since : vpn.started || vpn.since) * 1000

  readonly property var phaseText: ({
    off: "Off",
    failed: "Failed",
    login: "Logging in",
    password: "Waiting for the root password",
    connecting: "Starting the tunnel",
    waiting: "Connected, waiting for the data tunnel (ESP)",
    ready: "Ready",
    reconnecting: "Link lost, reconnecting",
    disconnecting: "Disconnecting"
  })

  readonly property string statusLine: {
    var text = fingerprint !== "" && phase !== "password" ? "Waiting for the fingerprint"
      : phaseText[phase] || phase
    if (pending) text += " · " + clock(now - pendingSince)
    if (phase === "ready" && vpn.transport) text += " over " + vpn.transport
    if (phase === "ready" && vpn.expires) text += " · until " + timeOfDay(vpn.expires)
    return text
  }

  // open/close/opened let `omarchy-shell shell toggle <id>` drive the panel.
  readonly property bool opened: popupOpen
  function open() { popupOpen = true }
  function close() { popupOpen = false }

  function clock(ms) {
    var s = Math.max(0, Math.round(ms / 1000))
    var m = Math.floor(s / 60)
    s = s % 60
    return m + ":" + (s < 10 ? "0" : "") + s
  }

  function timeOfDay(seconds) {
    return Qt.formatDateTime(new Date(seconds * 1000), "HH:mm")
  }

  // "3 h 5 min", "45 min"
  function duration(minutes) {
    var m = Math.max(0, Math.round(minutes))
    var h = Math.floor(m / 60)
    m = m % 60
    return h > 0 ? h + " h" + (m > 0 ? " " + m + " min" : "") : m + " min"
  }

  // "02:38 tomorrow", then "in 11 h 58 min" on a second line; the day only
  // when it is not today.
  function untilText(seconds) {
    var when = new Date(seconds * 1000)
    var today = new Date(now)
    var tomorrow = new Date(now + 86400000)
    var day = when.toDateString() === today.toDateString() ? ""
      : when.toDateString() === tomorrow.toDateString() ? " tomorrow"
      : " " + Qt.formatDateTime(when, "ddd d MMM")
    return timeOfDay(seconds) + day + "\nin " + duration((seconds * 1000 - now) / 60000)
  }

  readonly property bool expiringSoon: !idle && vpn.expires > 0 && vpn.expires * 1000 - now < 30 * 60000

  function poll() {
    if (!statusProc.running) statusProc.running = true
  }

  function parse(raw) {
    try {
      root.vpn = JSON.parse(String(raw).trim())
    } catch (e) {
      // A torn read; the next poll replaces it.
    }
  }

  function run(argv) {
    if (actionProc.running) return
    actionError = ""
    actionProc.command = ["python3", helper].concat(argv)
    actionProc.running = true
    soon.restart()
  }

  function connect() {
    requestedHere = true
    run(["connect", "--portal=" + portal, "--args=" + extraArgs, "--command=" + gpCommand])
  }

  function editPortal() {
    portalDraft = portal
    editingPortal = true
  }

  function savePortal(text) {
    editingPortal = false
    if (String(text).trim() !== "" && String(text).trim() !== portal) run(["portal", String(text).trim()])
  }

  function disconnect() {
    run(["disconnect"])
  }

  function toggle() {
    if (idle) connect()
    else disconnect()
  }

  function submitPassword() {
    if (passwordText.length === 0 || passwordProc.running) return
    passwordProc.secret = passwordText
    passwordText = ""
    passwordProc.running = true
    soon.restart()
  }

  onPhaseChanged: {
    if (phase === "password" && requestedHere) popupOpen = true
    if (phase !== "password") passwordText = ""
    if (idle || phase === "ready") requestedHere = false
  }
  onPopupOpenChanged: {
    if (popupOpen) poll()
    else editingPortal = false
  }

  Process {
    id: statusProc
    command: ["python3", root.helper, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parse(text)
    }
  }

  Process {
    id: actionProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") root.actionError = text.trim().split("\n").pop()
    }
  }

  // The password goes over stdin, never argv.
  Process {
    id: passwordProc
    property string secret: ""
    command: ["python3", root.helper, "password"]
    stdinEnabled: true
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
  }

  // Poll faster while something is changing or the panel is open.
  Timer {
    interval: (root.idle || root.phase === "ready") && !root.popupOpen ? 5000 : 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  Timer {
    id: soon
    interval: 400
    onTriggered: root.poll()
  }

  Timer {
    interval: 1000
    running: root.pending || root.popupOpen
    repeat: true
    onTriggered: root.now = Date.now()
  }

  visible: true
  implicitWidth: pill.implicitWidth
  implicitHeight: barSize

  WidgetButton {
    id: pill
    bar: root.bar
    text: String.fromCodePoint(0xF0582) + (root.pending ? " " + root.clock(root.now - root.pendingSince) : "")
    tooltipText: "VPN: " + root.statusLine
    fontSize: Style.font.body
    dimmed: root.phase === "off"
    active: root.phase === "failed" || root.phase === "password" || root.fingerprint !== ""

    onPressed: function(button) { root.popupOpen = !root.popupOpen }
  }

  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(360))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The password field owns the keyboard while it is shown.
      blocked: root.phase === "password" || root.editingPortal
      onCloseRequested: root.close()
      onActivateRequested: root.toggle()
      onTextKey: function(t) {
        if (t === "l" || t === "L") root.openLog()
        else if ((t === "e" || t === "E") && root.idle) root.editPortal()
        else if ((t === "c" || t === "C") && root.idle) root.connect()
        else if ((t === "d" || t === "D") && !root.idle) root.disconnect()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        // ---------- Header ----------
        Row {
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            text: String.fromCodePoint(0xF0582)
            color: root.bar.foreground
            opacity: root.phase === "off" ? 0.45 : 1
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.iconLarge
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            width: parent.width - Style.space(40)
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: "GlobalProtect VPN"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              text: root.statusLine
              color: root.phase === "failed" ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.3)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- Details ----------
        Column {
          width: parent.width
          spacing: Style.space(4)

          // The label column fits the longest label.
          TextMetrics {
            id: labelMetrics
            text: "Session valid until"
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // ---------- Portal: shown, or edited while the VPN is off ----------
          Row {
            width: parent.width
            visible: !root.editingPortal

            Text {
              textFormat: Text.PlainText
              text: "Portal"
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              width: labelMetrics.width + Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              textFormat: Text.PlainText
              text: root.portal || "not set"
              color: root.portal ? root.bar.foreground : root.bar.urgent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              width: parent.width - labelMetrics.width - Style.space(16) - editButton.width
              elide: Text.ElideRight
              anchors.verticalCenter: parent.verticalCenter
            }
            Button {
              id: editButton
              visible: root.idle
              text: "Edit"
              tooltipText: "Change the portal (e)"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.space(1)
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.editPortal()
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.editingPortal

            TextField {
              id: portalField
              width: parent.width
              placeholderText: "Portal, e.g. vpn.example.org"
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              foreground: root.bar.foreground
              horizontalPadding: Style.spacing.controlGap
              verticalPadding: Style.spacing.controlPaddingY
              text: root.portalDraft

              onTextChanged: if (text !== root.portalDraft) root.portalDraft = text
              onAccepted: root.savePortal(text)
              Keys.onEscapePressed: root.editingPortal = false

              onVisibleChanged: if (visible) Qt.callLater(function() { forceActiveFocus(); selectAll() })
            }

            ButtonGroup {
              visible: root.recentPortals.length > 0
              focusable: false
              options: root.recentPortals.map(function(p) { return { value: p, label: p, tooltip: "Use " + p } })
              value: root.portal
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.caption
              onChanged: function(v) { root.savePortal(v) }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Enter saves, Esc cancels. Your choice is remembered."
              color: Qt.darker(root.bar.foreground, 1.6)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Repeater {
            model: {
              var v = root.vpn
              var rows = []
              if (!root.idle && v.address) rows.push(["Address", v.address])
              if (root.phase === "ready") {
                rows.push(["Transport", v.transport === "HTTPS"
                  ? "HTTPS (ESP over UDP is blocked)" : v.transport || "?"])
                if (v.started && v.since) rows.push(["Came up in", root.clock((v.since - v.started) * 1000)])
                if (v.since) rows.push(["Ready since", root.timeOfDay(v.since)])
              }
              if (!root.idle && v.expires) rows.push(["Session valid until", root.untilText(v.expires)])
              if (!root.idle && v.idle_timeout) rows.push(["Idle timeout", root.duration(v.idle_timeout)])
              return rows
            }

            Row {
              required property var modelData
              width: parent.width

              Text {
                textFormat: Text.PlainText
                text: modelData[0]
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                width: labelMetrics.width + Style.space(16)
              }
              Text {
                textFormat: Text.PlainText
                text: modelData[1]
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                width: parent.width - labelMetrics.width - Style.space(16)
                wrapMode: Text.WordWrap
              }
            }
          }
        }

        // ---------- Warnings and errors ----------
        Text {
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          readonly property string message: root.actionError !== "" ? root.actionError
            : root.phase === "failed" ? (root.vpn.detail || "gpconnect failed; see the log")
            : root.expiringSoon ? "The session ends soon; the gateway will then drop the tunnel and you need to log in again."
            : root.vpn.hip ? "The gateway wants a HIP report; access may be limited."
            : root.phase === "ready" && root.vpn.transport === "HTTPS"
              ? "Add '-- --no-dtls' to the arguments to skip the ESP wait next time." : ""
          visible: message !== ""
          text: message
          color: root.phase === "ready" && !root.vpn.hip && !root.expiringSoon ? Qt.darker(root.bar.foreground, 1.5) : root.bar.urgent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }

        // ---------- Fingerprint (sudo asks before the password) ----------
        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: root.fingerprint !== "" && root.phase !== "password"

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Touch the fingerprint reader"
            color: root.bar.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.fingerprint
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- Root password ----------
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.phase === "password"

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: (root.vpn.attempt || 1) > 1 ? "Wrong password, try again." : "Root password for the tunnel:"
            color: (root.vpn.attempt || 1) > 1 ? root.bar.urgent : root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: pwField
            width: parent.width
            password: true
            placeholderText: "Password"
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            foreground: root.bar.foreground
            horizontalPadding: Style.spacing.controlGap
            verticalPadding: Style.spacing.controlPaddingY
            text: root.passwordText

            onTextChanged: if (text !== root.passwordText) root.passwordText = text
            onAccepted: root.submitPassword()
            // Esc gives up on the connection, so it ends as "off", not "failed".
            Keys.onEscapePressed: {
              root.disconnect()
              root.close()
            }

            onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
          }
        }

        // ---------- Actions ----------
        Row {
          spacing: Style.space(8)

          Button {
            text: root.idle ? "Connect" : root.phase === "ready" || root.phase === "reconnecting"
              ? "Disconnect" : root.phase === "password" ? "Unlock" : "Cancel"
            tooltipText: root.idle ? "Connect (c, Enter)" : root.phase === "password" ? "" : "Disconnect (d, Enter)"
            bordered: true
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.phase === "password" ? root.submitPassword() : root.toggle()
          }

          Button {
            visible: root.phase === "password"
            text: "Cancel"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.disconnect()
          }

          Button {
            text: "Log"
            tooltipText: "Open the log in a terminal (l)"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.openLog()
          }
        }

        // ---------- Key hints ----------
        Text {
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          // The portal editor shows its own hint.
          visible: !root.editingPortal
          text: root.phase === "password" ? "Enter unlock · Esc cancel"
            : (root.idle ? "c connect · e edit portal" : "d disconnect") + " · l log · Esc close"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  function openLog() {
    close()
    bar.run("omarchy-launch-floating-terminal-with-presentation tail -n 200 -f " + Util.shellQuote(logFile))
  }
}
