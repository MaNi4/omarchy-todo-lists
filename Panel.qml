import QtQuick
import Quickshell
import Quickshell.Io
import "Store.js" as Store
import "Hotkey.js" as Hotkey
import "Model.js" as Model
import qs.Ui
import qs.Commons

// To-Do Lists: to-do lists in tabs of your own. Fed by bin/todo-lists, one
// long-lived process that keeps the lists encrypted on disk (and in a
// private GitHub repository, when one is connected) and prints them as a
// JSON line on every change. Service.qml owns that process; this widget
// exists once per monitor and shows it. Theme colours, stock qs.Ui parts.
Panel {
  id: root

  moduleName: "mani4.todo-lists"
  ipcTarget: "mani4.todo-lists"

  readonly property string ff: bar ? bar.fontFamily : Style.font.family
  readonly property color dimForeground: Qt.darker(barForeground, 1.4)
  readonly property color accent: Color.accent

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---------- The store ----------
  // A shell service, not a child of this widget: a Process in here would be
  // one writer per monitor.
  property var service: null

  function bindService() {
    if (service) return
    var host = bar && bar.shell ? bar.shell : null
    var s = host && typeof host.serviceFor === "function" ? host.serviceFor(moduleName) : null
    // A tray drawer hands its widgets a facade without their service; see Store.js.
    if (!s) s = Store.get()
    if (!s) return
    service = s
  }

  // Polled: serviceFor() is a call, so nothing notifies a binding.
  Timer {
    interval: 100
    repeat: true
    running: root.service === null
    triggeredOnStart: true
    onTriggered: root.bindService()
  }

  Connections {
    target: root.service
    function onNotice(n) { root.showNotice(n) }
  }

  function cmd(c) { return service ? service.cmd(c) : false }
  function op(c) { return service ? service.op(c) : false }

  readonly property var status: service ? service.status : ({ state: "loading", lists: [], sync: { state: "off" } })
  // "loading", "setup" (no lists yet), "locked" (the password is needed),
  // "ready" or "error".
  readonly property string storeState: String(status.state || "loading")
  readonly property var lists: status.lists || []
  readonly property var sync: status.sync || ({ state: "off" })
  readonly property string repo: String(status.repo || "")
  // Any answer from the store ends a wait.
  onStatusChanged: {
    busy = false
    // The update is done: its page has nothing left to show.
    if (settingsPage === "update" && !status.legacy) settingsPage = ""
  }
  readonly property int openTotal: lists.reduce(function(n, l) { return n + Number(l.open || 0) }, 0)

  // ---------- Notices ----------
  // The store's answer to a command, shown for a while under the panel's
  // content: a wrong password, a connected repository.
  property var notice: null
  property real noticeSeen: 0
  function showNotice(n) {
    if (!n || Number(n.id) <= noticeSeen) return
    noticeSeen = Number(n.id)
    busy = false
    notice = n
    noticeTimer.restart()
    if (n.ok) connectDone()
  }
  // Set while a command that takes a moment (a password, GitHub) runs.
  property bool busy: false
  Timer {
    id: noticeTimer
    interval: 6000
    onTriggered: root.notice = null
  }
  function say(text) { showNotice({ id: Date.now() * 1000, ok: false, text: text }) }

  // ---------- Views ----------
  property bool configuring: false
  readonly property string view: storeState !== "ready" ? storeState
    : String(status.recovery || "") !== "" ? "recovery"
    : configuring ? "settings" : managing ? "lists" : movingItem !== "" ? "move" : "list"
  // The setup's second way in: lists already kept on GitHub.
  property bool joining: false

  // ---------- The list in view ----------
  property string listId: ""
  readonly property var current: Model.currentList(lists, listId)
  readonly property string currentId: current ? current.id : ""
  onCurrentIdChanged: if (service && currentId !== "") service.lastList = currentId
  // A locked list, not unlocked: its to-dos are not even here.
  readonly property bool currentHidden: !!current && current.locked && !current.unlocked
  readonly property var items: Model.visibleItems(current && current.items ? current.items : [], removing)
  readonly property var openItems: items.filter(function(x) { return !x.done })
  readonly property var doneItems: items.filter(function(x) { return x.done })
  property bool showDone: false

  // Naming a list from the list view: "new" or "rename".
  property string naming: ""
  property string editingItem: ""

  function resetListUi() {
    naming = ""
    armedStale = false
    editingItem = ""
    cursorActive = false
    cursorIndex = 0
  }

  // ---------- The Lists screen ----------
  // Every list in a row, as in Apple's app: a handle to drag it, its name to
  // click and rename, its lock, its bin. One row at a time opens below
  // itself for what needs more (a password, a confirmation).
  property bool managing: false
  property string rowEdit: ""   // the list whose row is open
  property string rowMode: ""   // "rename", "lock", "unlock", "unlocked", "delete"

  function manage(id) {
    flushTicks()
    resetListUi()
    closeRow()
    managing = true
    var ids = lists.map(function(l) { return l.id })
    cursorActive = true
    cursorIndex = Math.max(0, ids.indexOf(id || currentId))
    Qt.callLater(takeKeys)
  }
  function leaveManage() {
    closeRow()
    managing = false
    cursorActive = false
    cursorIndex = 0
    Qt.callLater(focusDefault)
  }
  function openRow(id, mode) {
    rowEdit = id
    rowMode = mode
  }
  function closeRow() {
    rowEdit = ""
    rowMode = ""
  }
  function listById(id) { return Model.listById(lists, id) }
  function lockModeFor(l) { return Model.lockMode(l) }
  function toggleRow(id, mode) {
    if (rowEdit === id && rowMode === mode) closeRow()
    else openRow(id, mode)
  }
  function moveListBy(id, by) {
    if (id) op({ op: "moveList", list: id, by: by })
  }
  function renameListTo(id, name) {
    name = String(name || "").trim()
    var l = listById(id)
    if (l && name !== "" && name !== l.name) op({ op: "renameList", list: id, name: name })
    closeRow()
    takeKeys()
  }
  function setLockFor(id, a, b) {
    var problem = Model.passwordProblem(a, b, 4)
    if (problem) { say(problem); return false }
    busy = true
    cmd({ cmd: "setLock", list: id, password: a })
    closeRow()
    takeKeys()
    return true
  }
  function changeListPasswordFor(id, a, b) {
    var problem = Model.passwordProblem(a, b, 4)
    if (problem) { say(problem); return false }
    busy = true
    cmd({ cmd: "changeListPassword", list: id, password: a })
    closeRow()
    takeKeys()
    return true
  }
  function unlockListFor(id, password) {
    if (password === "") return
    busy = true
    cmd({ cmd: "unlockList", list: id, password: password })
  }
  function removeLockFor(id) {
    cmd({ cmd: "removeLock", list: id })
    closeRow()
    takeKeys()
  }
  function deleteListNow(id) {
    op({ op: "removeList", list: id })
    closeRow()
    takeKeys()
  }
  function addListNamed(name) {
    name = String(name || "").trim()
    if (name === "") return false
    op({ op: "addList", name: name })
    return true
  }

  // keepTyping: switched with Alt+arrows from the field, typing goes on
  // there; a click leaves the field, so the keys are shortcuts again (a
  // locked list's password field takes them either way).
  function selectList(id, keepTyping) {
    if (id === currentId) return
    flushTicks()
    var typing = !!keepTyping && fieldsFocused > 0
    listId = id
    resetListUi()
    Qt.callLater(function() { if (typing) focusAdd(); else focusDefault() })
  }

  function stepList(dx) {
    var id = Model.steppedList(lists, currentId, dx)
    if (id) selectList(id, true)
  }

  // ---------- Ticking ----------
  // A ticked to-do stays where it is for a moment, as in Apple's app,
  // so a slip of the mouse can be taken back; then the store hears of it.
  property var pendingDone: ({})
  function isTicked(it) { return Model.isTicked(pendingDone, it) }
  function tick(it) {
    if (!it || !current) return
    pendingDone = Model.toggled(pendingDone, it, currentId)
    tickTimer.restart()
  }
  Timer {
    id: tickTimer
    interval: 900
    onTriggered: root.flushTicks()
  }
  function flushTicks() {
    tickTimer.stop()
    var due = Model.tickOps(pendingDone)
    pendingDone = ({})
    due.forEach(op)
  }

  // ---------- Actions ----------
  function addItem() {
    var text = addField.text.trim()
    if (text === "" || !current) return
    op({ op: "add", list: currentId, text: text })
    addField.text = ""
    Qt.callLater(function() { listView.contentY = Math.max(0, list.implicitHeight - listView.height) })
  }

  function startEdit(it) {
    if (!it || it.done) return
    flushTicks()
    editingItem = it.id
  }
  function saveEdit(id, text) {
    if (editingItem !== id) return
    editingItem = ""
    var it = items.filter(function(x) { return x.id === id })[0]
    text = String(text || "").trim()
    if (it && text !== "" && text !== it.text) op({ op: "edit", list: currentId, item: id, text: text })
  }

  function removeItem(it) {
    if (it) removeLater([it.id], "Deleted")
  }

  function moveItem(it, by) {
    if (!it || it.done) return
    op({ op: "move", list: currentId, item: it.id, by: by })
    // The cursor goes with it.
    if (cursorItem === "item:" + it.id) cursorIndex = Model.cursorShift(cursorIndex, by, openItems.length).index
  }

  function startNaming(kind) {
    naming = kind
    nameField.text = kind === "rename" && current ? current.name : ""
    Qt.callLater(function() { nameField.input.forceActiveFocus(); nameField.input.cursorPosition = nameField.text.length })
  }
  function saveName() {
    var name = nameField.text.trim()
    if (name === "") { nameField.input.forceActiveFocus(); return }
    if (naming === "new") {
      var before = lists.length
      op({ op: "addList", name: name })
      // The new list is the last one; it is shown when it comes back.
      pendingSelectLast = before
    } else if (current) {
      op({ op: "renameList", list: currentId, name: name })
    }
    naming = ""
    nameField.text = ""
    Qt.callLater(focusDefault)
  }
  property int pendingSelectLast: -1
  onListsChanged: {
    if (pendingSelectLast >= 0 && lists.length > pendingSelectLast) {
      pendingSelectLast = -1
      selectList(lists[lists.length - 1].id)
    }
  }


  function clearDone() {
    var ids = doneItems.map(function(x) { return x.id })
    if (ids.length) removeLater(ids, Model.clearedText(ids.length))
  }

  // ---------- Deleting, with Undo ----------
  // A deleted to-do goes at once; the store hears of it a few seconds later,
  // unless Undo (the notice's button, or u) brings it back.
  property var removing: ({})
  property var lastRemoved: []
  function removeLater(ids, text) {
    removing = Model.withRemoved(removing, ids, currentId)
    lastRemoved = ids
    lastMove = null
    removeTimer.restart()
    showNotice({ id: Date.now() * 1000, ok: true, text: text, undo: true })
  }
  // Undo takes back the last deletion, or the last move.
  readonly property bool canUndo: lastRemoved.length > 0 || lastMove !== null
  function undo() {
    if (lastRemoved.length) {
      removing = Model.withoutRemoved(removing, lastRemoved)
      lastRemoved = []
      notice = null
    } else if (lastMove) {
      var m = lastMove
      lastMove = null
      notice = null
      op({ op: "moveTo", list: m.to, item: m.id, to: m.from, as: Model.freshId(), at: m.at })
    }
  }
  function flushRemovals() {
    removeTimer.stop()
    var due = Model.removeOps(removing)
    removing = ({})
    lastRemoved = []
    if (notice && notice.undo) notice = null
    due.forEach(op)
  }
  Timer {
    id: removeTimer
    interval: 5000
    onTriggered: root.flushRemovals()
  }

  // ---------- Moving a to-do to another list ----------
  property string movingItem: ""
  property var lastMove: null  // { from, to, id, at }: what Undo takes back
  property string movingText: ""
  readonly property var moveRows: Model.moveRows(lists, currentId)
  function startMoving(it) {
    if (!it || moveRows.length === 0) return
    flushTicks()
    movingItem = it.id
    movingText = it.text
    cursorActive = true
    cursorIndex = 0
    Qt.callLater(takeKeys)
  }
  function cancelMoving() {
    movingItem = ""
    movingText = ""
    cursorActive = false
    Qt.callLater(focusDefault)
  }
  // The new record is named here, so Undo can move it back to its place.
  function moveItemTo(row) {
    if (!row || row.off) return
    var id = movingItem
    var from = currentId
    var at = openItems.map(function(x) { return x.id }).indexOf(id)
    var as = Model.freshId()
    cancelMoving()
    if (op({ op: "moveTo", list: from, item: id, to: row.id, as: as })) {
      lastRemoved = []
      lastMove = { from: from, to: row.id, id: as, at: at < 0 ? undefined : at }
      showNotice({ id: Date.now() * 1000, ok: true, text: "Moved to " + row.label, undo: true })
    }
  }

  function unlockList() {
    if (unlockField.text === "" || !current) return
    busy = true
    cmd({ cmd: "unlockList", list: currentId, password: unlockField.text })
    unlockField.text = ""
  }

  property bool armedStale: false
  function openStale() {
    if (staleField.text === "" || !current) return
    busy = true
    cmd({ cmd: "unlockOld", list: currentId, password: staleField.text })
    staleField.text = ""
  }

  function lockNow() {
    cmd({ cmd: "lockLists" })
    resetListUi()
    Qt.callLater(focusDefault)
  }

  // ---------- Setup ----------
  // ---------- Settings pages ----------
  // "" for the list of settings, else the page open: "shortcut", "sync",
  // "password", "recovery", "computer", "keys".
  property string settingsPage: ""
  function onPage(page) { return view === "settings" && settingsPage === page }
  readonly property var settingRows: Model.settingRows({
    legacy: !!status.legacy, hasService: !!service, repo: repo, syncState: String(sync.state || ""),
    boundHotkey: service ? service.boundHotkey : "", hotkeyConflict: service ? service.hotkeyConflict : "",
    remembered: String(status.remembered || "")
  })
  readonly property var lockedNames: lists.filter(function(l) { return l.locked }).map(function(l) { return l.name })
  function finishUpdate() {
    if (updatePw.text === "") { say("Type the master password"); return }
    busy = true
    cmd({ cmd: "upgrade", password: updatePw.text })
    updatePw.text = ""
  }
  function openSettings() {
    resetListUi()
    configuring = true
    settingsPage = ""
    cursorActive = true
    cursorIndex = 0
    Qt.callLater(takeKeys)
  }
  function openSettingsPage(page) {
    settingsPage = page
    cursorActive = false
    cursorIndex = 0
    if (page === "shortcut") {
      if (service) service.refreshBinds()
      hotkeyField.text = ""
      Qt.callLater(function() { hotkeyField.input.forceActiveFocus() })
    } else if (page === "update") Qt.callLater(function() { updatePw.input.forceActiveFocus() })
    else Qt.callLater(takeKeys)
  }
  function settingsBack() {
    if (settingsPage === "") { configuring = false; return }
    var back = Model.rowIndex(settingRows, settingsPage)
    settingsPage = ""
    armedDisconnect = false
    armedForget = false
    takeKeys()
    cursorActive = true
    cursorIndex = back
  }

  // ---------- The shortcut ----------
  // Free keys first, then taken ones with what holds them (Hotkey.js); the
  // field narrows them, or is a combination of its own.
  readonly property var hotkeyChoices: service ? Hotkey.choices(service.bindsJson, hotkeyField.text) : []
  // The picker's rows: the choices, and "No shortcut" while nothing is typed.
  readonly property var pickRows: Model.pickRows(hotkeyChoices, service ? service.boundHotkey : "", hotkeyField.text,
                                                !!service && service.hotkey === "")
  function pickHotkey(row) {
    if (!row || !service) return
    if (row.off) { say(row.label + " " + row.where); return }
    service.setHotkey(row.hotkey)
    hotkeyField.text = ""
    settingsBack()
  }
  // ---------- Recovery and passwords ----------
  property bool recovering: false       // the locked view's "Forgot the password?"
  property bool listRecovering: false   // the same for a locked list

  function recoverAll() {
    var code = recoverCodeField.text.trim()
    if (code === "") { say("Type the recovery key"); return }
    var problem = Model.passwordProblem(recoverPw.text, recoverPw2.text, 12)
    if (problem) { say(problem); return }
    busy = true
    cmd({ cmd: "recover", code: code, password: recoverPw.text })
    recoverPw.text = ""
    recoverPw2.text = ""
  }

  function recoverListNow() {
    var code = listRecCode.text.trim()
    if (code === "" || !current) { say("Type the recovery key"); return }
    var pw = listRecPw.text
    var problem = Model.passwordProblem(pw, listRecPw2.text, 4, true)
    if (problem) { say(problem); return }
    busy = true
    cmd({ cmd: "recoverList", list: currentId, code: code, password: pw })
    listRecPw.text = ""
    listRecPw2.text = ""
  }

  function makeNewRecovery() {
    if (recPwField.text === "") { say("Type the master password"); return }
    busy = true
    cmd({ cmd: "newRecovery", password: recPwField.text })
    recPwField.text = ""
  }

  function changeMasterPassword() {
    if (currentPw.text === "") { say("Type the current master password"); return }
    var problem = Model.passwordProblem(newPw.text, newPw2.text, 12)
    if (problem) { say(problem); return }
    busy = true
    cmd({ cmd: "changePassword", old: currentPw.text, password: newPw.text })
    currentPw.text = ""
    newPw.text = ""
    newPw2.text = ""
  }

  // The recovery key to the clipboard: on wl-copy's stdin, never in its
  // arguments, marked sensitive (clipboard managers keep no copy), and the
  // clipboard cleared a minute later.
  Process {
    id: copier
    command: ["wl-copy", "--sensitive"]
    stdinEnabled: true
    property string payload: ""
    onStarted: { write(payload); stdinEnabled = false }
    onExited: { payload = ""; stdinEnabled = true }
  }
  function copyRecovery() {
    if (copier.running) return
    copier.payload = String(status.recovery || "")
    copier.running = true
    clipboardClear.restart()
    showNotice({ id: Date.now() * 1000, ok: true, text: "Copied; the clipboard is cleared in a minute" })
  }
  Timer {
    id: clipboardClear
    interval: 60000
    onTriggered: Quickshell.execDetached(["wl-copy", "--clear"])
  }

  function createLists() {
    var problem = Model.passwordProblem(newField.text, newAgainField.text, 12)
    if (problem) { say(problem); return }
    busy = true
    cmd({ cmd: "create", password: newField.text })
    newField.text = ""
    newAgainField.text = ""
  }

  function unlockAll() {
    if (masterField.text === "") return
    busy = true
    cmd({ cmd: "unlock", password: masterField.text })
    masterField.text = ""
  }

  // From the setup (with the password) or the settings (without).
  function connectRepo(fromSetup) {
    var repoText = (fromSetup ? joinRepoField : repoField).text.trim()
    var token = (fromSetup ? joinTokenField : tokenField).text.trim()
    if (repoText === "") { say("Repository: owner/name"); return }
    if (token === "") { say("Paste a GitHub token"); return }
    var c = { cmd: "connect", repo: repoText, token: token }
    if (fromSetup) {
      if (joinPasswordField.text.length < 1) { say("Type the master password"); return }
      c.password = joinPasswordField.text
    }
    busy = true
    cmd(c)
  }
  // Secrets typed for a connection go once it worked.
  function connectDone() {
    recoverCodeField.text = ""
    listRecCode.text = ""
    recovering = false
    tokenField.text = ""
    joinTokenField.text = ""
    joinPasswordField.text = ""
  }

  property bool armedDisconnect: false
  property bool armedForget: false

  // Kept fresh by the clock, so "2 min ago" moves on while the panel is open.
  property real nowSeconds: Date.now() / 1000
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowSeconds = Date.now() / 1000
  }
  readonly property string syncText: Model.syncText(sync, repo, nowSeconds)
  readonly property string syncIcon: Model.syncIcon(sync.state)

  // ---------- Opening and closing ----------
  onOpenedChanged: {
    if (opened) {
      nowSeconds = Date.now() / 1000
      if (service && service.lastList) listId = service.lastList
      // From the "no key" notification: straight to the shortcut setting.
      if (service && service.wantShortcutSetup) {
        service.wantShortcutSetup = false
        if (storeState === "ready") { openSettings(); openSettingsPage("shortcut") }
      }
      notice = null
      if (repo !== "") cmd({ cmd: "sync" })
    } else {
      flushTicks()
      flushRemovals()
      movingItem = ""
      // Locked lists lock again when the panel closes.
      cmd({ cmd: "lockLists" })
      configuring = false
      settingsPage = ""
      managing = false
      closeRow()
      joining = false
      armedDisconnect = false
      armedForget = false
      resetListUi()
      hotkeyField.text = ""
      for (var f of [newField, newAgainField, masterField, unlockField, staleField, tokenField, joinTokenField, joinPasswordField,
                     recoverCodeField, recoverPw, recoverPw2, listRecCode, listRecPw, listRecPw2, currentPw, newPw, newPw2, recPwField, updatePw])
        f.text = ""
      recovering = false
      listRecovering = false
    }
  }

  // Where typing goes when the panel opens or the view changes.
  readonly property Item defaultFocus: view === "setup" ? (joining ? joinRepoField.input : newField.input)
    : view === "locked" ? masterField.input
    : view === "list" && currentHidden ? unlockField.input
    : keyTarget
  // The add field, taken on purpose: a click, Enter, n, a, /, or up from
  // the first to-do. It is not taken on opening, so keys are shortcuts
  // until then.
  function focusAdd() {
    if (opened && view === "list" && !currentHidden) addField.input.forceActiveFocus()
    else focusDefault()
  }
  function focusDefault() {
    if (opened && defaultFocus) defaultFocus.forceActiveFocus()
  }
  onViewChanged: {
    if (view === "settings" && service) service.refreshBinds()
    Qt.callLater(focusDefault)
  }
  onCurrentHiddenChanged: {
    if (!currentHidden) listRecovering = false
    Qt.callLater(focusDefault)
  }

  // The keys back from a field to the panel's cursor.
  function takeKeys() { keyTarget.forceActiveFocus() }

  // ---------- Keyboard cursor ----------
  property bool cursorActive: false
  property int cursorIndex: 0
  property int fieldsFocused: 0
  readonly property var focusItems: Model.focusItems({
    view: view, settingsPage: settingsPage, settingRows: settingRows, pickRows: pickRows, moveRows: moveRows, lists: lists,
    openItems: openItems, doneItems: doneItems, showDone: showDone, hidden: currentHidden
  })
  readonly property string cursorItem: cursorActive && cursorIndex < focusItems.length ? focusItems[cursorIndex] : ""
  onFocusItemsChanged: if (cursorIndex >= focusItems.length) cursorIndex = Math.max(0, focusItems.length - 1)
  function hasCursor(key) { return cursorItem === key }
  function itemAt(key) {
    if (key.indexOf("item:") !== 0) return null
    var id = key.substring(5)
    return items.filter(function(x) { return x.id === id })[0] || null
  }

  function moveCursor(dx, dy) {
    var to = Model.cursorMove({ view: view, settingsPage: settingsPage, active: cursorActive, index: cursorIndex,
                                count: focusItems.length }, dx, dy)
    if (to.then === "step") { stepList(dx); return }
    cursorActive = to.active
    cursorIndex = to.index
    if (to.then === "hotkeyField") hotkeyField.input.forceActiveFocus()
    else if (to.then === "newList") newListField.input.forceActiveFocus()
    else if (to.then === "add") focusAdd()
  }

  // The list under the Lists screen's cursor.
  readonly property string cursorList: cursorItem.indexOf("list:") === 0 ? cursorItem.substring(5) : ""
  // Shift+arrows (or J/K) on the Lists screen: the list moves, the cursor
  // with it.
  function moveCursorList(by) {
    if (cursorList === "") return
    var to = Model.cursorShift(cursorIndex, by, lists.length)
    if (to.by === 0) return
    moveListBy(cursorList, to.by)
    cursorIndex = to.index
  }

  // Keys the panel's catcher does not tell apart (it sees Shift+Left as
  // Left), taken before it: moving a list, renaming it, locking.
  // From a field (the add field), only what typing has no use for: Shift
  // with an arrow while the field is empty, F2, Ctrl+L.
  function specialKey(event, field) {
    var key = event.key === Qt.Key_Left ? "Left" : event.key === Qt.Key_Right ? "Right" : event.key === Qt.Key_Up ? "Up"
      : event.key === Qt.Key_Down ? "Down" : event.key === Qt.Key_F2 ? "F2" : event.key === Qt.Key_L ? "L" : ""
    var action = Model.specialKey({
      view: view, key: key, text: event.text, field: field ? field.text : null,
      shift: (event.modifiers & Qt.ShiftModifier) !== 0, ctrl: (event.modifiers & Qt.ControlModifier) !== 0,
      hasItem: !!itemAt(cursorItem), hasList: cursorList !== ""
    })
    if (action === "listLeft") moveListBy(currentId, -1)
    else if (action === "listRight") moveListBy(currentId, 1)
    else if (action === "renameList") startNaming("rename")
    else if (action === "lockNow") lockNow()
    else if (action === "itemUp" || action === "itemDown") moveItem(itemAt(cursorItem), action === "itemUp" ? -1 : 1)
    else if (action === "rowUp") moveCursorList(-1)
    else if (action === "rowDown") moveCursorList(1)
    else if (action === "renameRow") openRow(cursorList, "rename")
    return action !== ""
  }

  function activate(key) {
    var k = Model.cursorKey(key)
    if (k.kind === "set") openSettingsPage(k.id)
    else if (k.kind === "pick") pickHotkey(pickRows[Number(k.id)])
    else if (k.kind === "list") openRow(k.id, "rename")
    else if (k.kind === "new") newListField.input.forceActiveFocus()
    else if (k.kind === "completed") showDone = !showDone
    else if (k.kind === "to") moveItemTo(moveRows.filter(function(r) { return r.id === k.id })[0])
    else if (k.kind === "item") { var it = itemAt(key); if (it) tick(it) }
  }

  // ---------- Typing ----------
  // The fields are TextEdits, not TextFields: a TextField asks the clipboard
  // for its whole text whenever the clipboard changes, to know whether Paste
  // could be offered. Pasting goes through paste() instead, which reads no
  // more of the clipboard than a field can take; Ctrl+V and Shift+Insert are
  // taken before the field sees them, and the middle and right buttons are
  // swallowed.
  function fieldText(text, max) { return Model.fieldText(text, max) }

  property var pasteTarget: null
  property int pasteRoom: 0
  function paste(target, room) {
    if (paster.running) return
    pasteTarget = target
    pasteRoom = room
    paster.running = true
  }

  function finishPaste(raw) {
    var target = pasteTarget
    pasteTarget = null
    if (!target || !opened || !target.activeFocus) return
    target.remove(target.selectionStart, target.selectionEnd)
    var text = Model.pastedText(raw, pasteRoom - Array.from(target.text).length)
    if (text !== "") target.insert(target.cursorPosition, text)
  }

  Process {
    id: paster
    command: ["sh", "-c", "timeout 2 wl-paste --no-newline 2>/dev/null | head -c 1024"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishPaste(text)
    }
  }

  // ---------- Bar icon ----------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\u{f0756}" // nf-md-format-list-checks
    dimmed: root.storeState === "ready" && root.openTotal === 0
    tooltipText: root.storeState === "locked" ? "To-Do Lists \u00b7 locked"
      : root.storeState !== "ready" ? "To-Do Lists"
      : root.openTotal === 0 ? "To-Do Lists \u00b7 nothing to do"
      : "To-Do Lists \u00b7 " + root.openTotal + " to do"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.cmd({ cmd: "sync" })
      else root.toggle()
    }
  }

  // ---------- Pieces ----------
  // A one-line field, a TextEdit held to one line (see Typing). It hands the
  // keys that end typing to whoever uses it, as signals.
  component LineField: BorderSurface {
    id: line
    property alias text: input.text
    property alias input: input
    property string placeholderText: ""
    property int maximumLength: 500
    property bool hasCursor: false
    // Panel shortcuts that typing has no use for (see specialKey) work here.
    property bool panelKeys: false
    signal edited()
    signal finished()
    signal escaped()
    signal entered()
    signal steppedDown()
    signal switchedList(int dx)

    readonly property var spec: Border.controlSpec(input.activeFocus ? "focus" : (lineHover.hovered || hasCursor ? "hover-cursor" : "normal"),
      root.barForeground, root.accent)
    implicitWidth: Style.spacing.numberFieldWidth
    implicitHeight: Math.max(Style.spacing.controlHeight, root.controlHeight, input.implicitHeight + (Style.spacing.controlPaddingY + Border.top(spec)) * 2)
    color: Style.controlFill(input.activeFocus, lineHover.hovered || hasCursor, root.barForeground, root.accent)
    borderSpec: spec
    radius: Style.cornerRadius

    HoverHandler {
      id: lineHover
      cursorShape: Qt.IBeamCursor
    }

    TextEdit {
      id: input
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.controlPaddingX + Border.left(line.spec)
      anchors.rightMargin: Style.spacing.controlPaddingX + Border.right(line.spec)
      textFormat: TextEdit.PlainText
      wrapMode: TextEdit.NoWrap
      clip: true
      selectByMouse: true
      color: root.barForeground
      selectionColor: Style.selectionFillFor(root.barForeground, root.accent)
      selectedTextColor: root.barForeground
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall

      onTextChanged: {
        var kept = root.fieldText(text, line.maximumLength)
        if (kept === text) {
          line.edited()
          return
        }
        var at = cursorPosition
        text = kept
        cursorPosition = Math.min(at, kept.length)
      }
      onActiveFocusChanged: {
        root.fieldsFocused = Math.max(0, root.fieldsFocused + (activeFocus ? 1 : -1))
        if (!activeFocus) line.finished()
      }
      Component.onDestruction: if (activeFocus) root.fieldsFocused = Math.max(0, root.fieldsFocused - 1)

      Keys.onPressed: function(event) {
        var alt = (event.modifiers & Qt.AltModifier) !== 0
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        if (line.panelKeys && root.specialKey(event, input)) {
          event.accepted = true
        } else if (event.matches(StandardKey.Paste)) {
          event.accepted = true
          root.paste(input, line.maximumLength)
        } else if (event.key === Qt.Key_Escape) {
          event.accepted = true
          line.escaped()
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          event.accepted = true
          line.entered()
        } else if (event.key === Qt.Key_Down) {
          event.accepted = true
          line.steppedDown()
        } else if ((alt && (event.key === Qt.Key_Left || event.key === Qt.Key_Right))
            || (ctrl && (event.key === Qt.Key_PageUp || event.key === Qt.Key_PageDown))) {
          event.accepted = true
          line.switchedList(event.key === Qt.Key_Left || event.key === Qt.Key_PageUp ? -1 : 1)
        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          event.accepted = true
          root.takeKeys()
        }
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.MiddleButton | Qt.RightButton
        onPressed: function(mouse) { mouse.accepted = true }
        onReleased: function(mouse) { mouse.accepted = true }
      }
    }

    Text {
      visible: input.length === 0
      anchors.left: input.left
      anchors.right: input.right
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      elide: Text.ElideRight
      text: line.placeholderText
      color: root.dimForeground
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
    }
  }

  // A password field: the keys are taken one by one into a string and only
  // dots are drawn. No text item holds the password, nothing reads the
  // clipboard but paste(), and the text is cleared once it is sent.
  component PasswordField: BorderSurface {
    id: pw
    property string text: ""
    property alias input: catcher
    property string placeholderText: "Password"
    property int maximumLength: 256
    signal entered()
    signal escaped()

    readonly property var spec: Border.controlSpec(catcher.activeFocus ? "focus" : (pwHover.hovered ? "hover-cursor" : "normal"),
      root.barForeground, root.accent)
    implicitWidth: Style.spacing.numberFieldWidth
    implicitHeight: Math.max(Style.spacing.controlHeight, root.controlHeight, dots.implicitHeight + (Style.spacing.controlPaddingY + Border.top(spec)) * 2)
    color: Style.controlFill(catcher.activeFocus, pwHover.hovered, root.barForeground, root.accent)
    borderSpec: spec
    radius: Style.cornerRadius

    HoverHandler {
      id: pwHover
      cursorShape: Qt.IBeamCursor
    }

    // What paste() needs of a field.
    Item {
      id: catcher
      anchors.fill: parent
      readonly property string text: pw.text
      readonly property int selectionStart: pw.text.length
      readonly property int selectionEnd: pw.text.length
      readonly property int cursorPosition: pw.text.length
      function remove(a, b) { }
      function insert(at, t) { pw.text = (pw.text + t).substring(0, pw.maximumLength) }

      onActiveFocusChanged: root.fieldsFocused = Math.max(0, root.fieldsFocused + (activeFocus ? 1 : -1))
      Component.onDestruction: if (activeFocus) root.fieldsFocused = Math.max(0, root.fieldsFocused - 1)

      Keys.onPressed: function(event) {
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        var alt = (event.modifiers & Qt.AltModifier) !== 0
        event.accepted = true
        if (event.matches(StandardKey.Paste)) root.paste(catcher, pw.maximumLength)
        else if (event.key === Qt.Key_Escape) pw.escaped()
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) pw.entered()
        else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) root.takeKeys()
        else if (event.key === Qt.Key_Backspace) pw.text = ctrl ? "" : Array.from(pw.text).slice(0, -1).join("")
        else if (!ctrl && !alt && event.text.length > 0 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127)
          pw.text = (pw.text + event.text).substring(0, pw.maximumLength)
        else event.accepted = false
      }
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
      cursorShape: Qt.IBeamCursor
      onPressed: function(mouse) { mouse.accepted = true; catcher.forceActiveFocus() }
    }

    Text {
      id: dots
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.controlPaddingX + Border.left(pw.spec)
      anchors.rightMargin: Style.spacing.controlPaddingX + Border.right(pw.spec)
      textFormat: Text.PlainText
      elide: Text.ElideLeft
      text: pw.text.length ? "•".repeat(Math.min(64, Array.from(pw.text).length)) + (catcher.activeFocus ? "▏" : "")
        : catcher.activeFocus ? "▏" : pw.placeholderText
      color: pw.text.length ? root.barForeground : catcher.activeFocus ? root.accent : root.dimForeground
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
    }
  }

  // Fields are as tall as the buttons beside them.
  readonly property real controlHeight: buttonMeasure.implicitHeight

  // A row of the settings list: what it is, what it does, its value (a
  // shortcut as key caps), and a chevron to its page.
  component SettingRow: Rectangle {
    id: srow
    property var row: ({})
    property bool hasCursor: false
    signal clicked()
    width: parent ? parent.width : 0
    implicitHeight: Math.max(root.controlHeight, sLabel.implicitHeight + Style.spacing.controlPaddingY * 2)
    radius: Style.space(4)
    color: sMouse.containsMouse || hasCursor ? Style.hoverFillFor(root.barForeground, root.accent) : "transparent"

    Text {
      id: sLabel
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.controlPaddingX
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: String(srow.row.label || "")
      color: root.barForeground
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      anchors.left: sLabel.right
      anchors.leftMargin: Style.space(8)
      anchors.right: sValue.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      elide: Text.ElideRight
      text: String(srow.row.where || "")
      color: srow.row.urgent ? Color.urgent : root.dimForeground
      font.family: root.ff
      font.pixelSize: Style.font.caption
    }
    Row {
      id: sValue
      anchors.right: sChevron.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)
      Repeater {
        model: srow.row.keys ? String(srow.row.keys).split(" + ") : []
        KeyCap { required property var modelData; text: modelData }
      }
      Text {
        visible: !srow.row.keys && !!srow.row.value
        textFormat: Text.PlainText
        text: String(srow.row.value || "")
        color: root.dimForeground
        font.family: root.ff
        font.pixelSize: Style.font.caption
      }
    }
    Text {
      id: sChevron
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: "\u{f0142}" // nf-md-chevron-right
      color: root.dimForeground
      font.family: root.ff
      font.pixelSize: Style.font.icon
    }
    MouseArea {
      id: sMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: srow.clicked()
    }
  }

  // A key of a shortcut, as on the keyboard.
  component KeyCap: Rectangle {
    property alias text: capText.text
    implicitWidth: capText.implicitWidth + Style.space(8)
    implicitHeight: capText.implicitHeight + Style.space(4)
    radius: Style.space(3)
    color: "transparent"
    border.width: 1
    border.color: root.dimForeground
    Text {
      id: capText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      color: root.barForeground
      font.family: root.ff
      font.pixelSize: Style.font.caption
    }
  }

  // A key to choose: a check on the one in use, "free" or what holds it.
  component PickRow: Rectangle {
    id: prow
    property var row: ({})
    property bool hasCursor: false
    signal clicked()
    width: parent ? parent.width : 0
    implicitHeight: Math.max(root.controlHeight, pLabel.implicitHeight + Style.spacing.controlPaddingY * 2)
    radius: Style.space(4)
    color: !prow.row.off && (pMouse.containsMouse || hasCursor) ? Style.hoverFillFor(root.barForeground, root.accent) : "transparent"

    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.controlPaddingX
      anchors.verticalCenter: parent.verticalCenter
      visible: !!prow.row.on
      textFormat: Text.PlainText
      text: "\u{f012c}" // nf-md-check
      color: root.accent
      font.family: root.ff
      font.pixelSize: Style.font.icon
    }
    Text {
      id: pLabel
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.controlPaddingX + Style.space(22)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: String(prow.row.label || "")
      color: prow.row.off ? root.dimForeground : prow.row.on ? root.accent : root.barForeground
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
      font.bold: !!prow.row.on
    }
    Text {
      anchors.left: pLabel.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.controlPaddingX
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      elide: Text.ElideRight
      text: String(prow.row.where || "")
      color: root.dimForeground
      font.family: root.ff
      font.pixelSize: Style.font.caption
    }
    MouseArea {
      id: pMouse
      anchors.fill: parent
      enabled: !prow.row.off
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: prow.clicked()
    }
  }

  // A plain button in the panel's style.
  component PanelButton: Button {
    // One height for every button, with an icon or without, and the fields.
    height: root.controlHeight
    fontSize: Style.font.bodySmall
    foreground: root.barForeground
    fontFamily: root.ff
    bordered: true
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY
  }

  component Note: Text {
    width: parent ? parent.width : 0
    leftPadding: Style.spacing.controlPaddingX
    rightPadding: Style.spacing.controlPaddingX
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: root.dimForeground
    font.family: root.ff
    font.pixelSize: Style.font.caption
  }

  component HelpRow: Item {
    id: help
    property string key: ""
    property string meaning: ""
    width: parent ? parent.width : 0
    implicitHeight: Math.max(helpKey.implicitHeight, helpMeaning.implicitHeight)

    Text {
      id: helpKey
      x: Style.spacing.controlPaddingX
      width: Math.round(help.width * 0.36) - x
      textFormat: Text.PlainText
      text: help.key
      elide: Text.ElideRight
      color: root.accent
      font.family: root.ff
      font.pixelSize: Style.font.caption
    }

    Text {
      id: helpMeaning
      anchors.left: helpKey.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.controlPaddingX
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: help.meaning
      color: root.barForeground
      font.family: root.ff
      font.pixelSize: Style.font.caption
    }
  }

  // A to-do: a circle and its text, either of which ticks it; on the one
  // under the pointer (or the cursor), a pencil that edits it and a cross
  // that removes it. The two always keep their room, so the text does not
  // move when they show, and they sit on the middle of its first line.
  component ItemRow: Rectangle {
    id: row
    property var item: ({})
    property bool hasCursor: false
    readonly property bool ticked: root.isTicked(item)
    readonly property bool editing: root.editingItem !== "" && root.editingItem === item.id
    readonly property bool hot: rowHover.hovered || hasCursor
    readonly property real padY: Style.spacing.controlPaddingY
    // The first line: as tall as the tallest of circle, text and buttons.
    readonly property real lineHeight: Math.max(circle.implicitHeight, lineMetric.implicitHeight, actions.implicitHeight)

    width: parent ? parent.width : 0
    implicitHeight: (editing ? Math.max(lineHeight, editor.implicitHeight)
      : Math.max(lineHeight, label.implicitHeight + (lineHeight - lineMetric.implicitHeight) / 2)) + padY * 2
    radius: Style.space(4)
    color: (hot || dragging) && !editing ? Style.hoverFillFor(root.barForeground, root.accent) : "transparent"

    HoverHandler { id: rowHover }

    // A click anywhere on the row but its buttons ticks it (and leaves the
    // field, so the keys are shortcuts again). Pressed and moved, an open
    // to-do is dragged to another place instead.
    property real dragOffset: 0
    property bool dragging: false
    z: dragging ? 10 : 0
    transform: Translate { y: row.dragOffset }

    MouseArea {
      anchors.fill: parent
      enabled: !row.editing
      // The list's scrolling does not take a drag over.
      preventStealing: !row.item.done
      cursorShape: row.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
      property real startY: 0
      property bool moved: false
      onPressed: function(m) { startY = mapToItem(null, m.x, m.y).y; moved = false }
      onPositionChanged: function(m) {
        if (!pressed || row.item.done) return
        var dy = mapToItem(null, m.x, m.y).y - startY
        if (!row.dragging && Math.abs(dy) > Style.space(6)) { row.dragging = true; moved = true }
        if (row.dragging) row.dragOffset = dy
      }
      onReleased: {
        if (row.dragging) {
          var by = Math.round(row.dragOffset / (row.height + Style.space(1)))
          row.dragOffset = 0
          row.dragging = false
          if (by !== 0) root.moveItem(row.item, by)
          return
        }
        if (!moved) { root.takeKeys(); root.tick(row.item) }
      }
      onCanceled: { row.dragOffset = 0; row.dragging = false }
    }

    Text {
      id: lineMetric
      visible: false
      textFormat: Text.PlainText
      text: "M"
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: circle
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.controlPaddingX
      y: row.padY + (row.lineHeight - implicitHeight) / 2
      textFormat: Text.PlainText
      text: row.ticked ? "\u{f0133}" : "\u{f0130}" // nf-md-checkbox-marked-circle(-outline)
      color: row.ticked ? root.accent : row.hot ? root.barForeground : root.dimForeground
      font.family: root.ff
      font.pixelSize: Style.font.icon
    }

    Text {
      id: label
      visible: !row.editing
      anchors.left: circle.right
      anchors.leftMargin: Style.space(10)
      anchors.right: actions.left
      anchors.rightMargin: Style.space(4)
      y: row.padY + (row.lineHeight - lineMetric.implicitHeight) / 2
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      text: String(row.item.text || "")
      color: row.ticked ? root.dimForeground : root.barForeground
      font.family: root.ff
      font.pixelSize: Style.font.bodySmall
      font.strikeout: !!row.item.done
    }

    LineField {
      id: editor
      visible: row.editing
      anchors.left: circle.right
      anchors.leftMargin: Style.space(6)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(2)
      y: row.padY + (row.lineHeight - height) / 2
      onEntered: { root.saveEdit(row.item.id, text); root.takeKeys() }
      onEscaped: { root.editingItem = ""; root.takeKeys() }
      onFinished: root.saveEdit(row.item.id, text)
    }

    function beginEdit() {
      editor.text = String(item.text || "")
      Qt.callLater(function() { editor.input.forceActiveFocus(); editor.input.cursorPosition = editor.text.length })
    }
    onEditingChanged: if (editing) beginEdit()
    Component.onCompleted: if (editing) beginEdit()

    Row {
      id: actions
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      y: row.padY + (row.lineHeight - implicitHeight) / 2
      spacing: Style.space(2)
      visible: !row.editing
      opacity: row.hot ? 1 : 0

      PanelActionButton {
        visible: root.moveRows.length > 0
        enabled: row.hot
        iconText: "\u{f0054}" // nf-md-arrow_right
        tooltipText: "Move to another list (t)"
        foreground: root.dimForeground
        hoverColor: root.barForeground
        fontFamily: root.ff
        onClicked: root.startMoving(row.item)
      }

      PanelActionButton {
        // A ticked to-do is not edited; its place stays, so the cross
        // does not move.
        opacity: row.item.done ? 0 : 1
        enabled: row.hot && !row.item.done
        iconText: "\u{f03eb}" // nf-md-pencil
        tooltipText: "Edit (e)"
        foreground: root.dimForeground
        hoverColor: root.barForeground
        fontFamily: root.ff
        onClicked: root.startEdit(row.item)
      }

      PanelActionButton {
        enabled: row.hot
        iconText: "\u{f0156}" // nf-md-close
        tooltipText: "Remove (x)"
        foreground: root.dimForeground
        hoverColor: Color.urgent
        fontFamily: root.ff
        onClicked: root.removeItem(row.item)
      }
    }
  }

  // A row of the Lists screen. The fields it opens below itself are its
  // own; they empty whenever the row closes.
  component ListRow: Column {
    id: lrow
    property var list: ({})
    property bool hasCursor: false
    readonly property bool isOpen: root.rowEdit !== "" && root.rowEdit === list.id
    readonly property string mode: isOpen ? root.rowMode : ""
    readonly property bool hidden: !!list.locked && !list.unlocked
    readonly property bool nowUnlocked: !!list.unlocked
    property real dragOffset: 0
    property bool dragging: false

    width: parent ? parent.width : 0
    spacing: Style.space(4)
    z: dragging ? 10 : 0
    transform: Translate { y: lrow.dragOffset }

    function focusMode() {
      if (mode === "rename") { renameField.text = String(list.name || ""); renameField.input.forceActiveFocus(); renameField.input.cursorPosition = renameField.text.length }
      else if (mode === "lock") lockA.input.forceActiveFocus()
      else if (mode === "unlock") unlockB.input.forceActiveFocus()
      else if (mode === "repass") repassA.input.forceActiveFocus()
    }
    onModeChanged: {
      renameField.text = ""
      lockA.text = ""
      lockB.text = ""
      unlockB.text = ""
      repassA.text = ""
      repassB.text = ""
      if (mode !== "") Qt.callLater(focusMode)
    }
    // Unlocked from its row: the row closes, or goes on to what was asked.
    onNowUnlockedChanged: if (nowUnlocked && mode === "unlock") root.closeRow()

    Rectangle {
      id: line
      width: parent.width
      implicitHeight: Math.max(root.controlHeight, nameText.implicitHeight + Style.spacing.controlPaddingY * 2)
      radius: Style.space(4)
      color: lineHover.hovered || lrow.hasCursor || lrow.dragging || lrow.isOpen ? Style.hoverFillFor(root.barForeground, root.accent) : "transparent"

      HoverHandler { id: lineHover }

      Text {
        id: handle
        anchors.left: parent.left
        anchors.leftMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "\u{f01dd}" // nf-md-drag-vertical
        color: dragArea.containsMouse || lrow.dragging ? root.barForeground : root.dimForeground
        font.family: root.ff
        font.pixelSize: Style.font.icon

        MouseArea {
          id: dragArea
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          preventStealing: true
          cursorShape: lrow.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
          property real startY: 0
          onPressed: function(m) { startY = mapToItem(null, m.x, m.y).y; lrow.dragging = true }
          onPositionChanged: function(m) { if (pressed) lrow.dragOffset = mapToItem(null, m.x, m.y).y - startY }
          onReleased: {
            var step = line.height + listsColumn.spacing
            var by = Math.round(lrow.dragOffset / step)
            lrow.dragOffset = 0
            lrow.dragging = false
            if (by !== 0) root.moveListBy(lrow.list.id, by)
          }
          onCanceled: { lrow.dragOffset = 0; lrow.dragging = false }
        }
      }

      Text {
        id: nameText
        visible: lrow.mode !== "rename"
        anchors.left: handle.right
        anchors.leftMargin: Style.space(8)
        anchors.right: countText.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: String(lrow.list.name || "")
        color: root.currentId === lrow.list.id ? root.accent : root.barForeground
        font.family: root.ff
        font.pixelSize: Style.font.bodySmall
        font.bold: root.currentId === lrow.list.id

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.IBeamCursor
          onClicked: root.openRow(lrow.list.id, "rename")
        }
      }

      LineField {
        id: renameField
        visible: lrow.mode === "rename"
        anchors.left: handle.right
        anchors.leftMargin: Style.space(4)
        anchors.right: buttons.left
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        maximumLength: 60
        onEntered: root.renameListTo(lrow.list.id, text)
        onEscaped: { root.closeRow(); root.takeKeys() }
        onFinished: if (lrow.mode === "rename") root.renameListTo(lrow.list.id, text)
      }

      Text {
        id: countText
        visible: lrow.mode !== "rename"
        anchors.right: buttons.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: lrow.hidden || !lrow.list.open ? "" : String(lrow.list.open)
        color: root.dimForeground
        font.family: root.ff
        font.pixelSize: Style.font.caption
      }

      Row {
        id: buttons
        anchors.right: parent.right
        anchors.rightMargin: Style.space(2)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        PanelActionButton {
          iconText: !lrow.list.locked ? "\u{f0340}" : lrow.list.unlocked ? "\u{f0fc7}" : "\u{f033e}"
          tooltipText: !lrow.list.locked ? "Lock with a list password (p)" : lrow.list.unlocked ? "Unlocked: lock again or remove the lock (p)" : "Locked: unlock (p)"
          foreground: lrow.list.locked ? root.accent : root.dimForeground
          hoverColor: root.barForeground
          fontFamily: root.ff
          onClicked: root.toggleRow(lrow.list.id, root.lockModeFor(lrow.list))
        }
        PanelActionButton {
          iconText: "\u{f0a7a}" // nf-md-trash-can-outline
          tooltipText: lrow.hidden ? "Unlock it to delete it" : "Delete the list (x)"
          foreground: root.dimForeground
          hoverColor: Color.urgent
          fontFamily: root.ff
          onClicked: root.toggleRow(lrow.list.id, lrow.hidden ? "unlock" : "delete")
        }
      }
    }

    // ----- what the row opens -----
    Column {
      visible: lrow.mode === "lock" || lrow.mode === "unlock" || lrow.mode === "unlocked" || lrow.mode === "repass" || lrow.mode === "delete"
      width: parent.width
      leftPadding: Style.space(28)
      rightPadding: Style.space(4)
      bottomPadding: Style.space(6)
      spacing: Style.space(6)
      readonly property real inner: width - leftPadding - rightPadding

      Text {
        width: parent.inner
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: lrow.mode === "lock" ? "A list password: this list's own, not the master password. Its to-dos are encrypted again with it and stay hidden until it is typed; they lock again when the panel closes."
          : lrow.mode === "unlock" ? "Type the list password."
          : lrow.mode === "unlocked" ? "Unlocked until the panel closes."
          : lrow.mode === "repass" ? "A new list password. Its to-dos stay as they are, on every device."
          : lrow.mode === "delete" ? "Delete \u201c" + String(lrow.list.name || "") + "\u201d" + (lrow.list.items && lrow.list.items.length ? " and its " + lrow.list.items.length + " to-dos" : "") + "? It cannot be undone."
          : ""
        color: lrow.mode === "delete" ? Color.urgent : root.dimForeground
        font.family: root.ff
        font.pixelSize: Style.font.caption
      }

      PasswordField {
        id: lockA
        visible: lrow.mode === "lock"
        width: parent.inner
        placeholderText: "List password"
        onEntered: lockB.input.forceActiveFocus()
        onEscaped: { root.closeRow(); root.takeKeys() }
      }
      Row {
        visible: lrow.mode === "lock"
        spacing: Style.space(6)
        PasswordField {
          id: lockB
          width: lrow.width - Style.space(32) - lockGo.width - Style.space(6)
          placeholderText: "The same again"
          onEntered: root.setLockFor(lrow.list.id, lockA.text, lockB.text)
          onEscaped: { root.closeRow(); root.takeKeys() }
        }
        PanelButton { id: lockGo; iconText: "\u{f033e}"; text: "Lock"; selected: true; onClicked: root.setLockFor(lrow.list.id, lockA.text, lockB.text) }
      }

      Row {
        visible: lrow.mode === "unlock"
        spacing: Style.space(6)
        PasswordField {
          id: unlockB
          width: lrow.width - Style.space(32) - unlockGo.width - Style.space(6)
          placeholderText: "List password"
          onEntered: { root.unlockListFor(lrow.list.id, text); text = "" }
          onEscaped: { root.closeRow(); root.takeKeys() }
        }
        PanelButton { id: unlockGo; text: root.busy ? "\u2026" : "Unlock"; selected: true; onClicked: { root.unlockListFor(lrow.list.id, unlockB.text); unlockB.text = "" } }
      }

      PasswordField {
        id: repassA
        visible: lrow.mode === "repass"
        width: parent.inner
        placeholderText: "New list password"
        onEntered: repassB.input.forceActiveFocus()
        onEscaped: { root.closeRow(); root.takeKeys() }
      }
      Row {
        visible: lrow.mode === "repass"
        spacing: Style.space(6)
        PasswordField {
          id: repassB
          width: lrow.width - Style.space(32) - repassGo.width - Style.space(6)
          placeholderText: "The same again"
          onEntered: root.changeListPasswordFor(lrow.list.id, repassA.text, repassB.text)
          onEscaped: { root.closeRow(); root.takeKeys() }
        }
        PanelButton { id: repassGo; text: "Change"; selected: true; onClicked: root.changeListPasswordFor(lrow.list.id, repassA.text, repassB.text) }
      }

      Row {
        visible: lrow.mode === "unlocked"
        spacing: Style.space(6)
        PanelButton { iconText: "\u{f030b}"; text: "Change list password"; onClicked: root.openRow(lrow.list.id, "repass") }
        PanelButton { iconText: "\u{f0340}"; text: "Remove the lock"; onClicked: root.removeLockFor(lrow.list.id) }
        PanelButton { iconText: "\u{f033e}"; text: "Lock now"; onClicked: { root.closeRow(); root.lockNow() } }
      }

      Row {
        visible: lrow.mode === "delete"
        spacing: Style.space(6)
        PanelButton { iconText: "\u{f0a7a}"; text: "Delete"; foreground: Color.urgent; onClicked: root.deleteListNow(lrow.list.id) }
        PanelButton { text: "Cancel"; onClicked: { root.closeRow(); root.takeKeys() } }
      }
    }
  }

  // ---------- Tabs ----------
  readonly property var rowTabs: lists.map(function(l) {
    return { key: l.id, label: (l.locked ? (l.unlocked ? "\u{f0fc7} " : "\u{f033e} ") : "") + l.name, count: l.locked && !l.unlocked ? 0 : Number(l.open || 0) }
  })
  property bool moreOpen: false
  // No tab is wider than about two fifths of the row. A longer label is
  // cut by its count of characters (the bar's font is monospaced); all of
  // it is in the tooltip. Pure functions of fixed sizes: nothing here is
  // written while a binding reads it.
  readonly property real tabCap: Math.floor(tabRow.width * 0.4)
  readonly property real tabPaddingX: Style.space(6)
  readonly property real tabPadding: tabPaddingX * 2 + Style.space(6)
  readonly property real charWidth: Math.max(1, charMeasure.implicitWidth)
  function tabLabel(t) { return Model.tabLabel(t) }
  function shortLabel(t, room) { return Model.shortLabel(t, room === undefined ? tabCap - tabPadding : room, charWidth) }

  // ---------- Panel ----------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.defaultFocus
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      clip: true
      // While a field is being typed in, every key belongs to it.
      blocked: root.fieldsFocused > 0
      onCloseRequested: root.rowEdit !== "" ? root.closeRow()
        : root.managing ? root.leaveManage()
        : root.movingItem !== "" ? root.cancelMoving()
        : root.naming !== "" ? root.naming = ""
        : root.moreOpen ? root.moreOpen = false
        : root.configuring ? root.settingsBack()
        : root.cursorActive ? (root.cursorActive = false, root.focusDefault())
        : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: {
        if (root.cursorItem !== "") root.activate(root.cursorItem)
        else root.focusAdd()
      }
      onDeleteRequested: {
        if (root.view === "lists") {
          var dl = root.listById(root.cursorList)
          if (dl) root.openRow(dl.id, dl.locked && !dl.unlocked ? "unlock" : "delete")
        } else root.removeItem(root.itemAt(root.cursorItem))
      }
      onTextKey: function(t) {
        if (root.view === "lists") {
          var l = root.listById(root.cursorList)
          if (t === "r" && l) root.openRow(l.id, "rename")
          else if (t === "p" && l) root.toggleRow(l.id, root.lockModeFor(l))
          else if (t === "n" || t === "N") newListField.input.forceActiveFocus()
          else if (t === "m") root.leaveManage()
          return
        }
        if (root.view !== "list") {
          if (root.onPage("") && (t === "c" || t === "s")) root.configuring = false
          return
        }
        var it = root.itemAt(root.cursorItem)
        if (t === "u" && root.canUndo) root.undo()
        else if (t === "t" && it) root.startMoving(it)
        else if (t === "e" && it) root.startEdit(it)
        else if (t === "J" && it) root.moveItem(it, 1)
        else if (t === "K" && it) root.moveItem(it, -1)
        else if (t === "n" || t === "a" || t === "i" || t === "/") { root.cursorActive = false; root.focusAdd() }
        else if (t === "N") root.startNaming("new")
        else if (t === "r") root.startNaming("rename")
        else if (t === "c") root.showDone = !root.showDone
        else if (t === "m") root.manage()
        else if (t === "s") root.openSettings()
        else if (t === "S") root.cmd({ cmd: "sync" })
        else if (t >= "1" && t <= "9" && Number(t) <= root.lists.length) root.selectList(root.lists[Number(t) - 1].id)
      }

      // Has the keys whenever no field has them; takes Shift+arrows and the
      // like before the catcher, which would see them as plain arrows.
      // A click on the panel outside a field takes the keys back from it.
      MouseArea {
        anchors.fill: parent
        z: -1
        onPressed: function(mouse) { root.takeKeys(); mouse.accepted = false }
      }

      Item {
        id: keyTarget
        focus: true
        Keys.onPressed: function(event) { if (root.fieldsFocused === 0 && root.specialKey(event, null)) event.accepted = true }
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        // ---------- Masthead ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(masthead.implicitHeight, headerActions.implicitHeight)

          PanelSectionHeader {
            id: masthead
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.view === "settings" ? "SETTINGS" : root.view === "lists" ? "LISTS" : "TO-DO LISTS"
            foreground: root.barForeground
            fontFamily: root.ff
          }

          Row {
            id: headerActions
            visible: root.view === "list"
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            PanelActionButton {
              visible: root.lists.some(function(l) { return l.unlocked })
              iconText: "\u{f033e}" // nf-md-lock
              tooltipText: "Lock the unlocked lists (Ctrl+L)"
              foreground: root.barForeground
              fontFamily: root.ff
              onClicked: root.lockNow()
            }

            PanelActionButton {
              visible: root.repo !== ""
              iconText: root.syncIcon
              tooltipText: root.syncText + " · click to sync (S)"
              foreground: root.sync.state === "error" ? Color.urgent : root.sync.state === "offline" ? root.dimForeground : root.barForeground
              fontFamily: root.ff
              onClicked: root.cmd({ cmd: "sync" })
            }

            PanelActionButton {
              iconText: "\u{f0493}" // nf-md-cog
              tooltipText: "Settings and sync (s)"
              foreground: root.barForeground
              fontFamily: root.ff
              onClicked: root.openSettings()
            }
          }
        }

        // ---------- Loading, error ----------
        Note {
          visible: root.view === "loading" || root.view === "error"
          text: root.view === "loading" ? "Opening…" : String(root.status.error || "Something went wrong")
          color: root.view === "error" ? Color.urgent : root.dimForeground
        }

        // ---------- Setup ----------
        Note {
          visible: root.view === "setup" && !root.joining
          text: "Choose a master password: 12 characters or more. Your to-do lists are kept encrypted with it, and the keyring remembers it. Next you get a recovery key, the one way back in if you forget it."
        }
        PasswordField {
          id: newField
          visible: root.view === "setup" && !root.joining
          width: parent.width
          placeholderText: "Master password (12 characters or more)"
          onEntered: newAgainField.input.forceActiveFocus()
          onEscaped: root.close()
        }
        PasswordField {
          id: newAgainField
          visible: root.view === "setup" && !root.joining
          width: parent.width
          placeholderText: "The same again"
          onEntered: root.createLists()
          onEscaped: root.close()
        }
        Row {
          visible: root.view === "setup" && !root.joining
          spacing: Style.space(6)
          PanelButton { text: "Create my lists"; selected: true; onClicked: root.createLists() }
          PanelButton { text: "I have them on GitHub…"; onClicked: root.joining = true }
        }

        Note {
          visible: root.view === "setup" && root.joining
          text: "Your lists from another device: the private GitHub repository they sync to, a token for it, and the master password. An empty repository starts new lists with this master password."
        }
        LineField {
          id: joinRepoField
          visible: root.view === "setup" && root.joining
          width: parent.width
          maximumLength: 200
          placeholderText: "owner/repository"
          onEntered: joinTokenField.input.forceActiveFocus()
          onEscaped: root.joining = false
        }
        PasswordField {
          id: joinTokenField
          visible: root.view === "setup" && root.joining
          width: parent.width
          placeholderText: "GitHub token"
          onEntered: joinPasswordField.input.forceActiveFocus()
          onEscaped: root.joining = false
        }
        PasswordField {
          id: joinPasswordField
          visible: root.view === "setup" && root.joining
          width: parent.width
          placeholderText: "Master password"
          onEntered: root.connectRepo(true)
          onEscaped: root.joining = false
        }
        Row {
          visible: root.view === "setup" && root.joining
          spacing: Style.space(6)
          PanelButton { text: root.busy ? "Connecting…" : "Connect"; selected: true; onClicked: root.connectRepo(true) }
          PanelButton { text: "Back"; onClicked: root.joining = false }
        }
        TokenHelp { visible: root.view === "setup" && root.joining }

        // ---------- The recovery key, once ----------
        Note {
          visible: root.view === "recovery"
          text: "Your recovery key. If you forget the master password, or a list password, this key opens your lists and lets you set a new one. Nobody else has it, and it is shown only now: keep it in your password manager, or on paper."
          color: root.barForeground
        }
        Rectangle {
          visible: root.view === "recovery"
          width: parent.width
          implicitHeight: codeText.implicitHeight + Style.space(20)
          radius: Style.cornerRadius
          color: Style.controlFill(false, false, root.barForeground, root.accent)
          border.width: 1
          border.color: root.accent

          Text {
            id: codeText
            anchors.centerIn: parent
            width: parent.width - Style.space(20)
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            wrapMode: Text.WrapAnywhere
            text: String(root.status.recovery || "")
            color: root.accent
            font.family: root.ff
            font.pixelSize: Style.font.body
            font.bold: true
            font.letterSpacing: 1
          }
        }
        Row {
          visible: root.view === "recovery"
          spacing: Style.space(6)
          PanelButton { iconText: "\u{f018f}"; text: "Copy"; onClicked: root.copyRecovery() }
          PanelButton { iconText: "\u{f012c}"; text: "I saved it"; selected: true; onClicked: root.cmd({ cmd: "ackRecovery" }) }
        }

        // ---------- Locked ----------
        Note {
          visible: root.view === "locked" && !root.recovering
          text: "Your to-do lists are encrypted. Type the master password to open them."
        }
        PasswordField {
          id: masterField
          visible: root.view === "locked" && !root.recovering
          width: parent.width
          placeholderText: "Master password"
          onEntered: root.unlockAll()
          onEscaped: root.close()
        }
        Row {
          visible: root.view === "locked" && !root.recovering
          spacing: Style.space(6)
          PanelButton { text: root.busy ? "Opening\u2026" : "Open"; selected: true; onClicked: root.unlockAll() }
          PanelButton { text: "Forgot the master password?"; onClicked: { root.recovering = true; Qt.callLater(function() { recoverCodeField.input.forceActiveFocus() }) } }
        }

        // A forgotten password: the recovery key, and a new password.
        Note {
          visible: root.view === "locked" && root.recovering
          text: "Type your recovery key (the one shown when you set your lists up) and choose a new master password."
        }
        LineField {
          id: recoverCodeField
          visible: root.view === "locked" && root.recovering
          width: parent.width
          maximumLength: 64
          placeholderText: "Recovery key: XXXX-XXXX-XXXX-\u2026"
          onEntered: recoverPw.input.forceActiveFocus()
          onEscaped: root.recovering = false
        }
        PasswordField {
          id: recoverPw
          visible: root.view === "locked" && root.recovering
          width: parent.width
          placeholderText: "New master password (12 characters or more)"
          onEntered: recoverPw2.input.forceActiveFocus()
          onEscaped: root.recovering = false
        }
        PasswordField {
          id: recoverPw2
          visible: root.view === "locked" && root.recovering
          width: parent.width
          placeholderText: "The same again"
          onEntered: root.recoverAll()
          onEscaped: root.recovering = false
        }
        Row {
          visible: root.view === "locked" && root.recovering
          spacing: Style.space(6)
          PanelButton { text: root.busy ? "\u2026" : "Set the new master password"; selected: true; onClicked: root.recoverAll() }
          PanelButton { text: "Back"; onClicked: root.recovering = false }
        }

        // ---------- Tabs ----------
        Row {
          id: measures
          visible: false
          Repeater {
            model: root.view === "list" ? root.rowTabs : []
            Button {
              required property var modelData
              objectName: "tabMeasure"
              text: root.shortLabel(modelData)
              fontSize: Style.font.bodySmall
              fontFamily: root.ff
              horizontalPadding: root.tabPaddingX
              verticalPadding: Style.spacing.controlPaddingY
            }
          }
          PanelButton {
            id: buttonMeasure
            iconText: "\u{f0415}"
            text: "Add"
          }
          Button {
            id: moreMeasureButton
            text: "More (99) ▾"
            fontSize: Style.font.bodySmall
            fontFamily: root.ff
            horizontalPadding: root.tabPaddingX
            verticalPadding: Style.spacing.controlPaddingY
          }
          Text {
            id: charMeasure
            textFormat: Text.PlainText
            text: "M"
            font.family: root.ff
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Text {
            id: arrowMeasure
            textFormat: Text.PlainText
            text: " ▾"
            font.family: root.ff
            font.pixelSize: Style.font.bodySmall
          }
        }

        Item {
          visible: root.view === "list"
          width: parent.width
          implicitHeight: Math.max(tabRow.implicitHeight, tabActions.implicitHeight)

          // The tabs that fit, then More for the rest; the room left is
          // shared out evenly, so the row is always exactly one line.
          Row {
            id: tabRow
            anchors.left: parent.left
            anchors.right: tabActions.left
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            readonly property var widths: {
              var out = []
              for (var i = 0; i < measures.children.length; i++) {
                var c = measures.children[i]
                if (c.objectName === "tabMeasure") out.push(c.implicitWidth)
              }
              return out
            }
            readonly property real moreWidth: moreMeasureButton.implicitWidth
            readonly property int fit: widths.length !== root.rowTabs.length ? root.rowTabs.length
              : Model.tabsThatFit(widths, spacing, width, moreWidth)
            readonly property bool hasMore: fit < root.rowTabs.length
            readonly property var shown: root.rowTabs.slice(0, fit)
            readonly property var hidden: root.rowTabs.slice(fit)
            readonly property var chosenHidden: {
              for (var i = 0; i < hidden.length; i++) if (hidden[i].key === root.currentId) return hidden[i]
              return null
            }
            readonly property int hiddenOpen: hidden.reduce(function(sum, t) { return sum + t.count }, 0)
            readonly property real extra: Model.tabExtra(widths, fit, spacing, width, moreWidth, hasMore)

            Repeater {
              model: tabRow.shown
              Button {
                required property var modelData
                required property int index
                width: (tabRow.widths[index] || implicitWidth) + tabRow.extra
                text: root.shortLabel(modelData)
                tooltipText: text !== root.tabLabel(modelData) ? root.tabLabel(modelData) : ""
                selected: root.currentId === modelData.key
                fontSize: Style.font.bodySmall
                foreground: root.barForeground
                fontFamily: root.ff
                bordered: true
                horizontalPadding: root.tabPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.selectList(modelData.key)
                onRightClicked: root.manage(modelData.key)
              }
            }

            Button {
              id: moreButton
              visible: tabRow.hasMore
              width: tabRow.moreWidth + tabRow.extra
              text: (tabRow.chosenHidden ? root.shortLabel(tabRow.chosenHidden, moreButton.width - root.tabPadding - arrowMeasure.implicitWidth)
                : "More" + (tabRow.hiddenOpen > 0 ? " (" + tabRow.hiddenOpen + ")" : "")) + " ▾"
              tooltipText: tabRow.chosenHidden ? root.tabLabel(tabRow.chosenHidden) : ""
              selected: tabRow.chosenHidden !== null || root.moreOpen
              fontSize: Style.font.bodySmall
              foreground: root.barForeground
              fontFamily: root.ff
              bordered: true
              horizontalPadding: root.tabPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.moreOpen = !root.moreOpen
            }
          }

          Row {
            id: tabActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            PanelActionButton {
              iconText: "\u{f0415}" // nf-md-plus
              tooltipText: "New list (N)"
              foreground: root.barForeground
              fontFamily: root.ff
              onClicked: root.startNaming("new")
            }
            PanelActionButton {
              iconText: "\u{f0900}" // nf-md-playlist-edit
              tooltipText: "Lists: rename, reorder, lock, delete (m)"
              foreground: root.barForeground
              fontFamily: root.ff
              onClicked: root.manage()
            }
          }
        }

        // The lists under More, one per line.
        Column {
          visible: root.view === "list" && root.moreOpen && tabRow.hasMore
          width: parent.width
          spacing: Style.space(2)

          Repeater {
            model: tabRow.hidden
            Rectangle {
              id: moreItem
              required property var modelData
              readonly property bool chosen: root.currentId === modelData.key
              width: parent.width
              implicitHeight: moreLabel.implicitHeight + Style.spacing.controlPaddingY * 2
              radius: Style.space(4)
              color: moreMouse.containsMouse ? Style.hoverFillFor(root.barForeground, root.accent) : "transparent"

              Text {
                id: moreLabel
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.controlPaddingX
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.controlPaddingX
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.tabLabel(moreItem.modelData)
                wrapMode: Text.WordWrap
                color: moreItem.chosen ? root.accent : root.barForeground
                font.family: root.ff
                font.pixelSize: Style.font.bodySmall
                font.bold: moreItem.chosen
              }

              MouseArea {
                id: moreMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.selectList(moreItem.modelData.key); root.moreOpen = false }
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.barForeground
          }
        }

        // ---------- Naming a list ----------
        Row {
          visible: root.view === "list" && root.naming !== ""
          width: parent.width
          spacing: Style.space(6)

          LineField {
            id: nameField
            width: parent.width - nameSave.width - parent.spacing
            maximumLength: 60
            placeholderText: root.naming === "new" ? "Name of the new list" : "New name"
            onEntered: root.saveName()
            onEscaped: { root.naming = ""; root.focusDefault() }
          }
          PanelButton {
            id: nameSave
            text: root.naming === "new" ? "Add list" : "Rename"
            selected: true
            onClicked: root.saveName()
          }
        }

        // ---------- A locked list ----------
        Column {
          visible: root.view === "list" && root.currentHidden
          width: parent.width
          spacing: Style.space(8)
          topPadding: Style.space(6)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: "\u{f033e}"
            color: root.dimForeground
            font.family: root.ff
            font.pixelSize: Style.font.icon * 2
          }
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: "“" + (root.current ? root.current.name : "") + "” is locked" + (root.current && root.current.open ? " · " + root.current.open + " to do" : "")
            color: root.barForeground
            font.family: root.ff
            font.pixelSize: Style.font.bodySmall
          }
          Row {
            width: parent.width
            spacing: Style.space(6)
            PasswordField {
              id: unlockField
              width: parent.width - unlockGo.width - parent.spacing
              placeholderText: "List password"
              onEntered: root.unlockList()
              onEscaped: root.close()
            }
            PanelButton { id: unlockGo; text: root.busy ? "\u2026" : "Unlock"; selected: true; onClicked: root.unlockList() }
          }
          PanelButton {
            visible: !root.listRecovering && !!root.current && !!root.current.recoverable
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Forgot it? Use the recovery key"
            onClicked: { root.listRecovering = true; Qt.callLater(function() { listRecCode.input.forceActiveFocus() }) }
          }
          Note {
            visible: root.listRecovering
            text: "The recovery key opens this list. Choose a new list password, or leave both empty to take the lock off."
          }
          LineField {
            id: listRecCode
            visible: root.listRecovering
            width: parent.width
            maximumLength: 64
            placeholderText: "Recovery key: XXXX-XXXX-XXXX-\u2026"
            onEntered: listRecPw.input.forceActiveFocus()
            onEscaped: root.listRecovering = false
          }
          PasswordField {
            id: listRecPw
            visible: root.listRecovering
            width: parent.width
            placeholderText: "New list password (empty: no lock)"
            onEntered: listRecPw2.input.forceActiveFocus()
            onEscaped: root.listRecovering = false
          }
          Row {
            visible: root.listRecovering
            width: parent.width
            spacing: Style.space(6)
            PasswordField {
              id: listRecPw2
              width: parent.width - listRecGo.width - parent.spacing
              placeholderText: "The same again"
              onEntered: root.recoverListNow()
              onEscaped: root.listRecovering = false
            }
            PanelButton { id: listRecGo; text: root.busy ? "\u2026" : "Open"; selected: true; onClicked: root.recoverListNow() }
          }
        }

        // ---------- Adding ----------
        Row {
          visible: root.view === "list" && !root.currentHidden
          width: parent.width
          spacing: Style.space(6)

          LineField {
            id: addField
            width: parent.width - addGo.width - parent.spacing
            panelKeys: true
            placeholderText: "New to-do in " + (root.current ? root.current.name : "") + "…  (n)"
            onEntered: root.addItem()
            // Esc empties the field, then leaves it; the next Esc closes.
            onEscaped: text !== "" ? text = "" : root.takeKeys()
            onSteppedDown: if (root.focusItems.length) { root.takeKeys(); root.cursorActive = true; root.cursorIndex = 0 }
            onSwitchedList: function(dx) { root.stepList(dx) }
          }
          PanelButton {
            id: addGo
            iconText: "\u{f0415}"
            text: "Add"
            onClicked: root.addItem()
          }
        }

        // ---------- An update left to finish ----------
        Rectangle {
          visible: root.view === "list" && !!root.status.legacy
          width: parent.width
          implicitHeight: updateNote.implicitHeight + Style.space(10)
          radius: Style.space(4)
          color: updateMouse.containsMouse ? Style.hoverFillFor(root.barForeground, root.accent) : "transparent"
          border.width: 1
          border.color: root.accent
          Text {
            id: updateNote
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.spacing.controlPaddingX
            anchors.rightMargin: Style.spacing.controlPaddingX
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: "One step left: finish the update (your master password, then a new recovery key) \u203a"
            color: root.accent
            font.family: root.ff
            font.pixelSize: Style.font.caption
          }
          MouseArea {
            id: updateMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.openSettings(); root.openSettingsPage("update") }
          }
        }

        // ---------- Sealed with an older password ----------
        // The list's password changed on another device while this one,
        // offline, sealed to-dos with the old one. The old password opens
        // them; they are sealed again with the list's password now.
        Column {
          visible: root.view === "list" && !root.currentHidden && !!root.current && Number(root.current.stale || 0) > 0
          width: parent.width
          spacing: Style.space(6)

          Note {
            text: "\u{f033e}  " + (root.current ? root.current.stale : 0)
              + (root.current && root.current.stale === 1 ? " to-do was" : " to-dos were")
              + " sealed with an older list password, before it changed. Type that password to open them."
            color: root.barForeground
          }
          Row {
            width: parent.width
            spacing: Style.space(6)
            PasswordField {
              id: staleField
              width: parent.width - staleGo.width - staleDrop.width - parent.spacing * 2
              placeholderText: "Older list password, or the recovery key"
              onEntered: root.openStale()
              onEscaped: { text = ""; root.takeKeys() }
            }
            PanelButton { id: staleGo; text: root.busy ? "\u2026" : "Open"; selected: true; onClicked: root.openStale() }
            PanelButton {
              id: staleDrop
              text: root.armedStale ? "Delete them?" : "Delete"
              foreground: root.armedStale ? Color.urgent : root.barForeground
              onClicked: {
                if (!root.armedStale) { root.armedStale = true; return }
                root.armedStale = false
                root.op({ op: "removeStale", list: root.currentId })
              }
            }
          }
        }

        // ---------- To-dos ----------
        Flickable {
          id: listView
          visible: root.view === "list" && !root.currentHidden && root.items.length > 0
          width: parent.width
          height: Math.min(list.implicitHeight, Math.max(Style.space(160), panel.availableCardHeight * 0.7 - Style.space(160)))
          contentHeight: list.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          function reveal(row) {
            if (!row) return
            var y = row.mapToItem(list, 0, 0).y
            if (y < contentY) contentY = y
            else if (y + row.height > contentY + height) contentY = y + row.height - height
          }

          Column {
            id: list
            width: parent.width
            spacing: Style.space(1)

            Repeater {
              model: root.openItems.length
              ItemRow {
                id: itemRow
                required property int index
                item: root.openItems[index] || ({})
                hasCursor: root.hasCursor("item:" + item.id)
                onHasCursorChanged: if (hasCursor) listView.reveal(itemRow)
              }
            }

            // Completed: folded away, as in Apple's app.
            Item {
              visible: root.doneItems.length > 0
              width: parent.width
              implicitHeight: Math.max(doneHead.implicitHeight, clearButton.implicitHeight) + Style.space(8)

              Rectangle {
                anchors.fill: parent
                radius: Style.space(4)
                color: root.hasCursor("completed") || doneMouse.containsMouse ? Style.hoverFillFor(root.barForeground, root.accent) : "transparent"
              }
              Text {
                id: doneHead
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.controlPaddingX
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: (root.showDone ? "\u{f0140} " : "\u{f0142} ") + "COMPLETED (" + root.doneItems.length + ")"
                color: root.dimForeground
                font.family: root.ff
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
              MouseArea {
                id: doneMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.showDone = !root.showDone
              }
              Button {
                id: clearButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Clear"
                fontSize: Style.font.caption
                foreground: root.dimForeground
                fontFamily: root.ff
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.space(2)
                onClicked: root.clearDone()
              }
            }

            Repeater {
              model: root.showDone ? root.doneItems.length : 0
              ItemRow {
                id: itemRow
                required property int index
                item: root.doneItems[index] || ({})
                hasCursor: root.hasCursor("item:" + item.id)
                onHasCursorChanged: if (hasCursor) listView.reveal(itemRow)
              }
            }
          }
        }

        Note {
          visible: root.view === "list" && !root.currentHidden && root.items.length === 0
          horizontalAlignment: Text.AlignHCenter
          text: "Nothing here. Type above and press Enter."
        }

        // ---------- Moving a to-do ----------
        PanelSectionHeader {
          visible: root.view === "move"
          text: "MOVE \u201c" + root.movingText + "\u201d TO"
          foreground: root.barForeground
          fontFamily: root.ff
        }
        Column {
          visible: root.view === "move"
          width: parent.width
          spacing: Style.space(1)
          Repeater {
            model: root.view === "move" ? root.moveRows : []
            PickRow {
              required property var modelData
              row: modelData
              hasCursor: root.hasCursor("to:" + modelData.id)
              onClicked: root.moveItemTo(modelData)
            }
          }
        }
        PanelButton {
          visible: root.view === "move"
          text: "Cancel"
          onClicked: root.cancelMoving()
        }

        // ---------- The Lists screen ----------
        PanelButton {
          visible: root.view === "lists"
          iconText: "\u{f004d}"
          text: "Back"
          onClicked: root.leaveManage()
        }

        Column {
          id: listsColumn
          visible: root.view === "lists"
          width: parent.width
          spacing: Style.space(2)

          // By count, not by the lists themselves: a new status (a sync)
          // keeps the rows, and with them a row's open fields.
          Repeater {
            model: root.view === "lists" ? root.lists.length : 0
            ListRow {
              required property int index
              list: root.lists[index] || ({})
              hasCursor: root.hasCursor("list:" + (root.lists[index] ? root.lists[index].id : ""))
            }
          }
        }

        Row {
          visible: root.view === "lists"
          width: parent.width
          spacing: Style.space(6)

          LineField {
            id: newListField
            width: parent.width - newListGo.width - parent.spacing
            maximumLength: 60
            hasCursor: root.hasCursor("new")
            placeholderText: "New list"
            onEntered: if (root.addListNamed(text)) text = ""
            onEscaped: { text = ""; root.takeKeys() }
          }
          PanelButton {
            id: newListGo
            iconText: "\u{f0415}"
            text: "Add"
            onClicked: if (root.addListNamed(newListField.text)) newListField.text = ""
          }
        }

        Note {
          visible: root.view === "lists"
          text: "Drag \u{f01dd} (or Shift+\u2191 \u2193, J K) to reorder \u00b7 click a name (r, F2) to rename \u00b7 p locks \u00b7 x deletes"
        }

        // ---------- Settings ----------
        // A short list, as in mani4.ai-scratchpad: each row opens a page of
        // its own; Back (or Esc) goes up again.
        PanelButton {
          visible: root.view === "settings"
          iconText: "\u{f004d}"
          text: root.settingsPage === "" ? "Back to the to-dos" : "Settings"
          onClicked: root.settingsBack()
        }

        Column {
          visible: root.onPage("")
          width: parent.width
          spacing: Style.space(1)
          Repeater {
            model: root.onPage("") ? root.settingRows : []
            SettingRow {
              required property var modelData
              row: modelData
              hasCursor: root.hasCursor("set:" + modelData.page)
              onClicked: root.openSettingsPage(modelData.page)
            }
          }
        }

        // ----- finishing the update (a file of the first name) -----
        PanelSectionHeader {
          visible: root.onPage("update")
          text: "FINISH THE UPDATE"
          foreground: root.barForeground
          fontFamily: root.ff
        }
        Note {
          visible: root.onPage("update")
          text: "Your lists' file still carries the plugin's first name inside its encryption. Type the master password to make it new: nothing in your lists changes, and you get a new recovery key (the old one stops working; save the new one)."
        }
        Note {
          visible: root.onPage("update") && root.lockedNames.length > 0
          text: "First take the lock off " + root.lockedNames.map(function(n) { return "\u201c" + n + "\u201d" }).join(", ") + " (Lists, its lock, Remove the lock), and lock it again after: a list password is not kept, so its lock cannot be made new without it."
          color: Color.urgent
        }
        Row {
          visible: root.onPage("update")
          width: parent.width
          spacing: Style.space(6)
          PasswordField {
            id: updatePw
            width: parent.width - updateGo.width - parent.spacing
            placeholderText: "Master password"
            onEntered: root.finishUpdate()
            onEscaped: root.settingsBack()
          }
          PanelButton { id: updateGo; text: root.busy ? "\u2026" : "Finish"; selected: true; onClicked: root.finishUpdate() }
        }

        // ----- the shortcut: pick one, or type your own -----
        PanelSectionHeader {
          visible: root.onPage("shortcut")
          text: "OPEN THIS PANEL WITH"
          foreground: root.barForeground
          fontFamily: root.ff
        }
        Note {
          visible: root.onPage("shortcut") && !!root.service && root.service.hotkeyConflict !== ""
          text: root.service ? root.service.hotkey + " already runs \u201c" + root.service.hotkeyConflict + "\u201d, so it was left alone. Choose a free key." : ""
          color: Color.urgent
        }
        LineField {
          id: hotkeyField
          visible: root.onPage("shortcut")
          width: parent.width
          maximumLength: 40
          placeholderText: "Pick one, or type your own"
          onEntered: if (root.pickRows.length) root.pickHotkey(root.pickRows[0])
          onEscaped: text !== "" ? text = "" : root.settingsBack()
          onSteppedDown: if (root.pickRows.length) { root.takeKeys(); root.cursorActive = true; root.cursorIndex = 0 }
        }
        Column {
          visible: root.onPage("shortcut")
          width: parent.width
          spacing: Style.space(1)
          Repeater {
            model: root.onPage("shortcut") ? root.pickRows : []
            PickRow {
              required property var modelData
              required property int index
              row: modelData
              hasCursor: root.hasCursor("pick:" + index)
              onClicked: root.pickHotkey(modelData)
            }
          }
        }

        PanelSectionHeader {
          visible: root.onPage("sync")
          text: "SYNC"
          foreground: root.barForeground
          fontFamily: root.ff
        }
        Note {
          visible: root.onPage("sync")
          text: root.repo !== "" ? root.repo + " · " + String(root.status.path || "") + "\n" + root.syncText
            : "Keep your lists in a private GitHub repository too, so your phone (the web app) and other computers have them. Only the encrypted file goes there."
          color: root.sync.state === "error" ? Color.urgent : root.dimForeground
        }
        Row {
          visible: root.onPage("sync") && root.repo !== ""
          spacing: Style.space(6)
          PanelButton { iconText: "\u{f04e6}"; text: "Sync now"; onClicked: root.cmd({ cmd: "sync" }) }
          PanelButton {
            text: root.armedDisconnect ? "Stop syncing?" : "Disconnect"
            foreground: root.armedDisconnect ? Color.urgent : root.barForeground
            onClicked: {
              if (!root.armedDisconnect) { root.armedDisconnect = true; return }
              root.armedDisconnect = false
              root.cmd({ cmd: "disconnect" })
            }
          }
        }
        LineField {
          id: repoField
          visible: root.onPage("sync") && root.repo === ""
          width: parent.width
          maximumLength: 200
          placeholderText: "owner/repository (private)"
          onEntered: tokenField.input.forceActiveFocus()
          onEscaped: root.settingsBack()
        }
        Row {
          visible: root.onPage("sync") && root.repo === ""
          width: parent.width
          spacing: Style.space(6)
          PasswordField {
            id: tokenField
            width: parent.width - connectGo.width - parent.spacing
            placeholderText: "GitHub token"
            onEntered: root.connectRepo(false)
            onEscaped: root.settingsBack()
          }
          PanelButton { id: connectGo; text: root.busy ? "…" : "Connect"; selected: true; onClicked: root.connectRepo(false) }
        }
        TokenHelp { visible: root.onPage("sync") && root.repo === "" }

        PanelSectionHeader {
          visible: root.onPage("password")
          text: "MASTER PASSWORD"
          foreground: root.barForeground
          fontFamily: root.ff
        }
        Note {
          visible: root.onPage("password")
          text: "A new master password. Your other devices go on without asking; a new one asks for the new master password. The recovery key stays the same."
        }
        PasswordField {
          id: currentPw
          visible: root.onPage("password")
          width: parent.width
          placeholderText: "Current master password"
          onEntered: newPw.input.forceActiveFocus()
          onEscaped: root.takeKeys()
        }
        PasswordField {
          id: newPw
          visible: root.onPage("password")
          width: parent.width
          placeholderText: "New master password (12 characters or more)"
          onEntered: newPw2.input.forceActiveFocus()
          onEscaped: root.takeKeys()
        }
        Row {
          visible: root.onPage("password")
          width: parent.width
          spacing: Style.space(6)
          PasswordField {
            id: newPw2
            width: parent.width - changePwGo.width - parent.spacing
            placeholderText: "The same again"
            onEntered: root.changeMasterPassword()
            onEscaped: root.takeKeys()
          }
          PanelButton { id: changePwGo; text: root.busy ? "\u2026" : "Change"; selected: true; onClicked: root.changeMasterPassword() }
        }

        PanelSectionHeader {
          visible: root.onPage("recovery")
          text: "RECOVERY KEY"
          foreground: root.barForeground
          fontFamily: root.ff
        }
        Note {
          visible: root.onPage("recovery")
          text: "Lost it, or never saved it? Make a new one; the old one stops working. Locked lists take it on when they are next unlocked."
        }
        Row {
          visible: root.onPage("recovery")
          width: parent.width
          spacing: Style.space(6)
          PasswordField {
            id: recPwField
            width: parent.width - newRecGo.width - parent.spacing
            placeholderText: "Master password, to confirm"
            onEntered: root.makeNewRecovery()
            onEscaped: root.takeKeys()
          }
          PanelButton { id: newRecGo; iconText: "\u{f030b}"; text: root.busy ? "\u2026" : "New recovery key"; onClicked: root.makeNewRecovery() }
        }

        PanelSectionHeader {
          visible: root.onPage("computer")
          text: "THIS COMPUTER"
          foreground: root.barForeground
          fontFamily: root.ff
        }
        Note {
          visible: root.onPage("computer")
          text: root.status.remembered === "keyring" ? "The master password is remembered in the keyring (as the key it opens). Forget it, and the panel asks for it next time."
            : root.status.remembered === "session" ? "The keyring's main collection is not working, so the master password is remembered only until the computer restarts."
            : "There is no working keyring here, so the master password is asked again after every restart of the shell."
        }
        PanelButton {
          visible: root.onPage("computer")
          text: root.armedForget ? "Forget it and lock?" : "Forget the master password here"
          foreground: root.armedForget ? Color.urgent : root.barForeground
          onClicked: {
            if (!root.armedForget) { root.armedForget = true; return }
            root.armedForget = false
            root.configuring = false
            root.cmd({ cmd: "forget" })
          }
        }

        PanelSectionHeader {
          visible: root.onPage("export")
          text: "EXPORT"
          foreground: root.barForeground
          fontFamily: root.ff
        }
        Note {
          visible: root.onPage("export")
          text: "Your lists as a Markdown file in ~/Documents: a heading per list, a check box per to-do. It is plain text, not encrypted. A locked list is included only while it is unlocked."
        }
        PanelButton {
          visible: root.onPage("export")
          iconText: "\u{f0207}" // nf-md-export
          text: "Export as Markdown"
          onClicked: root.cmd({ cmd: "export" })
        }

        PanelSectionHeader {
          visible: root.onPage("keys")
          text: "KEYBOARD"
          foreground: root.barForeground
          fontFamily: root.ff
        }
        Column {
          visible: root.onPage("keys")
          width: parent.width
          spacing: Style.space(2)
          HelpRow { key: "n  a  /  Enter"; meaning: "Into the field, to add a to-do (Enter adds it)" }
          HelpRow { key: "↓ ↑"; meaning: "From the field into the list, and through it" }
          HelpRow { key: "← →  1–9"; meaning: "Switch list (Alt+← → while typing)" }
          HelpRow { key: "Space  Enter"; meaning: "Tick or untick" }
          HelpRow { key: "e"; meaning: "Edit the to-do (or its pencil)" }
          HelpRow { key: "x"; meaning: "Remove it (u, or Undo, brings it back)" }
          HelpRow { key: "t"; meaning: "Move it to another list" }
          HelpRow { key: "Shift+\u2191 \u2193  J K"; meaning: "Move it up, down (or drag it)" }
          HelpRow { key: "c"; meaning: "Show or hide the completed" }
          HelpRow { key: "Shift+\u2190 \u2192  H L"; meaning: "Move the list left, right (from the field while it is empty)" }
          HelpRow { key: "r  F2"; meaning: "Rename the list" }
          HelpRow { key: "N"; meaning: "New list" }
          HelpRow { key: "m"; meaning: "Lists: reorder, rename, lock, delete" }
          HelpRow { key: "Ctrl+L"; meaning: "Lock the unlocked lists" }
          HelpRow { key: "S  s"; meaning: "Sync now, settings" }
          HelpRow { key: "n  /"; meaning: "Back to the field" }
          HelpRow { key: "Esc"; meaning: "Leave the field, back, then close" }
        }

        PanelSectionHeader {
          visible: root.onPage("keys")
          text: "KEYBOARD \u00b7 LISTS"
          foreground: root.barForeground
          fontFamily: root.ff
        }
        Column {
          visible: root.onPage("keys")
          width: parent.width
          spacing: Style.space(2)
          HelpRow { key: "\u2191 \u2193"; meaning: "Choose a list" }
          HelpRow { key: "Shift+\u2191 \u2193  J K"; meaning: "Move it up, down (or drag its handle)" }
          HelpRow { key: "Enter  r  F2"; meaning: "Rename it" }
          HelpRow { key: "p"; meaning: "Lock, unlock, remove the lock" }
          HelpRow { key: "x"; meaning: "Delete it" }
          HelpRow { key: "n"; meaning: "New list" }
          HelpRow { key: "Esc  m"; meaning: "Back to the to-dos" }
        }

        // ---------- Notice ----------
        Item {
          visible: root.notice !== null && root.view !== "loading"
          width: parent.width
          implicitHeight: Math.max(noticeText.implicitHeight, undoButton.visible ? undoButton.implicitHeight : 0)
          Note {
            id: noticeText
            anchors.left: parent.left
            anchors.right: undoButton.visible ? undoButton.left : parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.notice ? String(root.notice.text || "") : ""
            color: root.notice && root.notice.ok ? root.accent : Color.urgent
          }
          Button {
            id: undoButton
            visible: !!root.notice && !!root.notice.undo && root.canUndo
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Undo (u)"
            fontSize: Style.font.caption
            foreground: root.barForeground
            fontFamily: root.ff
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.space(2)
            onClicked: root.undo()
          }
        }
      }
    }
  }

  // How to make a token that reaches one repository and nothing else.
  component TokenHelp: Note {
    text: "Token: github.com › Settings › Developer settings › Fine-grained tokens › Generate. Repository access: only this repository; Permissions: Contents, read and write. It is kept on this computer, encrypted with your master password."
  }
}
