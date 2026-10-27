import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "Store.js" as Store
import "Hotkey.js" as Hotkey

// The lists, mounted once for the shell. Omarchy builds a bar per monitor,
// so a Process on the widget would be one writer per screen. Every Panel.qml
// is a view of this instead, and bin/todo-lists is the only one that writes
// the file.
Item {
  id: service
  visible: false

  // Where panels that the shell does not hand this service to find it.
  Component.onCompleted: Store.set(service)
  Component.onDestruction: {
    Store.clear(service)
    // Disabling, removing or reloading the plugin takes the binding with it.
    var combo = Hotkey.parse(service.boundHotkey)
    if (combo) Quickshell.execDetached(["hyprctl", "eval", Hotkey.unbind(combo.mask, combo.key)])
  }

  property var status: ({ state: "loading", error: "", lists: [], sync: { state: "off" } })
  property bool loading: true
  // The list last looked at, so every panel opens on it.
  property string lastList: ""

  readonly property string pluginDir: {
    var s = String(Qt.resolvedUrl("."))
    return s.indexOf("file://") === 0 ? s.substring(7) : s
  }

  Process {
    id: store
    running: true
    command: [service.pluginDir + "bin/todo-lists"]
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) {
        // 50 lists of 1000 to-dos is the most it keeps; a line past
        // 16 MiB is not ours.
        if (line.length > 16777216) return
        try {
          var d = JSON.parse(String(line))
          if (d && typeof d === "object" && Array.isArray(d.lists)) {
            service.status = d
            service.loading = false
            if (d.notice) service.notice(d.notice)
          }
        } catch (e) { }
      }
    }
    // Gone (killed, or crashed): started again, so changes are not lost.
    onRunningChanged: if (!running) restart.start()
  }

  Timer {
    id: restart
    interval: 2000
    onTriggered: store.running = true
  }

  // An answer to a command (wrong password, connected, ...), for the panels.
  signal notice(var n)

  // ---------- The key that opens the panel ----------
  // Bound at runtime with `hyprctl eval`, as mani4.search-menu-items does: no
  // Hyprland file is written. A key something else holds is left alone, and
  // a notification offers to choose another (in the panel's settings). The
  // choice is kept in todo-lists.json by bin/todo-lists; "" binds nothing.
  readonly property string defaultHotkey: "SUPER + R"
  readonly property string hotkeyCommand: "omarchy-shell shell toggle mani4.todo-lists"
  // Nothing until the settings are read, so a chosen key (or none) is not
  // preceded by the default.
  readonly property string hotkey: {
    if (loading) return ""
    var h = status.hotkey
    return typeof h === "string" ? Hotkey.tidy(h) : defaultHotkey
  }
  onHotkeyChanged: hotkeyTimer.restart()
  property string boundHotkey: ""     // what we bound, so unloading can unbind it
  property string hotkeyConflict: ""  // what holds the key, when it is taken
  property string warnedConflict: ""  // notify once per key, not on every reload
  property string bindsJson: "[]"     // for the panel's list of free keys
  property bool hotkeyQueued: false
  // Set by the notification: the panel opens on the shortcut setting.
  property bool wantShortcutSetup: false

  // The short delay lets a previous instance's unbind land first when the
  // plugin is reloaded.
  // Started once the settings are read (onHotkeyChanged): before that the
  // key is not known, and acting on "no key" would unbind it.
  Timer {
    id: hotkeyTimer
    interval: 600
    onTriggered: service.ensureHotkey()
  }

  function ensureHotkey() {
    if (service.loading) return
    if (bindsProc.running) { service.hotkeyQueued = true; return }
    bindsProc.running = true
  }

  function reconcile(json) {
    service.bindsJson = json
    var plan = Hotkey.plan(json, service.hotkey, service.hotkeyCommand)
    if (plan.lua.length > 0) Quickshell.execDetached(["hyprctl", "eval", plan.lua.join("\n")])
    service.boundHotkey = plan.bound ? service.hotkey : ""
    service.hotkeyConflict = plan.conflict
    if (plan.conflict && service.warnedConflict !== service.hotkey) {
      service.warnedConflict = service.hotkey
      conflictNote.taken = service.hotkey + " already runs \"" + plan.conflict + "\"."
      conflictNote.running = true
    }
    if (service.hotkeyQueued) { service.hotkeyQueued = false; service.ensureHotkey() }
  }

  // The panel's settings ask for the binds again, for a fresh list.
  function refreshBinds() { ensureHotkey() }

  function setHotkey(text) {
    cmd({ cmd: "setHotkey", hotkey: Hotkey.tidy(text) })
  }

  // Clicking the notification opens the panel on the shortcut setting.
  Process {
    id: conflictNote
    property string taken: ""
    command: ["notify-send", "-a", "To-Do Lists", "-A", "default=Choose a key",
      "To-Do Lists has no key", taken + " Click to choose another one."]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text || "").trim() !== "default") return
        service.wantShortcutSetup = true
        Quickshell.execDetached(["omarchy-shell", "shell", "summon", "mani4.todo-lists"])
      }
    }
  }

  Process {
    id: bindsProc
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.reconcile(String(text || ""))
    }
  }

  // Hyprland drops runtime binds when its config reloads.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event && String(event.name) === "configreloaded") service.ensureHotkey()
    }
  }

  // One command, as bin/todo-lists takes it: one line of JSON, which never
  // holds a line break. Passwords, tokens and to-dos go on stdin, never
  // in arguments.
  function cmd(c) {
    if (!store.running || !c || typeof c !== "object") return false
    store.write(JSON.stringify(c) + "\n")
    return true
  }

  // A change to the lists (see apply() in bin/todo-lists).
  function op(change) {
    var c = { cmd: "op" }
    for (var k in change) c[k] = change[k]
    return cmd(c)
  }
}
