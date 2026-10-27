.pragma library

// What the panel decides, with no QML in it, so tests/run.js can check it:
// which list is in view, ticking, passwords, the settings' rows, the sync
// line, the keyboard cursor and keys, pasting, and fitting the tabs.
// Panel.qml holds the state and does what these say.

// ---------- Lists ----------

function listById(lists, id) {
  for (var i = 0; i < lists.length; i++) if (lists[i].id === id) return lists[i]
  return null
}

// The list in view: the one chosen, or the first while it is not there.
function currentList(lists, id) {
  return listById(lists, id) || (lists.length ? lists[0] : null)
}

// The lock button's step for a list: lock it, unlock it, or (unlocked)
// lock it again or take the lock off.
function lockMode(list) {
  return !list.locked ? "lock" : list.unlocked ? "unlocked" : "unlock"
}

// The list dx steps away, round the ends.
function steppedList(lists, id, dx) {
  if (!lists.length) return ""
  var ids = lists.map(function(l) { return l.id })
  var i = ids.indexOf(id)
  return ids[((i < 0 ? 0 : i) + dx % ids.length + ids.length) % ids.length]
}

// Where a to-do can move: the other lists. A locked one is shown, but must
// be unlocked first.
function moveRows(lists, currentId) {
  return lists.filter(function(l) { return l.id !== currentId }).map(function(l) {
    var shut = !!l.locked && !l.unlocked
    return { id: l.id, label: l.name, off: shut, on: false, where: shut ? "locked: unlock it first" : l.locked ? "unlocked" : "" }
  })
}

// ---------- Ticking ----------
// A ticked to-do stays where it is for a moment, so a slip can be taken
// back; `pending` holds those ticks, by to-do id: { list, done }.

function isTicked(pending, item) {
  var p = pending[item.id]
  return p !== undefined ? p.done : !!item.done
}

// pending with item's tick added, or taken back if it was there.
function toggled(pending, item, listId) {
  var out = {}
  for (var k in pending) out[k] = pending[k]
  if (out[item.id] !== undefined) delete out[item.id]
  else out[item.id] = { list: listId, done: !item.done }
  return out
}

// The store's ops for the ticks that are due.
function tickOps(pending) {
  var ops = []
  for (var id in pending) ops.push({ op: "done", list: pending[id].list, item: id, done: pending[id].done })
  return ops
}

// ---------- Deleting, with Undo ----------
// Deleted to-dos are hidden at once and deleted for good a few seconds
// later, unless Undo brings them back. `removing` holds them, by to-do id:
// the list each is in.

function withRemoved(removing, ids, listId) {
  var out = {}
  for (var k in removing) out[k] = removing[k]
  ids.forEach(function(id) { out[id] = listId })
  return out
}

function withoutRemoved(removing, ids) {
  var out = {}
  for (var k in removing) if (ids.indexOf(k) < 0) out[k] = removing[k]
  return out
}

function visibleItems(items, removing) {
  return items.filter(function(x) { return removing[x.id] === undefined })
}

function removeOps(removing) {
  var ops = []
  for (var id in removing) ops.push({ op: "remove", list: removing[id], item: id })
  return ops
}

// A name for a new record: 16 hex digits, as the store makes them. Not a
// secret, only unique.
function freshId() {
  var out = ""
  for (var i = 0; i < 16; i++) out += "0123456789abcdef"[Math.floor(Math.random() * 16)]
  return out
}

function clearedText(n) {
  return n === 1 ? "Cleared 1 to-do" : "Cleared " + n + " to-dos"
}

// ---------- Passwords ----------
// What is wrong with a new password typed twice, or "". `optional`: empty
// is allowed (it takes a list's lock off).
function passwordProblem(password, again, least, optional) {
  if (!(optional && password === "") && password.length < least) return "Use at least " + least + " characters"
  if (password !== again) return "The passwords are not the same"
  return ""
}

// ---------- Settings ----------
// The settings' rows. `s`: { legacy, boundHotkey, hotkeyConflict, hasService,
// repo, syncState, remembered }.
function settingRows(s) {
  var taken = !!s.hotkeyConflict
  var rows = []
  if (s.legacy)
    rows.push({ page: "update", label: "Finish the update", where: "one step: the master password, then a new recovery key",
                keys: "", value: "", urgent: true })
  return rows.concat([
    { page: "shortcut", label: "Shortcut", keys: s.boundHotkey || "",
      where: taken ? "taken by “" + s.hotkeyConflict + "”, choose another" : "opens this panel",
      value: s.hasService && !s.boundHotkey && !taken ? "none" : "", urgent: taken },
    { page: "sync", label: "Sync", where: "your lists on GitHub too, for your phone", keys: "",
      value: s.repo ? s.repo : "off", urgent: s.syncState === "error" },
    { page: "password", label: "Master password", where: "change it", keys: "", value: "", urgent: false },
    { page: "recovery", label: "Recovery key", where: "make a new one", keys: "", value: "", urgent: false },
    { page: "export", label: "Export", where: "your lists as a Markdown file", keys: "", value: "", urgent: false },
    { page: "computer", label: "This computer", keys: "", urgent: false, value: "",
      where: s.remembered === "keyring" ? "remembers the master password"
        : s.remembered === "session" ? "remembers it until a restart" : "asks for it after a restart" },
    { page: "keys", label: "Keyboard", where: "every key of the panel", keys: "", value: "", urgent: false },
  ])
}

