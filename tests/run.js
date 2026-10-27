// node tests/run.js — checks Model.js and Hotkey.js, which have no QML in
// them; the QML is checked by hand. bin/todo-lists has its own tests:
// python3 -m unittest discover -s tests
const fs = require("fs")
const path = require("path")
const assert = require("assert")

const library = (file, names) => {
  const source = fs.readFileSync(path.join(__dirname, "..", file), "utf8").replace(/^\.pragma library\s*$/m, "")
  return new Function(source + "\nreturn { " + names + " }")()
}
const Hotkey = library("Hotkey.js", "parse, format, tidy, holder, plan, choices, IDEAS, DESCRIPTION")
const Model = library("Model.js", `listById, currentList, lockMode, steppedList, isTicked, toggled, tickOps,
  passwordProblem, settingRows, rowIndex, pickRows, timeAgo, syncText, syncIcon, focusItems, cursorKey, cursorMove,
  cursorShift, specialKey, fieldText, pastedText, tabLabel, shortLabel, tabsThatFit, tabExtra, moveRows, withRemoved,
  withoutRemoved, visibleItems, removeOps, clearedText, freshId`)

// What `hyprctl binds -j` reports: SUPER is 64, CTRL 4, ALT 8, SHIFT 1.
// Omarchy's own reminder keys sit on SUPER + CTRL (+ ALT, + SHIFT) + R.
const bind = (modmask, key, description) => ({ modmask, key, description, dispatcher: "exec" })
const binds = extra => JSON.stringify([
  bind(64, "K", "Keybindings"), bind(68, "R", "Set reminder"), bind(76, "R", "Show reminders"),
  bind(65, "R", "Something"), bind(64, "", "By keycode"),
].concat(extra || []))
const ours = (modmask, key) => bind(modmask, key, Hotkey.DESCRIPTION)

