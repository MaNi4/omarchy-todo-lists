.pragma library

// The key that opens the To-Do Lists panel: which Lua to hand `hyprctl eval`
// so that exactly one binding, the configured hotkey, opens it, and which
// keys to offer when that one is taken. Taken from mani4.search-menu-items. Pure: `hyprctl binds -j` in, answers out, so
// it runs under node in tests/run.js.
//
// Our bindings are told apart by their description. No config file is
// written here (bin/todo-lists keeps the choice); Hyprland forgets runtime
// binds when its config reloads, so Service.qml asks again after every reload.

var DESCRIPTION = "To-Do Lists"

// Offered when the hotkey is taken, in this order.
var IDEAS = ["SUPER + R", "SUPER + ALT + R", "SUPER + SHIFT + R", "SUPER + U", "SUPER + ALT + U",
  "SUPER + N", "SUPER + ALT + N", "SUPER + ALT + T", "SUPER + SEMICOLON", "SUPER + APOSTROPHE"]

var MODIFIERS = { SHIFT: 1, CTRL: 4, CONTROL: 4, ALT: 8, SUPER: 64 }
var ORDER = [["SUPER", 64], ["CTRL", 4], ["ALT", 8], ["SHIFT", 1]]

// "SUPER + ALT + M" -> { mask: 72, key: "M" }; null when empty or malformed.
function parse(text) {
  var parts = String(text || "").split("+").map(function(part) { return part.trim().toUpperCase() })
  var key = parts.pop()
  if (!key || !/^[A-Z0-9_:]+$/.test(key) || MODIFIERS[key] !== undefined) return null
  var mask = 0
  for (var i = 0; i < parts.length; i++) {
    if (MODIFIERS[parts[i]] === undefined) return null
    mask |= MODIFIERS[parts[i]]
  }
  return { mask: mask, key: key }
}

function format(mask, key) {
  var names = []
  for (var i = 0; i < ORDER.length; i++) if (mask & ORDER[i][1]) names.push(ORDER[i][0])
  names.push(key)
  return names.join(" + ")
}

// "super+alt + m" -> "SUPER + ALT + M"; "" when it is not a key combination.
function tidy(text) {
  var combo = parse(text)
  return combo ? format(combo.mask, combo.key) : ""
}

// What already runs on that key, "" when it is free. Our own binding does not count.
function holder(bindsJson, hotkey) {
  var binds = []
  try { binds = JSON.parse(bindsJson) || [] } catch (e) { binds = [] }
  var want = parse(hotkey)
  if (!want) return ""
  for (var i = 0; i < binds.length; i++) {
    var bind = binds[i]
    if (bind.description === DESCRIPTION) continue
    if (bind.modmask === want.mask && keyOf(bind) === want.key) return bind.description || bind.dispatcher || "another binding"
  }
  return ""
}

// The keys to choose from for what is typed so far: the typed combination
// itself when it reads as one, then the ideas it matches. Free keys come
// first; a taken one says what holds it.
//   [{ hotkey: "SUPER + M", holder: "" }, { hotkey: "SUPER + K", holder: "Keybindings" }]
function choices(bindsJson, typed) {
  // A bare letter is not a key to give away to a panel.
  var combo = parse(typed)
  var own = combo && combo.mask !== 0 ? format(combo.mask, combo.key) : ""
  var query = String(typed || "").toUpperCase().replace(/\s+/g, "")
  var hotkeys = own ? [own] : []
  for (var i = 0; i < IDEAS.length; i++) {
    if (IDEAS[i] !== own && IDEAS[i].replace(/\s+/g, "").indexOf(query) >= 0) hotkeys.push(IDEAS[i])
  }
  var free = []
  var taken = []
  for (var j = 0; j < hotkeys.length; j++) {
    var held = holder(bindsJson, hotkeys[j])
    ;(held ? taken : free).push({ hotkey: hotkeys[j], holder: held })
  }
  return free.concat(taken)
}

function quote(text) {
  return '"' + String(text).replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n") + '"'
}

function keyOf(bind) {
  // Keycode binds ("code:58") report the key in `keycode`.
  return bind.key ? String(bind.key).toUpperCase() : (bind.keycode ? "CODE:" + bind.keycode : "")
}

function unbind(mask, key) {
  return "hl.unbind(" + quote(format(mask, key)) + ")"
}

// Returns { lua: [statements], bound: bool, conflict: "what holds the key" }.
// Binding is one statement pair, unbind then bind, run by Hyprland at once:
// however two instances of the plugin overlap (a reload), the key ends up
// bound once. hl.unbind takes everything on a key, so a key that holds
// someone else's binding is never unbound.
function plan(bindsJson, hotkey, command) {
  var binds = []
  try { binds = JSON.parse(bindsJson) || [] } catch (e) { binds = [] }
  var want = parse(hotkey)
  var lua = []
  var have = 0
  function foreign(mask, key) {
    for (var k = 0; k < binds.length; k++) {
      var b = binds[k]
      if (b.description !== DESCRIPTION && b.modmask === mask && keyOf(b) === key) return b
    }
    return null
  }

  // Our bindings on other keys (an older choice) go.
  for (var i = 0; i < binds.length; i++) {
    var bind = binds[i]
    if (bind.description !== DESCRIPTION) continue
    if (want && bind.modmask === want.mask && keyOf(bind) === want.key) have++
    else if (!foreign(bind.modmask, keyOf(bind))) lua.push(unbind(bind.modmask, keyOf(bind)))
  }
  if (!want) return { lua: lua, bound: false, conflict: "" }

  var other = foreign(want.mask, want.key)
  if (other) return { lua: lua, bound: have > 0, conflict: have > 0 ? "" : (other.description || other.dispatcher || "another binding") }
  if (have === 1) return { lua: lua, bound: true, conflict: "" }

  lua.push(unbind(want.mask, want.key) + "\n" + "hl.bind(" + quote(format(want.mask, want.key)) + ", hl.dsp.exec_cmd(" + quote(command)
    + "), { description = " + quote(DESCRIPTION) + " })")
  return { lua: lua, bound: true, conflict: "" }
}