function rowIndex(rows, page) {
  for (var i = 0; i < rows.length; i++) if (rows[i].page === page) return i
  return 0
}

// The shortcut picker's rows: Hotkey.choices(), and "No shortcut" while
// nothing is typed. `bound`: the key bound now; `none`: no key is wanted.
function pickRows(choices, bound, typed, none) {
  var rows = choices.map(function(c) {
    return { hotkey: c.hotkey, label: c.hotkey, on: c.hotkey === bound, off: c.holder !== "",
             where: c.holder ? "runs “" + c.holder + "”" : "free" }
  })
  if (String(typed || "").trim() === "")
    rows.push({ hotkey: "", label: "No shortcut", on: !!none, off: false, where: "bind it yourself, or not at all" })
  return rows
}

// ---------- Sync ----------

function timeAgo(epoch, now) {
  var s = Math.max(0, now - epoch)
  if (s < 60) return "just now"
  if (s < 3600) return Math.floor(s / 60) + " min ago"
  if (s < 86400) return Math.floor(s / 3600) + " h ago"
  return Math.floor(s / 86400) + " d ago"
}

// `now` in seconds, as sync.last.
function syncText(sync, repo, now) {
  var st = String(sync.state || "off")
  if (st === "off") return "Not synced; only on this computer"
  if (st === "syncing") return "Syncing with " + repo + "…"
  if (st === "offline" || st === "error") return String(sync.error || "Sync failed")
  if (sync.last) return "Synced with " + repo + " " + timeAgo(sync.last, now)
  return "Syncing with " + repo
}

function syncIcon(state) {
  var st = String(state || "off")
  return st === "syncing" ? "\u{f12d6}" : st === "offline" ? "\u{f0164}" : st === "error" ? "\u{f09e0}" : "\u{f12cc}"
}

// ---------- The keyboard cursor ----------
// The cursor stops on these, by key: "set:<page>", "pick:<n>", "list:<id>",
// "new", "item:<id>", "completed", "to:<id>" (a list to move a to-do to). `v`: { view, settingsPage, settingRows,
// pickRows, moveRows, lists, openItems, doneItems, showDone, hidden }.
function focusItems(v) {
  if (v.view === "move") return v.moveRows.map(function(r) { return "to:" + r.id })
  if (v.view === "settings") {
    if (v.settingsPage === "") return v.settingRows.map(function(r) { return "set:" + r.page })
    if (v.settingsPage === "shortcut") return v.pickRows.map(function(r, i) { return "pick:" + i })
    return []
  }
  if (v.view === "lists") return v.lists.map(function(l) { return "list:" + l.id }).concat(["new"])
  if (v.view !== "list" || v.hidden) return []
  var keys = v.openItems.map(function(x) { return "item:" + x.id })
  if (v.doneItems.length) {
    keys.push("completed")
    if (v.showDone) keys = keys.concat(v.doneItems.map(function(x) { return "item:" + x.id }))
  }
  return keys
}

// What a key of the cursor is: { kind: "set" | "pick" | "list" | "item" | "new"
// | "completed", id }.
function cursorKey(key) {
  var at = key.indexOf(":")
  return at < 0 ? { kind: key, id: "" } : { kind: key.substring(0, at), id: key.substring(at + 1) }
}

// Where an arrow takes the cursor. `c`: { view, settingsPage, active, index,
// count }. Returns { active, index, then }; `then` is what the panel does
// besides: "" or "hotkeyField" (up out of the shortcut list), "newList"
// (onto the Lists screen's new-list field), "add" (up out of the to-dos,
// into the add field), "step" (left or right: the next list).
function cursorMove(c, dx, dy) {
  var same = { active: c.active, index: c.index, then: "" }
  var clamp = function(i) { return Math.max(0, Math.min(c.count - 1, i)) }
  if (c.view === "settings" || c.view === "move") {
    if (dy === 0 || c.count === 0) return same
    if (!c.active) return { active: true, index: dy > 0 ? 0 : c.count - 1, then: "" }
    var to = c.index + dy
    if (to < 0 && c.settingsPage === "shortcut") return { active: false, index: c.index, then: "hotkeyField" }
    return { active: true, index: clamp(to), then: "" }
  }
  if (c.view === "lists") {
    if (dy === 0) return same
    if (!c.active) return { active: true, index: 0, then: "" }
    var at = clamp(c.index + dy)
    return { active: true, index: at, then: at === c.count - 1 ? "newList" : "" }
  }
  if (c.view !== "list") return same
  if (dx !== 0) return { active: c.active, index: c.index, then: "step" }
  if (!c.active) return c.count === 0 ? same : { active: true, index: dy > 0 ? 0 : c.count - 1, then: "" }
  var next = c.index + dy
  if (next < 0) return { active: false, index: c.index, then: "add" }
  return { active: true, index: Math.min(c.count - 1, next), then: "" }
}