const tests = {
  "a key combination is read whatever its spacing and case"() {
    assert.deepStrictEqual(Hotkey.parse("super+alt + r"), { mask: 72, key: "R" })
    assert.strictEqual(Hotkey.tidy("super+alt + r"), "SUPER + ALT + R")
    assert.strictEqual(Hotkey.tidy("ctrl + super + slash"), "SUPER + CTRL + SLASH")
  },
  "what is not a key combination is turned down"() {
    for (const text of ["", "SUPER + ", "hello world", "super + ctrl", "foo + r", "super + r!"])
      assert.strictEqual(Hotkey.tidy(text), "", JSON.stringify(text))
  },
  "holder names what runs on a key"() {
    assert.strictEqual(Hotkey.holder(binds(), "SUPER + K"), "Keybindings")
    assert.strictEqual(Hotkey.holder(binds(), "super + ctrl + r"), "Set reminder")
    assert.strictEqual(Hotkey.holder(binds(), "SUPER + R"), "")
  },
  "our own binding does not hold a key against us"() {
    assert.strictEqual(Hotkey.holder(binds([ours(64, "R")]), "SUPER + R"), "")
  },
  "holder copes with output that is not JSON"() {
    assert.strictEqual(Hotkey.holder("", "SUPER + K"), "")
    assert.strictEqual(Hotkey.holder("oops", "SUPER + K"), "")
  },
  "a free key gets bound"() {
    const plan = Hotkey.plan(binds(), "SUPER + R", "open-it")
    assert.strictEqual(plan.bound, true)
    assert.strictEqual(plan.conflict, "")
    assert.deepStrictEqual(plan.lua,
      ['hl.unbind("SUPER + R")\nhl.bind("SUPER + R", hl.dsp.exec_cmd("open-it"), { description = "To-Do Lists" })'])
  },
  "a taken key is left alone and named"() {
    assert.deepStrictEqual(Hotkey.plan(binds(), "SUPER + K", "open-it"), { lua: [], bound: false, conflict: "Keybindings" })
  },
  "a key we already hold is not bound twice"() {
    assert.deepStrictEqual(Hotkey.plan(binds([ours(64, "R")]), "SUPER + R", "open-it"),
      { lua: [], bound: true, conflict: "" })
  },
  "changing the key lets go of the old one"() {
    const plan = Hotkey.plan(binds([ours(64, "R")]), "SUPER + ALT + R", "open-it")
    assert.strictEqual(plan.lua[0], 'hl.unbind("SUPER + R")')
    assert.ok(plan.lua[1].startsWith('hl.unbind("SUPER + ALT + R")\nhl.bind("SUPER + ALT + R"'))
    assert.strictEqual(plan.bound, true)
  },
  "an empty hotkey binds nothing and lets go of ours"() {
    assert.deepStrictEqual(Hotkey.plan(binds([ours(64, "R")]), "", "open-it"),
      { lua: ['hl.unbind("SUPER + R")'], bound: false, conflict: "" })
  },
  "the command is quoted for Lua"() {
    const plan = Hotkey.plan(binds(), "SUPER + R", 'say "hi"\\now')
    assert.ok(plan.lua[0].includes('hl.dsp.exec_cmd("say \\"hi\\"\\\\now")'), plan.lua[0])
  },
  "with nothing typed every idea is offered, free ones first"() {
    const choices = Hotkey.choices(binds(), "")
    assert.strictEqual(choices.length, Hotkey.IDEAS.length)
    assert.deepStrictEqual(choices[0], { hotkey: "SUPER + R", holder: "" })
    assert.deepStrictEqual(choices[choices.length - 1], { hotkey: "SUPER + SHIFT + R", holder: "Something" })
  },
  "a typed combination is offered itself, and says when it is taken"() {
    assert.deepStrictEqual(Hotkey.choices(binds(), "super + k"), [{ hotkey: "SUPER + K", holder: "Keybindings" }])
    assert.deepStrictEqual(Hotkey.choices(binds(), "super+f9"), [{ hotkey: "SUPER + F9", holder: "" }])
  },
  "a key bound twice (a reload race) is bound again, once"() {
    const plan = Hotkey.plan(binds([ours(64, "R"), ours(64, "R")]), "SUPER + R", "x")
    assert.strictEqual(plan.bound, true)
    assert.strictEqual(plan.lua.length, 1)
    assert.ok(plan.lua[0].startsWith('hl.unbind("SUPER + R")\nhl.bind('), plan.lua[0])
  },
  "someone else's binding on the same key is never unbound"() {
    const twice = Hotkey.plan(binds([ours(64, "R"), ours(64, "R"), bind(64, "R", "Mine")]), "SUPER + R", "x")
    assert.ok(twice.lua.every(l => !l.startsWith("hl.unbind(")), twice.lua.join())
    // SUPER + SHIFT + R (65) holds "Something" too: our old binding there stays.
    const moved = Hotkey.plan(binds([ours(65, "R")]), "SUPER + F9", "x")
    assert.ok(moved.lua.every(l => !l.startsWith('hl.unbind("SUPER + SHIFT + R")')), moved.lua.join())
  },
  "a key bound once is left alone"() {
    assert.deepStrictEqual(Hotkey.plan(binds([ours(64, "R")]), "SUPER + R", "x"), { lua: [], bound: true, conflict: "" })
  },
  "a bare letter is not offered as a key"() {
    assert.ok(Hotkey.choices(binds(), "r").every(choice => choice.hotkey !== "R"))
  },
}

// ---------- Model.js ----------
const lists = [
  { id: "a", name: "Shopping", locked: false },
  { id: "b", name: "Work", locked: true, unlocked: true },
  { id: "c", name: "Gifts", locked: true, unlocked: false },
]
const item = (id, done) => ({ id, text: id, done: !!done })
const listView = extra => Object.assign({ view: "list", settingsPage: "", settingRows: [], pickRows: [], lists,
  openItems: [item("x"), item("y")], doneItems: [item("z", true)], showDone: false, hidden: false }, extra)
const keyOf = extra => Object.assign({ view: "list", key: "", text: "", shift: false, ctrl: false, field: null,
  hasItem: false, hasList: false }, extra)