// Moving the thing under the cursor by `by` among `count`: where the
// cursor goes, and how far the thing moves (0: it is at the end already).
function cursorShift(index, by, count) {
  var to = Math.max(0, Math.min(count - 1, index + by))
  return { index: to, by: to - index }
}

// Keys the panel's catcher does not tell apart (it sees Shift+Left as
// Left), taken before it. `k`: { view, key ("Left", "Right", "Up", "Down",
// "F2", "L", or ""), text (what the key types), shift, ctrl, field (the
// field's text when typing in one, else null), hasItem (a to-do is under
// the cursor), hasList (a list is, on the Lists screen) }. Returns the
// action: "listLeft", "listRight", "renameList", "lockNow", "itemUp",
// "itemDown", "rowUp", "rowDown", "renameRow", or "".
// From a field, only what typing has no use for: Shift with an arrow while
// the field is empty, F2, Ctrl+L.
function specialKey(k) {
  var inField = k.field !== null && k.field !== undefined
  var arrowsFree = !inField || k.field.length === 0
  if (k.view === "list") {
    if ((k.shift && arrowsFree && k.key === "Left") || (!inField && k.text === "H")) return "listLeft"
    if ((k.shift && arrowsFree && k.key === "Right") || (!inField && k.text === "L")) return "listRight"
    if (k.key === "F2") return "renameList"
    if (k.ctrl && k.key === "L") return "lockNow"
    if (!inField && k.hasItem && k.shift && (k.key === "Up" || k.key === "Down")) return k.key === "Up" ? "itemUp" : "itemDown"
  } else if (k.view === "lists" && !inField) {
    if ((k.shift && k.key === "Up") || k.text === "K") return "rowUp"
    if ((k.shift && k.key === "Down") || k.text === "J") return "rowDown"
    if (k.key === "F2" && k.hasList) return "renameRow"
  }
  return ""
}

// ---------- Typing ----------

// One line of text, no control characters, at most `max` characters.
function fieldText(text, max) {
  var line = String(text || "").replace(/[\u0000-\u001f\u007f]/g, "")
  return Array.from(line).slice(0, max).join("")
}

// What a paste puts in a field: the clipboard's first line, without a
// character cut in half by the read, as much as the field has room for.
function pastedText(raw, room) {
  var line = String(raw || "").replace(/�+$/, "").split(/\r\n|\r|\n/)[0]
  return fieldText(line, Math.max(0, room))
}

// ---------- Tabs ----------

function tabLabel(tab) {
  return tab.count > 0 ? tab.label + " (" + tab.count + ")" : tab.label
}

// A tab's label cut to fit `room` pixels of a monospaced font, its count
// always shown.
function shortLabel(tab, room, charWidth) {
  var tail = tab.count > 0 ? " (" + tab.count + ")" : ""
  var label = String(tab.label || "")
  var most = Math.floor(room / Math.max(1, charWidth)) - tail.length
  if (label.length > most) label = label.substring(0, Math.max(1, most - 1)) + "…"
  return label + tail
}

// How many tabs fit in `width`, leaving room for More when they do not all
// fit; at least one.
function tabsThatFit(widths, spacing, width, moreWidth) {
  var n = widths.length
  var total = 0
  for (var i = 0; i < n; i++) total += widths[i] + (i > 0 ? spacing : 0)
  if (total <= width) return n
  var room = width - moreWidth - spacing
  var used = 0
  var k = 0
  for (; k < n; k++) {
    var add = widths[k] + (k > 0 ? spacing : 0)
    if (used + add > room) break
    used += add
  }
  return Math.max(1, k)
}

// The room left in the row, shared out evenly to the tabs shown (and More).
function tabExtra(widths, fit, spacing, width, moreWidth, hasMore) {
  var used = 0
  for (var i = 0; i < fit && i < widths.length; i++) used += widths[i] + (i > 0 ? spacing : 0)
  if (hasMore) used += spacing + moreWidth
  return Math.max(0, Math.floor((width - used) / (fit + (hasMore ? 1 : 0))))
}