Object.assign(tests, {
  "a to-do can move to every other list; a locked one is shown, but must be unlocked"() {
    const rows = Model.moveRows(lists, "a")
    assert.deepStrictEqual(rows.map(r => [r.id, r.label, r.off, r.where]),
      [["b", "Work", false, "unlocked"], ["c", "Gifts", true, "locked: unlock it first"]])
    assert.deepStrictEqual(Model.focusItems(listView({ view: "move", moveRows: rows })), ["to:b", "to:c"])
    const at = (active, index) => ({ view: "move", settingsPage: "", active, index, count: 2 })
    assert.deepStrictEqual(Model.cursorMove(at(false, 0), 0, 1), { active: true, index: 0, then: "" })
    assert.deepStrictEqual(Model.cursorMove(at(true, 0), 0, 1), { active: true, index: 1, then: "" })
    assert.deepStrictEqual(Model.cursorMove(at(true, 0), 0, -1), { active: true, index: 0, then: "" })
    assert.deepStrictEqual(Model.cursorKey("to:b"), { kind: "to", id: "b" })
  },
  "deleted to-dos hide at once, Undo brings them back, the rest go to the store"() {
    let removing = Model.withRemoved({}, ["x"], "a")
    removing = Model.withRemoved(removing, ["y", "z"], "b")
    assert.deepStrictEqual(Model.visibleItems([item("x"), item("y"), item("w")], removing).map(x => x.id), ["w"])
    const undone = Model.withoutRemoved(removing, ["y", "z"])
    assert.deepStrictEqual(Object.keys(undone), ["x"])
    assert.deepStrictEqual(Object.keys(removing).sort(), ["x", "y", "z"], "the old map is not changed")
    assert.deepStrictEqual(Model.removeOps(undone), [{ op: "remove", list: "a", item: "x" }])
    assert.deepStrictEqual(Model.removeOps({}), [])
    assert.strictEqual(Model.clearedText(1), "Cleared 1 to-do")
    assert.strictEqual(Model.clearedText(3), "Cleared 3 to-dos")
    assert.match(Model.freshId(), /^[0-9a-f]{16}$/)
    assert.notStrictEqual(Model.freshId(), Model.freshId())
  },
  "the list in view is the one chosen, else the first"() {
    assert.strictEqual(Model.currentList(lists, "b").name, "Work")
    assert.strictEqual(Model.currentList(lists, "gone").name, "Shopping")
    assert.strictEqual(Model.currentList([], "a"), null)
    assert.strictEqual(Model.listById(lists, "gone"), null)
  },
  "a list's lock button: lock, unlock, or the unlocked choices"() {
    assert.deepStrictEqual(lists.map(Model.lockMode), ["lock", "unlocked", "unlock"])
  },
  "stepping through lists goes round the ends"() {
    assert.strictEqual(Model.steppedList(lists, "a", 1), "b")
    assert.strictEqual(Model.steppedList(lists, "c", 1), "a")
    assert.strictEqual(Model.steppedList(lists, "a", -1), "c")
    assert.strictEqual(Model.steppedList(lists, "gone", 1), "b")
    assert.strictEqual(Model.steppedList(lists, "a", -4), "c")
    assert.strictEqual(Model.steppedList([], "a", 1), "")
  },
  "a tick waits, a second tick takes it back, and the rest go to the store"() {
    const milk = item("m"), eggs = item("e", true)
    let pending = Model.toggled({}, milk, "a")
    assert.strictEqual(Model.isTicked(pending, milk), true)
    assert.strictEqual(Model.isTicked(pending, eggs), true)
    pending = Model.toggled(pending, eggs, "a")
    assert.strictEqual(Model.isTicked(pending, eggs), false)
    const before = pending
    assert.deepStrictEqual(Model.tickOps(Model.toggled(pending, milk, "a")), [{ op: "done", list: "a", item: "e", done: false }])
    assert.ok(before.m, "toggled() does not change what it was given")
    assert.deepStrictEqual(Model.tickOps(pending).map(o => o.item).sort(), ["e", "m"])
  },
  "passwords: long enough, typed the same, and empty only where allowed"() {
    assert.strictEqual(Model.passwordProblem("short", "short", 12), "Use at least 12 characters")
    assert.strictEqual(Model.passwordProblem("long enough pw", "long enough Pw", 12), "The passwords are not the same")
    assert.strictEqual(Model.passwordProblem("1234", "1234", 4), "")
    assert.strictEqual(Model.passwordProblem("", "", 4), "Use at least 4 characters")
    assert.strictEqual(Model.passwordProblem("", "", 4, true), "")
    assert.strictEqual(Model.passwordProblem("", "x", 4, true), "The passwords are not the same")
    assert.strictEqual(Model.passwordProblem("čšť1", "čšť1", 4), "")
  },
  "settings: the update first while one is due, and what each row says"() {
    const base = { legacy: false, hasService: true, repo: "", syncState: "off", boundHotkey: "SUPER + R", hotkeyConflict: "", remembered: "keyring" }
    const rows = Model.settingRows(base)
    assert.deepStrictEqual(rows.map(r => r.page), ["shortcut", "sync", "password", "recovery", "export", "computer", "keys"])
    assert.strictEqual(rows[0].keys, "SUPER + R")
    assert.strictEqual(rows[1].value, "off")
    assert.strictEqual(rows[5].where, "remembers the master password")
    const legacy = Model.settingRows(Object.assign({}, base, { legacy: true }))
    assert.strictEqual(legacy[0].page, "update")
    assert.strictEqual(legacy[0].urgent, true)
    assert.strictEqual(Model.rowIndex(legacy, "sync"), 2)
    assert.strictEqual(Model.rowIndex(legacy, "gone"), 0)
  },
  "settings: a taken key, no key, and a failing sync are shown"() {
    const base = { legacy: false, hasService: true, repo: "me/data", syncState: "error", boundHotkey: "", hotkeyConflict: "", remembered: "" }
    const taken = Model.settingRows(Object.assign({}, base, { hotkeyConflict: "Show reminders" }))
    assert.strictEqual(taken[0].urgent, true)
    assert.ok(taken[0].where.includes("Show reminders"))
    assert.strictEqual(taken[0].value, "")
    const none = Model.settingRows(base)
    assert.strictEqual(none[0].value, "none")
    assert.strictEqual(none[1].value, "me/data")
    assert.strictEqual(none[1].urgent, true)
    assert.strictEqual(none[5].where, "asks for it after a restart")
  },
  "the shortcut picker: free and taken keys, and No shortcut while nothing is typed"() {
    const choices = [{ hotkey: "SUPER + R", holder: "" }, { hotkey: "SUPER + K", holder: "Keybindings" }]
    const rows = Model.pickRows(choices, "SUPER + R", "", false)
    assert.deepStrictEqual(rows.map(r => [r.label, r.on, r.off]), [["SUPER + R", true, false], ["SUPER + K", false, true], ["No shortcut", false, false]])
    assert.strictEqual(rows[1].where, "runs “Keybindings”")
    assert.strictEqual(Model.pickRows(choices, "", "super", true).length, 2)
    assert.strictEqual(Model.pickRows([], "", " ", true)[0].on, true)
  },
  "the sync line"() {
    assert.strictEqual(Model.timeAgo(1000, 1030), "just now")
    assert.strictEqual(Model.timeAgo(1000, 1000 + 125), "2 min ago")
    assert.strictEqual(Model.timeAgo(1000, 1000 + 7300), "2 h ago")
    assert.strictEqual(Model.timeAgo(1000, 1000 + 3 * 86400), "3 d ago")
    assert.strictEqual(Model.timeAgo(2000, 1000), "just now")
    assert.strictEqual(Model.syncText({ state: "off" }, "", 0), "Not synced; only on this computer")
    assert.strictEqual(Model.syncText({ state: "ok", last: 1000 }, "me/data", 1200), "Synced with me/data 3 min ago")
    assert.strictEqual(Model.syncText({ state: "error", error: "Bad token" }, "me/data", 0), "Bad token")
    assert.strictEqual(Model.syncText({ state: "offline" }, "me/data", 0), "Sync failed")
    assert.strictEqual(Model.syncText({ state: "ok" }, "me/data", 0), "Syncing with me/data")
    assert.notStrictEqual(Model.syncIcon("error"), Model.syncIcon("ok"))
    assert.strictEqual(Model.syncIcon(undefined), Model.syncIcon("off"))
  },
  "the cursor stops on to-dos, then Completed, then the done ones while shown"() {
    assert.deepStrictEqual(Model.focusItems(listView()), ["item:x", "item:y", "completed"])
    assert.deepStrictEqual(Model.focusItems(listView({ showDone: true })), ["item:x", "item:y", "completed", "item:z"])
    assert.deepStrictEqual(Model.focusItems(listView({ doneItems: [] })), ["item:x", "item:y"])
    assert.deepStrictEqual(Model.focusItems(listView({ hidden: true })), [])
    assert.deepStrictEqual(Model.focusItems(listView({ view: "lists" })), ["list:a", "list:b", "list:c", "new"])
    assert.deepStrictEqual(Model.focusItems(listView({ view: "settings", settingRows: [{ page: "sync" }] })), ["set:sync"])
    assert.deepStrictEqual(Model.focusItems(listView({ view: "settings", settingsPage: "shortcut", pickRows: [{}, {}] })), ["pick:0", "pick:1"])
    assert.deepStrictEqual(Model.focusItems(listView({ view: "settings", settingsPage: "sync" })), [])
    assert.deepStrictEqual(Model.focusItems(listView({ view: "setup" })), [])
  },
  "a cursor key says what it stands on"() {
    assert.deepStrictEqual(Model.cursorKey("item:ab:c"), { kind: "item", id: "ab:c" })
    assert.deepStrictEqual(Model.cursorKey("completed"), { kind: "completed", id: "" })
    assert.deepStrictEqual(Model.cursorKey("pick:2"), { kind: "pick", id: "2" })
  },
  "arrows in a list: onto the to-dos, up into the add field, sideways to the next list"() {
    const at = (active, index) => ({ view: "list", settingsPage: "", active, index, count: 3 })
    assert.deepStrictEqual(Model.cursorMove(at(false, 0), 0, 1), { active: true, index: 0, then: "" })
    assert.deepStrictEqual(Model.cursorMove(at(false, 0), 0, -1), { active: true, index: 2, then: "" })
    assert.deepStrictEqual(Model.cursorMove(at(true, 1), 0, 1), { active: true, index: 2, then: "" })
    assert.deepStrictEqual(Model.cursorMove(at(true, 2), 0, 1), { active: true, index: 2, then: "" })
    assert.deepStrictEqual(Model.cursorMove(at(true, 0), 0, -1), { active: false, index: 0, then: "add" })
    assert.strictEqual(Model.cursorMove(at(true, 1), 1, 0).then, "step")
    assert.deepStrictEqual(Model.cursorMove({ view: "list", active: false, index: 0, count: 0 }, 0, 1), { active: false, index: 0, then: "" })
  },
  "arrows on the Lists screen and in the settings"() {
    const lists = (active, index) => ({ view: "lists", active, index, count: 4 })
    assert.deepStrictEqual(Model.cursorMove(lists(false, 2), 0, -1), { active: true, index: 0, then: "" })
    assert.deepStrictEqual(Model.cursorMove(lists(true, 2), 0, 1), { active: true, index: 3, then: "newList" })
    assert.deepStrictEqual(Model.cursorMove(lists(true, 2), 1, 0), { active: true, index: 2, then: "" })
    const set = (page, active, index) => ({ view: "settings", settingsPage: page, active, index, count: 5 })
    assert.deepStrictEqual(Model.cursorMove(set("", false, 0), 0, -1), { active: true, index: 4, then: "" })
    assert.deepStrictEqual(Model.cursorMove(set("", true, 0), 0, -1), { active: true, index: 0, then: "" })
    assert.deepStrictEqual(Model.cursorMove(set("shortcut", true, 0), 0, -1), { active: false, index: 0, then: "hotkeyField" })
    assert.deepStrictEqual(Model.cursorMove(set("", true, 3), 1, 0), { active: true, index: 3, then: "" })
  },
  "moving what is under the cursor stops at the ends"() {
    assert.deepStrictEqual(Model.cursorShift(1, 1, 3), { index: 2, by: 1 })
    assert.deepStrictEqual(Model.cursorShift(2, 1, 3), { index: 2, by: 0 })
    assert.deepStrictEqual(Model.cursorShift(0, -1, 3), { index: 0, by: 0 })
    assert.deepStrictEqual(Model.cursorShift(2, -5, 3), { index: 0, by: -2 })
  },
  "keys in a list: lists move with Shift+arrows or H/L, to-dos with Shift+Up/Down"() {
    assert.strictEqual(Model.specialKey(keyOf({ key: "Left", shift: true })), "listLeft")
    assert.strictEqual(Model.specialKey(keyOf({ text: "L", key: "L", shift: true })), "listRight")
    assert.strictEqual(Model.specialKey(keyOf({ text: "H" })), "listLeft")
    assert.strictEqual(Model.specialKey(keyOf({ key: "Left" })), "")
    assert.strictEqual(Model.specialKey(keyOf({ key: "F2" })), "renameList")
    assert.strictEqual(Model.specialKey(keyOf({ key: "L", text: "\f", ctrl: true })), "lockNow")
    assert.strictEqual(Model.specialKey(keyOf({ key: "Up", shift: true, hasItem: true })), "itemUp")
    assert.strictEqual(Model.specialKey(keyOf({ key: "Down", shift: true, hasItem: true })), "itemDown")
    assert.strictEqual(Model.specialKey(keyOf({ key: "Down", shift: true })), "")
  },
  "keys typed in a field are text, except where typing has no use for them"() {
    assert.strictEqual(Model.specialKey(keyOf({ text: "H", field: "" })), "")
    assert.strictEqual(Model.specialKey(keyOf({ text: "L", key: "L", shift: true, field: "milk" })), "")
    assert.strictEqual(Model.specialKey(keyOf({ key: "Left", shift: true, field: "milk" })), "")
    assert.strictEqual(Model.specialKey(keyOf({ key: "Left", shift: true, field: "" })), "listLeft")
    assert.strictEqual(Model.specialKey(keyOf({ key: "Up", shift: true, hasItem: true, field: "" })), "")
    assert.strictEqual(Model.specialKey(keyOf({ key: "F2", field: "milk" })), "renameList")
    assert.strictEqual(Model.specialKey(keyOf({ key: "L", ctrl: true, field: "milk" })), "lockNow")
  },
  "keys on the Lists screen: J/K and Shift+Up/Down move the list, F2 renames it"() {
    const lists = extra => keyOf(Object.assign({ view: "lists", hasList: true }, extra))
    assert.strictEqual(Model.specialKey(lists({ text: "K" })), "rowUp")
    assert.strictEqual(Model.specialKey(lists({ key: "Down", shift: true })), "rowDown")
    assert.strictEqual(Model.specialKey(lists({ key: "F2" })), "renameRow")
    assert.strictEqual(Model.specialKey(lists({ key: "F2", hasList: false })), "")
    assert.strictEqual(Model.specialKey(lists({ text: "J", field: "" })), "")
    assert.strictEqual(Model.specialKey(keyOf({ view: "settings", text: "J" })), "")
  },
  "a field takes one line, no control characters, and only as much as it holds"() {
    assert.strictEqual(Model.fieldText("a\tb\u0007c", 10), "abc")
    assert.strictEqual(Model.fieldText("😀😀😀", 2), "😀😀")
    assert.strictEqual(Model.fieldText(null, 5), "")
    assert.strictEqual(Model.pastedText("first\nsecond", 50), "first")
    assert.strictEqual(Model.pastedText("one\r\ntwo", 50), "one")
    assert.strictEqual(Model.pastedText("cut�", 50), "cut")
    assert.strictEqual(Model.pastedText("abcdef", 3), "abc")
    assert.strictEqual(Model.pastedText("abc", -2), "")
  },
  "tab labels: the count shown, a long name cut to fit"() {
    assert.strictEqual(Model.tabLabel({ label: "Work", count: 3 }), "Work (3)")
    assert.strictEqual(Model.tabLabel({ label: "Work", count: 0 }), "Work")
    assert.strictEqual(Model.shortLabel({ label: "Groceries for the week", count: 12 }, 100, 10), "Groc… (12)")
    assert.strictEqual(Model.shortLabel({ label: "Home", count: 2 }, 100, 10), "Home (2)")
    assert.strictEqual(Model.shortLabel({ label: "Long name", count: 0 }, 20, 10), "L…")
  },
  "tabs that fit, More for the rest, and the room left shared out"() {
    assert.strictEqual(Model.tabsThatFit([50, 50, 50], 4, 200, 40), 3)
    assert.strictEqual(Model.tabsThatFit([50, 50, 50, 50], 4, 200, 40), 2)
    assert.strictEqual(Model.tabsThatFit([300, 50], 4, 200, 40), 1)
    assert.strictEqual(Model.tabsThatFit([], 4, 200, 40), 0)
    assert.strictEqual(Model.tabExtra([50, 50, 50], 3, 4, 200, 40, false), 14)
    assert.strictEqual(Model.tabExtra([50, 50, 50, 50], 2, 4, 200, 40, true), 17)
    assert.strictEqual(Model.tabExtra([300], 1, 4, 200, 40, false), 0)
  },
})

let failed = 0
for (const [name, test] of Object.entries(tests)) {
  try { test(); console.log("ok   " + name) }
  catch (error) { failed++; console.log("FAIL " + name + "\n     " + String(error.message).split("\n").join("\n     ")) }
}
process.exit(failed ? 1 : 0)
