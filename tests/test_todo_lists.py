"""Tests for bin/todo-lists that need no network or keyring:
python3 -m unittest discover -s tests"""
import base64
import http.server
import importlib.machinery
import importlib.util
import json
import os
import stat
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(os.path.dirname(HERE), "bin", "todo-lists")


def load(home):
    os.environ["XDG_CONFIG_HOME"] = os.path.join(home, "config")
    os.environ["XDG_DATA_HOME"] = os.path.join(home, "data")
    loader = importlib.machinery.SourceFileLoader("todo_lists", SCRIPT)
    spec = importlib.util.spec_from_loader("todo_lists", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    # No keyring in tests: an in-memory one.
    ring = {}
    module.keyring_get = lambda kind, service=None: ring.get(kind)
    module.keyring_set = lambda kind, secret, label: ring.__setitem__(kind, secret) or True
    module.keyring_clear = lambda kind, service=None: ring.pop(kind, None)
    # Faster key derivation in tests; still Argon2id through the command.
    module.ARGON = {"name": "Argon2id", "t": 1, "m": 8192, "p": 1}
    module.emit = lambda store: None
    return module, ring


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.m, self.ring = load(self.dir.name)
        self.s = self.m.Store()

    def tearDown(self):
        self.dir.cleanup()

    def op(self, **op):
        return self.s.apply(op)

    def lists(self):
        return self.s.view()["lists"]

    def texts(self, i=0):
        return [x["text"] for x in self.lists()[i]["items"]]


class CryptoTest(Base):
    def test_setup_create_and_reopen(self):
        self.assertEqual(self.s.view()["state"], "setup")
        self.assertFalse(self.s.create("short"))
        self.assertFalse(self.s.create("eleven char"))
        self.assertTrue(self.s.create("correct horse"))
        self.assertEqual([l["name"] for l in self.lists()], ["To-Do"])
        self.assertEqual(stat.S_IMODE(os.stat(self.m.STORE).st_mode), 0o600)
        with open(self.m.STORE) as f:
            raw = f.read()
        self.assertNotIn("To-Do", raw)
        env = json.loads(raw)
        self.assertEqual(env["format"], "mani4.todo-lists")
        self.assertEqual(env["v"], 3)
        self.assertEqual(env["header"]["password"]["kdf"]["name"], "Argon2id")
        self.assertRegex(self.s.recovery_shown, r"^([0-9A-Z]{4}-){7}[0-9A-Z]{4}$")
        # A new process opens it from the keyring.
        s2 = self.m.Store()
        s2.start()
        self.assertEqual(s2.view()["state"], "ready")
        # Without the keyring it asks, and only the right password opens it.
        self.ring.clear()
        s3 = self.m.Store()
        s3.start()
        self.assertEqual(s3.view()["state"], "locked")
        self.assertFalse(s3.unlock("wrong password"))
        self.assertTrue(s3.unlock("correct horse"))
        self.assertEqual(s3.view()["lists"][0]["name"], "To-Do")

    def test_changed_file_does_not_open(self):
        self.s.create("correct horse")
        with open(self.m.STORE) as f:
            env = json.load(f)
        ct = bytearray(base64.b64decode(env["ct"]))
        ct[0] ^= 1
        env["ct"] = base64.b64encode(bytes(ct)).decode()
        self.assertIsNone(self.m.open_doc(env, self.s.dek))

    def test_forget(self):
        self.s.create("correct horse")
        self.s.forget()
        self.assertNotIn("master", self.ring)
        self.assertEqual(self.s.view()["state"], "locked")


class ListTest(Base):
    def setUp(self):
        super().setUp()
        self.s.create("correct horse")
        self.lid = self.lists()[0]["id"]

    def test_lists(self):
        self.assertTrue(self.op(op="addList", name="Shopping\n"))
        self.assertFalse(self.op(op="addList", name="  "))
        shop = self.lists()[1]["id"]
        self.assertTrue(self.op(op="renameList", list=shop, name="Groceries"))
        self.assertTrue(self.op(op="moveList", list=shop, by=-1))
        self.assertEqual([l["name"] for l in self.lists()], ["Groceries", "To-Do"])
        self.assertFalse(self.op(op="moveList", list=shop, by=-1))
        self.assertTrue(self.op(op="removeList", list=self.lid))
        self.assertTrue(self.op(op="removeList", list=shop))
        self.assertEqual([l["name"] for l in self.lists()], ["To-Do"])

    def test_items(self):
        for t in ("milk", "eggs", "bread\nand butter"):
            self.assertTrue(self.op(op="add", list=self.lid, text=t))
        self.assertEqual(self.texts(), ["milk", "eggs", "bread and butter"])
        milk, eggs, bread = [x["id"] for x in self.lists()[0]["items"]]
        self.assertEqual(self.lists()[0]["open"], 3)
        self.assertTrue(self.op(op="done", list=self.lid, item=milk, done=True))
        self.assertEqual(self.texts(), ["eggs", "bread and butter", "milk"])
        self.assertEqual(self.lists()[0]["open"], 2)
        self.assertTrue(self.op(op="move", list=self.lid, item=bread, by=-1))
        self.assertEqual(self.texts(), ["bread and butter", "eggs", "milk"])
        self.assertFalse(self.op(op="move", list=self.lid, item=bread, by=-1))
        self.assertTrue(self.op(op="done", list=self.lid, item=milk, done=False))
        self.assertEqual(self.texts(), ["bread and butter", "eggs", "milk"])
        self.assertTrue(self.op(op="edit", list=self.lid, item=eggs, text="6 eggs"))
        self.assertFalse(self.op(op="edit", list=self.lid, item=eggs, text=""))
        self.assertTrue(self.op(op="done", list=self.lid, item=eggs, done=True))
        self.assertTrue(self.op(op="clearDone", list=self.lid))
        self.assertFalse(self.op(op="clearDone", list=self.lid))
        self.assertTrue(self.op(op="remove", list=self.lid, item=bread))
        self.assertEqual(self.texts(), ["milk"])

    def test_many_moves_keep_order(self):
        for t in "abcdef":
            self.op(op="add", list=self.lid, text=t)
        ids = {x["text"]: x["id"] for x in self.lists()[0]["items"]}
        # Bounce one back and forth until the gaps would run out.
        for _ in range(80):
            self.op(op="move", list=self.lid, item=ids["f"], by=-4)
            self.op(op="move", list=self.lid, item=ids["e"], by=-4)
        self.assertEqual(sorted(self.texts()), list("abcdef"))
        self.assertEqual(len(set(self.texts())), 6)

    def test_bad_ops_change_nothing(self):
        before = json.dumps(self.s.doc, sort_keys=True)
        for op in (None, "x", {}, {"op": "add", "list": "nope", "text": "a"},
                   {"op": "remove", "list": self.lid, "item": "nope"},
                   {"op": "moveList", "list": self.lid, "by": True}):
            self.assertFalse(self.s.apply(op))
        self.assertEqual(json.dumps(self.s.doc, sort_keys=True), before)

    def test_locked_list(self):
        self.op(op="add", list=self.lid, text="secret thing")
        self.assertFalse(self.s.set_lock(self.lid, "abc"))
        self.assertTrue(self.s.set_lock(self.lid, "1234"))
        rec = next(iter(self.s.doc["items"].values()))
        self.assertNotIn("text", rec)
        self.assertIn("sealed", rec)
        # Open until the panel closes.
        self.assertEqual(self.texts(), ["secret thing"])
        self.op(op="add", list=self.lid, text="another")
        self.s.list_keys = {}
        l = self.lists()[0]
        self.assertTrue(l["locked"])
        self.assertIsNone(l["items"])
        self.assertEqual(l["open"], 2)
        self.assertFalse(self.op(op="add", list=self.lid, text="x"))
        self.assertFalse(self.op(op="removeList", list=self.lid))
        self.assertFalse(self.s.unlock_list(self.lid, "wrong"))
        self.assertEqual(self.s.notice["text"], "Wrong password")
        self.s.unlock_list(self.lid, "1234")
        self.assertTrue(self.lists()[0]["unlocked"])
        self.assertEqual(self.texts(), ["secret thing", "another"])
        self.assertTrue(self.s.remove_lock(self.lid))
        self.assertFalse(self.lists()[0]["locked"])
        self.assertEqual(self.texts(), ["secret thing", "another"])

    def test_a_todo_moves_to_another_list(self):
        self.op(op="add", list=self.lid, text="milk")
        self.op(op="add", list=self.lid, text="bread")
        self.op(op="addList", name="Work")
        work = self.lists()[1]["id"]
        self.op(op="add", list=work, text="report")
        milk = self.lists()[0]["items"][0]["id"]
        self.assertTrue(self.op(op="moveTo", list=self.lid, item=milk, to=work))
        self.assertEqual(self.texts(0), ["bread"])
        self.assertEqual(self.texts(1), ["report", "milk"])
        self.assertTrue(self.s.doc["items"][milk]["deleted"])
        # Nowhere, to itself, or an item that is gone: nothing changes.
        bread = self.lists()[0]["items"][0]["id"]
        self.assertFalse(self.op(op="moveTo", list=self.lid, item=bread, to=self.lid))
        self.assertFalse(self.op(op="moveTo", list=self.lid, item=bread, to="nowhere"))
        self.assertFalse(self.op(op="moveTo", list=self.lid, item=milk, to=work))
        # A done to-do stays done.
        self.op(op="done", list=self.lid, item=bread, done=True)
        self.assertTrue(self.op(op="moveTo", list=self.lid, item=bread, to=work))
        moved = [it for it in self.lists()[1]["items"] if it["text"] == "bread"][0]
        self.assertTrue(moved["done"])

    def test_a_move_is_undone_to_the_same_place(self):
        for t in ("milk", "bread", "eggs"):
            self.op(op="add", list=self.lid, text=t)
        self.op(op="addList", name="Work")
        work = self.lists()[1]["id"]
        bread = self.lists()[0]["items"][1]["id"]
        self.assertTrue(self.op(op="moveTo", list=self.lid, item=bread, to=work, **{"as": "0123456789abcdef"}))
        self.assertEqual(self.lists()[1]["items"][0]["id"], "0123456789abcdef")
        # Undo: back where it was, the second of three.
        self.assertTrue(self.op(op="moveTo", list=work, item="0123456789abcdef", to=self.lid, at=1))
        self.assertEqual(self.texts(0), ["milk", "bread", "eggs"])
        self.assertEqual(self.texts(1), [])
        # A name already taken, or not one at all, gets a fresh one.
        milk = self.lists()[0]["items"][0]["id"]
        self.assertTrue(self.op(op="moveTo", list=self.lid, item=milk, to=work, **{"as": bread}))
        self.assertNotEqual(self.lists()[1]["items"][0]["id"], bread)
        eggs = [x["id"] for x in self.lists()[0]["items"] if x["text"] == "eggs"][0]
        self.assertTrue(self.op(op="moveTo", list=self.lid, item=eggs, to=work, at=0, **{"as": "../x"}))
        self.assertEqual(self.texts(1), ["eggs", "milk"])

    def test_moving_into_and_out_of_a_locked_list(self):
        self.op(op="add", list=self.lid, text="gift idea")
        self.op(op="addList", name="Gifts")
        gifts = self.lists()[1]["id"]
        self.assertTrue(self.s.set_lock(gifts, "1234"))
        idea = self.lists()[0]["items"][0]["id"]
        # Into it while it is open: sealed with its key.
        self.assertTrue(self.op(op="moveTo", list=self.lid, item=idea, to=gifts))
        rec = [r for r in self.s.doc["items"].values() if r.get("list") == gifts and not r.get("deleted")][0]
        self.assertNotIn("text", rec)
        self.assertIn("sealed", rec)
        self.assertEqual(self.texts(1), ["gift idea"])
        # Out of it while open: plain again.
        back = self.lists()[1]["items"][0]["id"]
        self.assertTrue(self.op(op="moveTo", list=gifts, item=back, to=self.lid))
        self.assertEqual(self.texts(0), ["gift idea"])
        # Locked again: nothing goes in or comes out.
        self.s.list_keys = {}
        again = self.lists()[0]["items"][0]["id"]
        self.assertFalse(self.op(op="moveTo", list=self.lid, item=again, to=gifts))
        self.assertEqual(self.texts(0), ["gift idea"])

    def test_export_as_markdown(self):
        self.op(op="renameList", list=self.lid, name="Shopping")
        self.op(op="add", list=self.lid, text="milk")
        self.op(op="add", list=self.lid, text="bread")
        self.op(op="done", list=self.lid, item=self.lists()[0]["items"][1]["id"], done=True)
        self.op(op="addList", name="Gifts")
        gifts = self.lists()[1]["id"]
        self.op(op="add", list=gifts, text="a book")
        self.s.set_lock(gifts, "1234")
        self.op(op="addList", name="Empty")
        self.s.list_keys = {}
        text = self.m.markdown(self.lists(), "2026-10-27")
        self.assertEqual(text, "# To-Do Lists\n\n_Exported 2026-10-27_\n\n## Shopping\n\n- [ ] milk\n- [x] bread\n\n"
                         "## Gifts\n\n_Locked: unlock it, then export again to include it._\n\n## Empty\n\n_Nothing to do._\n")
        self.assertNotIn("a book", text)
        # Written as a file of its own, only its owner can read.
        home = self.dir.name
        os.makedirs(os.path.join(home, "Documents"))
        old = os.environ.get("HOME")
        os.environ["HOME"] = home
        try:
            self.m.handle(self.s, {"cmd": "export"})
            self.m.handle(self.s, {"cmd": "export"})
        finally:
            os.environ["HOME"] = old
        files = sorted(os.listdir(os.path.join(home, "Documents")))
        self.assertEqual(len(files), 2)
        self.assertTrue(files[0].startswith("To-Do Lists ") and files[0].endswith(".md"))
        path = os.path.join(home, "Documents", files[0])
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertIn("- [ ] milk", open(path).read())
        self.assertTrue(self.s.notice["ok"])

    def test_tombstones_are_pruned(self):
        self.op(op="add", list=self.lid, text="x")
        iid = self.lists()[0]["items"][0]["id"]
        self.op(op="remove", list=self.lid, item=iid)
        self.assertTrue(self.s.doc["items"][iid]["deleted"])
        self.s.doc["items"][iid]["updated"] -= self.m.KEEP_TOMBSTONES + 60000
        self.m.prune(self.s.doc, self.m.now_ms())
        self.assertNotIn(iid, self.s.doc["items"])


class MergeTest(Base):
    def test_two_devices(self):
        m = self.m
        self.s.create("correct horse")
        lid = self.lists()[0]["id"]
        self.op(op="add", list=lid, text="milk")
        milk = self.lists()[0]["items"][0]["id"]
        other = m.Store()
        other.settings["device"] = "bbbbbbbb"
        other.opened(json.loads(json.dumps(self.s.doc)), self.s.dek, json.loads(json.dumps(self.s.header)), self.s.version)
        # Here: tick milk, add eggs. There: add bread, remove the milk later.
        self.op(op="done", list=lid, item=milk, done=True)
        self.op(op="add", list=lid, text="eggs")
        other.apply({"op": "add", "list": lid, "text": "bread"})
        merged = m.merge(self.s.doc, other.doc)
        self.assertEqual(m.merge(other.doc, self.s.doc), merged)
        self.s.doc = merged
        self.assertEqual(sorted(self.texts()), ["bread", "eggs", "milk"])
        self.assertTrue([x for x in self.lists()[0]["items"] if x["text"] == "milk"][0]["done"])
        other.doc = m.merge(other.doc, merged)
        other.apply({"op": "remove", "list": lid, "item": milk})
        self.s.doc = m.merge(self.s.doc, other.doc)
        self.assertEqual(sorted(self.texts()), ["bread", "eggs"])


class LockChangeTest(Base):
    """A lock changed on one device while another, offline, adds to it."""

    def two(self):
        m = self.m
        self.s.create("correct horse")
        self.lid = self.lists()[0]["id"]
        self.op(op="add", list=self.lid, text="first")
        self.assertTrue(self.s.set_lock(self.lid, "old1"))
        b = m.Store()
        b.settings["device"] = "bbbbbbbb"
        b.opened(json.loads(json.dumps(self.s.doc)), self.s.dek, json.loads(json.dumps(self.s.header)), self.s.version)
        b.unlock_list(self.lid, "old1")
        return b

    def b_texts(self, b):
        return [x["text"] for x in b.view()["lists"][0]["items"]]

    def test_lock_removed_meanwhile(self):
        m = self.m
        b = self.two()
        # Here the lock comes off; there, offline, a reminder is sealed with it.
        self.assertTrue(self.s.remove_lock(self.lid))
        self.assertTrue(b.apply({"op": "add", "list": self.lid, "text": "from the phone"}))
        # The phone hears of it: it still has the old key, so the reminder
        # becomes plain text at once.
        b.doc = m.merge(b.doc, self.s.doc)
        self.assertTrue(b.settle_keys())
        self.assertEqual(sorted(self.b_texts(b)), ["first", "from the phone"])
        self.assertFalse(any("sealed" in it for it in b.doc["items"].values() if not it.get("deleted")))
        self.s.doc = m.merge(self.s.doc, b.doc)
        self.assertEqual(sorted(self.texts()), ["first", "from the phone"])

    def test_heals_here_while_the_old_key_is_still_known(self):
        m = self.m
        b = self.two()
        self.s.remove_lock(self.lid)
        self.s.set_lock(self.lid, "new2")
        b.apply({"op": "add", "list": self.lid, "text": "from the phone"})
        self.s.doc = m.merge(self.s.doc, b.doc)
        self.assertTrue(self.s.settle_keys())
        self.assertEqual(sorted(self.texts()), ["first", "from the phone"])

    def test_password_changed_meanwhile(self):
        m = self.m
        b = self.two()
        # Here the password changes (off, then on with a new one) ...
        self.s.remove_lock(self.lid)
        self.s.set_lock(self.lid, "new2")
        # ... and there a reminder is sealed with the old one.
        b.apply({"op": "add", "list": self.lid, "text": "from the phone"})
        merged = m.merge(self.s.doc, b.doc)
        self.assertEqual(merged, m.merge(b.doc, self.s.doc))
        # The panel here closed meanwhile (the old key is gone); opened
        # again with the new password.
        self.s.list_keys = {}
        self.s.old_keys = {}
        self.s.doc = merged
        self.s.settle_keys()
        self.s.unlock_list(self.lid, "new2")
        # Here only the new key: that one is waiting for the old password.
        l = self.lists()[0]
        self.assertEqual(self.texts(), ["first"])
        self.assertEqual(l["stale"], 1)
        self.assertFalse(self.s.unlock_old(self.lid, "wrong"))
        self.assertTrue(self.s.unlock_old(self.lid, "old1"))
        self.assertEqual(sorted(self.texts()), ["first", "from the phone"])
        self.assertEqual(self.lists()[0]["stale"], 0)
        # Sealed with the new lock now: the new password alone opens it.
        self.s.list_keys = {}
        self.s.old_keys = {}
        self.s.unlock_list(self.lid, "new2")
        self.assertEqual(sorted(self.texts()), ["first", "from the phone"])

    def test_phone_heals_when_it_unlocks_with_the_new_password(self):
        m = self.m
        b = self.two()
        self.s.remove_lock(self.lid)
        self.s.set_lock(self.lid, "new2")
        b.apply({"op": "add", "list": self.lid, "text": "from the phone"})
        b.doc = m.merge(b.doc, self.s.doc)
        b.settle_keys()  # the old key is kept as an old one
        self.assertEqual(b.view()["lists"][0]["items"], None)
        b.unlock_list(self.lid, "new2")
        self.assertEqual(sorted(self.b_texts(b)), ["first", "from the phone"])
        self.assertEqual(b.view()["lists"][0]["stale"], 0)

    def test_forgotten_old_password(self):
        m = self.m
        b = self.two()
        self.s.remove_lock(self.lid)
        self.s.set_lock(self.lid, "new2")
        b.apply({"op": "add", "list": self.lid, "text": "lost"})
        self.s.list_keys = {}
        self.s.old_keys = {}
        self.s.doc = m.merge(self.s.doc, b.doc)
        self.s.settle_keys()
        self.s.unlock_list(self.lid, "new2")
        self.assertEqual(self.lists()[0]["stale"], 1)
        self.assertTrue(self.op(op="removeStale", list=self.lid))
        self.assertEqual(self.lists()[0]["stale"], 0)
        self.assertEqual(self.texts(), ["first"])


class FieldMergeTest(Base):
    def test_rename_there_lock_here(self):
        m = self.m
        self.s.create("correct horse")
        lid = self.lists()[0]["id"]
        self.op(op="add", list=lid, text="milk")
        iid = self.lists()[0]["items"][0]["id"]
        b = m.Store()
        b.settings["device"] = "bbbbbbbb"
        b.opened(json.loads(json.dumps(self.s.doc)), self.s.dek, json.loads(json.dumps(self.s.header)), self.s.version)
        self.s.set_lock(lid, "1234")
        self.op(op="done", list=lid, item=iid, done=True)
        b.apply({"op": "renameList", "list": lid, "name": "Shopping"})
        b.apply({"op": "move", "list": lid, "item": iid, "by": 0})
        self.s.doc = m.merge(self.s.doc, b.doc)
        l = self.lists()[0]
        self.assertEqual(l["name"], "Shopping")
        self.assertTrue(l["locked"])
        self.assertTrue(l["items"][0]["done"])

    def test_old_files_are_read(self):
        m = self.m
        old = {"v": 1, "lists": {"aaaaaaaa": {"name": "Old", "pos": 1, "updated": 5, "by": "x1x1x1x1"}},
               "items": {"bbbbbbbb": {"list": "aaaaaaaa", "text": "thing", "done": False, "pos": 1, "updated": 6, "by": "x1x1x1x1"}}}
        doc = m.tidy(old)
        self.assertEqual(doc["lists"]["aaaaaaaa"]["at"]["name"], [5, "x1x1x1x1"])
        self.assertEqual(doc["items"]["bbbbbbbb"]["at"]["done"], [6, "x1x1x1x1"])
        self.assertEqual(m.tidy(doc), doc)


class RecoveryTest(Base):
    def test_forgotten_password(self):
        self.s.create("correct horse")
        code = self.s.recovery_shown
        lid = self.lists()[0]["id"]
        self.op(op="add", list=lid, text="milk")
        self.s.save()
        self.s.forget()
        self.ring.clear()
        s2 = self.m.Store()
        s2.start()
        self.assertEqual(s2.view()["state"], "locked")
        self.assertFalse(s2.recover("0000-0000-0000-0000-0000-0000-0000-0000", "a new password!"))
        self.assertFalse(s2.recover(code, "short"))
        # Typed sloppily: lower case, spaces, O for 0.
        sloppy = code.lower().replace("-", " ").replace("0", "o")
        self.assertTrue(s2.recover(sloppy, "a new password!"))
        self.assertEqual([x["text"] for x in s2.view()["lists"][0]["items"]], ["milk"])
        s3 = self.m.Store()
        self.assertFalse(s3.unlock("correct horse"))
        self.assertTrue(s3.unlock("a new password!"))

    def test_change_password_keeps_other_devices(self):
        self.s.create("correct horse")
        dek = self.s.dek
        self.assertFalse(self.s.change_password("wrong one here", "another password"))
        self.assertTrue(self.s.change_password("correct horse", "another password"))
        self.assertEqual(self.s.dek, dek)
        s2 = self.m.Store()
        self.assertFalse(s2.unlock("correct horse"))
        self.assertTrue(s2.unlock("another password"))

    def test_list_recovery_and_new_list_password(self):
        self.s.create("correct horse")
        code = self.s.recovery_shown
        lid = self.lists()[0]["id"]
        self.op(op="add", list=lid, text="gift")
        self.s.set_lock(lid, "1234")
        lock_id = self.s.doc["lists"][lid]["lock"]["id"]
        self.s.list_keys = {}
        self.assertFalse(self.s.recover_list(lid, "0" * 32, "5678"))
        self.s.recover_list(lid, code, "5678")
        self.assertEqual(self.texts(), ["gift"])
        self.assertEqual(self.s.doc["lists"][lid]["lock"]["id"], lock_id)
        self.s.list_keys = {}
        self.assertFalse(self.s.unlock_list(lid, "1234") or self.lists()[0]["unlocked"])
        self.s.unlock_list(lid, "5678")
        self.assertEqual(self.texts(), ["gift"])
        # A new list password while unlocked: the to-dos stay as they are.
        sealed = self.s.doc["items"][self.lists()[0]["items"][0]["id"]]["sealed"]
        self.assertTrue(self.s.change_list_password(lid, "9999"))
        self.assertEqual(self.s.doc["items"][self.lists()[0]["items"][0]["id"]]["sealed"], sealed)
        self.s.list_keys = {}
        self.s.unlock_list(lid, "9999")
        self.assertEqual(self.texts(), ["gift"])
        # No new password: the recovery key takes the lock off.
        self.s.list_keys = {}
        self.s.recover_list(lid, code, "")
        self.assertFalse(self.lists()[0]["locked"])
        self.assertEqual(self.texts(), ["gift"])

    def test_version_1_file_is_made_anew(self):
        m = self.m
        # A version 1 file as the first build wrote it: the key from the
        # password, and a list locked the old way.
        salt = os.urandom(16)
        key = m.pbkdf2("old password", salt, 100000)
        lsalt = os.urandom(16)
        lkey = m.pbkdf2("1234", lsalt, 100000)
        sealed = m.b64e(m.seal(lkey, json.dumps({"text": "old secret"}).encode(), m.LIST_AAD))
        doc = {"v": 1,
               "lists": {"aaaaaaaa": {"name": "Old", "pos": 1, "updated": 5, "by": "x",
                                      "lock": {"salt": m.b64e(lsalt), "iter": 100000, "check": m.b64e(m.seal(lkey, b"ok", m.LIST_AAD))}}},
               "items": {"bbbbbbbb": {"list": "aaaaaaaa", "sealed": sealed, "done": False, "pos": 1, "updated": 6, "by": "x"}}}
        blob = m.seal(key, json.dumps(doc).encode(), m.AAD)
        env = {"format": "mani4.reminders", "v": 1, "kdf": {"name": "PBKDF2-SHA256", "iter": 100000, "salt": m.b64e(salt)},
               "iv": m.b64e(blob[:12]), "ct": m.b64e(blob[12:])}
        m.private_file(m.STORE, json.dumps(env))
        s = m.Store()
        s.start()
        self.assertEqual(s.view()["state"], "locked")
        self.assertFalse(s.unlock("wrong"))
        self.assertTrue(s.unlock("old password"))
        self.assertTrue(s.recovery_shown)
        with open(m.STORE) as f:
            self.assertEqual(json.load(f)["v"], 3)
        # The old lock opens with its password and is made anew in place.
        s.unlock_list("aaaaaaaa", "1234")
        self.assertEqual([x["text"] for x in s.view()["lists"][0]["items"]], ["old secret"])
        self.assertIn("kdf", s.doc["lists"]["aaaaaaaa"]["lock"])
        s.list_keys = {}
        s.recover_list("aaaaaaaa", s.recovery_shown, "4321")
        self.assertEqual([x["text"] for x in s.view()["lists"][0]["items"]], ["old secret"])


class NamesAndNewRecoveryTest(Base):
    def test_first_names_are_moved(self):
        m = self.m
        os.makedirs(m.OLD_DATA)
        with open(os.path.join(m.OLD_DATA, "reminders.enc"), "w") as f:
            f.write("old file")
        os.makedirs(os.path.dirname(m.OLD_SETTINGS), exist_ok=True)
        with open(m.OLD_SETTINGS, "w") as f:
            f.write('{"hotkey": "SUPER + R"}')
        self.ring["master"] = None  # nothing under the new name
        m.keyring_get = lambda kind, service=None: '{"dek": "x"}' if service == m.OLD_KEYRING else None
        stored = {}
        m.keyring_set = lambda kind, secret, label: stored.__setitem__(kind, secret) or "keyring"
        cleared = []
        m.keyring_clear = lambda kind, service=None: cleared.append(service)
        m.migrate_names()
        with open(m.STORE) as f:
            self.assertEqual(f.read(), "old file")
        self.assertFalse(os.path.exists(m.OLD_DATA))
        self.assertTrue(os.path.exists(m.SETTINGS))
        self.assertEqual(stored["master"], '{"dek": "x"}')
        self.assertEqual(cleared, [m.OLD_KEYRING])

    def test_new_recovery_key(self):
        self.s.create("correct horse")
        old_code = self.s.recovery_shown
        lid = self.lists()[0]["id"]
        self.op(op="add", list=lid, text="gift")
        self.s.set_lock(lid, "1234")
        self.assertTrue(self.lists()[0]["recoverable"])
        self.assertFalse(self.s.new_recovery("wrong password"))
        self.s.list_keys = {}
        self.assertTrue(self.s.new_recovery("correct horse"))
        code = self.s.recovery_shown
        self.assertNotEqual(code, old_code)
        # Locked meanwhile: wrapped for the old key until it is unlocked.
        self.assertFalse(self.lists()[0]["recoverable"])
        self.s.unlock_list(lid, "1234")
        self.assertTrue(self.lists()[0]["recoverable"])
        self.s.list_keys = {}
        self.assertFalse(self.s.recover_list(lid, old_code, "5678"))
        self.s.recover_list(lid, code, "5678")
        self.assertEqual(self.texts(), ["gift"])
        # The master password: the new key works, the old one does not.
        self.s.save()
        s2 = self.m.Store()
        self.assertFalse(s2.recover(old_code, "a new password!"))
        self.assertTrue(s2.recover(code, "a new password!"))


class UpgradeTest(Base):
    def make_v2(self):
        """A file as the first name wrote it: version 2."""
        self.m.CURRENT = 2
        self.s.create("correct horse")
        self.m.CURRENT = 3
        with open(self.m.STORE) as f:
            env = json.load(f)
        self.assertEqual((env["format"], env["v"]), ("mani4.reminders", 2))
        return self.s.recovery_shown

    def test_version_2_works_and_upgrades(self):
        old_code = self.make_v2()
        lid = self.lists()[0]["id"]
        self.op(op="add", list=lid, text="milk")
        self.s.save()
        self.assertTrue(self.s.view()["legacy"])
        # Still version 2 when it is opened again, and it works.
        s2 = self.m.Store()
        self.assertTrue(s2.unlock("correct horse"))
        self.assertEqual(s2.version, 2)
        s2.set_lock(lid, "1234")
        self.assertFalse(s2.upgrade("wrong password"))
        self.assertFalse(s2.upgrade("correct horse"))
        self.assertIn("Take the lock off", s2.notice["text"])
        s2.remove_lock(lid)
        self.assertTrue(s2.upgrade("correct horse"))
        self.assertEqual(s2.version, 3)
        self.assertFalse(s2.view()["legacy"])
        code = s2.recovery_shown
        self.assertNotEqual(code, old_code)
        with open(self.m.STORE) as f:
            raw = f.read()
        self.assertNotIn("mani4.reminders", raw)
        env = json.loads(raw)
        self.assertEqual((env["format"], env["v"]), ("mani4.todo-lists", 3))
        s3 = self.m.Store()
        self.assertTrue(s3.unlock("correct horse"))
        self.assertEqual([x["text"] for x in s3.view()["lists"][0]["items"]], ["milk"])
        s4 = self.m.Store()
        self.assertFalse(s4.recover(old_code, "a new password!"))
        self.assertTrue(s4.recover(code, "a new password!"))


class WebAppFileTest(Base):
    """A file the phone's web app wrote (todo-lists-web, tests/model.test.js
    writes tests/fixtures/web-v3.json): the plugin reads it as its own."""

    def test_the_web_apps_file_opens(self):
        m = self.m
        with open(os.path.join(HERE, "fixtures", "web-v3.json")) as f:
            fixture = json.load(f)
        m.private_file(m.STORE, json.dumps(fixture["env"]))
        s = m.Store()
        s.start()
        self.assertTrue(s.unlock(fixture["password"]))
        self.assertEqual(s.version, 3)
        # Its header is signed the way this script signs them.
        self.assertTrue(m.header_ok(s.dek, m.clean_header(fixture["env"]["header"]), m.LABELS[3]))
        lists = s.view()["lists"]
        self.assertEqual([l["name"] for l in lists], fixture["expect"]["names"])
        self.assertIn(fixture["expect"]["added"], [x["text"] for x in lists[0]["items"]])
        s.unlock_list(lists[1]["id"], fixture["listPassword"])
        self.assertIn(fixture["expect"]["sealed"], [x["text"] for x in s.view()["lists"][1]["items"]])
        s.list_keys = {}
        s.recover_list(lists[1]["id"], fixture["recovery"], "4321")
        self.assertIn(fixture["expect"]["sealed"], [x["text"] for x in s.view()["lists"][1]["items"]])
        # And the plugin's own change goes back in a file the web app reads.
        self.assertTrue(s.apply({"op": "add", "list": lists[0]["id"], "text": "z počítača"}))


class SignedHeaderTest(Base):
    def test_header_is_signed_and_checked(self):
        m = self.m
        self.s.create("correct horse")
        self.s.save()
        with open(m.STORE) as f:
            env = json.load(f)
        self.assertIn("mac", env["header"])
        header = m.clean_header(env["header"])
        self.assertTrue(m.header_ok(self.s.dek, header, m.LABELS[3]))
        # Anything changed in it (a later time, an old password block) is caught.
        forged = dict(header, at=header["at"] + 10**6)
        self.assertFalse(m.header_ok(self.s.dek, forged, m.LABELS[3]))
        # Unsigned: only when no newer than the header known here (it is
        # then never taken over), and never for a device that knows none.
        bare = {k: v for k, v in header.items() if k != "mac"}
        self.assertTrue(m.header_ok(self.s.dek, bare, m.LABELS[3], known=header))
        self.assertTrue(m.header_ok(self.s.dek, dict(bare, at=1), m.LABELS[3], known=header))
        self.assertFalse(m.header_ok(self.s.dek, dict(bare, at=header["at"] + 1), m.LABELS[3], known=header))
        self.assertFalse(m.header_ok(self.s.dek, bare, m.LABELS[3]))

    def test_an_unsigned_local_file_is_signed_on_start(self):
        m = self.m
        self.s.create("correct horse")
        env = m.envelope(self.s.doc, self.s.dek, self.s.header, 3)
        del env["header"]["mac"]
        m.private_file(m.STORE, json.dumps(env))
        s2 = m.Store()
        s2.start()
        self.assertEqual(s2.view()["state"], "ready")
        with open(m.STORE) as f:
            self.assertIn("mac", json.load(f)["header"])
        self.assertTrue(s2.dirty)

    def test_a_tampered_local_header_is_refused(self):
        m = self.m
        self.s.create("correct horse")
        with open(m.STORE) as f:
            env = json.load(f)
        env["header"]["at"] += 1
        m.private_file(m.STORE, json.dumps(env))
        s2 = m.Store()
        s2.start()
        self.assertEqual(s2.view()["state"], "error")
        self.assertFalse(s2.unlock("correct horse"))

    def test_argon2_limits(self):
        m = self.m
        ok = {"name": "Argon2id", "t": 3, "m": 65536, "p": 1, "salt": "abcdefghijklmnop"}
        self.assertTrue(m.clean_kdf(ok))
        self.assertIsNone(m.clean_kdf(dict(ok, m=1048576)))
        self.assertIsNone(m.clean_kdf(dict(ok, t=10)))


class FakeGitHub(http.server.BaseHTTPRequestHandler):
    files = {}
    private = True

    def log_message(self, *a):
        pass

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer " + "t" * 40:
            return self.reply(401, {"message": "Bad credentials"})
        if self.path == "/repos/me/data":
            return self.reply(200, {"private": FakeGitHub.private})
        name = self.path.split("/contents/", 1)[-1]
        if name not in FakeGitHub.files:
            return self.reply(404, {"message": "Not Found"})
        content, sha = FakeGitHub.files[name]
        self.reply(200, {"encoding": "base64", "content": content, "sha": sha})

    def do_PUT(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        name = self.path.split("/contents/", 1)[-1]
        current = FakeGitHub.files.get(name)
        if current and body.get("sha") != current[1]:
            return self.reply(409, {"message": "sha mismatch"})
        sha = os.urandom(8).hex()
        FakeGitHub.files[name] = (body["content"], sha)
        self.reply(201 if not current else 200, {"content": {"sha": sha}})


class SyncTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeGitHub)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        os.environ["TODO_LISTS_GITHUB_API"] = "http://127.0.0.1:%d" % cls.server.server_port

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        os.environ.pop("TODO_LISTS_GITHUB_API", None)

    def setUp(self):
        FakeGitHub.files = {}
        FakeGitHub.private = True
        self.dirs = [tempfile.TemporaryDirectory(), tempfile.TemporaryDirectory()]

    def tearDown(self):
        for d in self.dirs:
            d.cleanup()

    def device(self, n):
        m, ring = load(self.dirs[n].name)
        return m, m.Store()

    def test_two_computers_through_github(self):
        token = "t" * 40
        m1, a = self.device(0)
        a.create("correct horse")
        lid = a.view()["lists"][0]["id"]
        a.apply({"op": "add", "list": lid, "text": "milk"})
        a.save()
        self.assertTrue(a.connect("https://github.com/me/data", "", token, ""))
        a.sync_now()
        self.assertEqual(a.sync["state"], "ok", a.sync)
        self.assertIn("todo-lists.enc", FakeGitHub.files)
        stored = base64.b64decode(FakeGitHub.files["todo-lists.enc"][0]).decode()
        self.assertNotIn("milk", stored)
        # The token is kept sealed with the lists' key, not in plain text.
        with open(m1.TOKEN) as f:
            self.assertNotIn(token, f.read())
        self.assertEqual(stat.S_IMODE(os.stat(m1.TOKEN).st_mode), 0o600)
        again = m1.Store()
        again.start()
        self.assertEqual(again.token, token)

        # A second device joins with the password.
        m2, b = self.device(1)
        self.assertFalse(b.connect("me/data", "", token, "wrong password"))
        self.assertIsNone(b.doc)
        self.assertTrue(b.connect("me/data", "", token, "correct horse"))
        self.assertEqual([x["text"] for x in b.view()["lists"][0]["items"]], ["milk"])
        b.apply({"op": "add", "list": lid, "text": "eggs"})
        b.dirty = True
        b.sync_now()
        self.assertEqual(b.sync["state"], "ok", b.sync)

        a.apply({"op": "add", "list": lid, "text": "bread"})
        a.dirty = True
        a.sync_now()
        self.assertEqual(sorted(x["text"] for x in a.view()["lists"][0]["items"]), ["bread", "eggs", "milk"])
        b.sync_now()
        self.assertEqual(sorted(x["text"] for x in b.view()["lists"][0]["items"]), ["bread", "eggs", "milk"])
        # A new password on one device: the other goes on, and gets the
        # new header (a fresh start there asks for the new password).
        self.assertTrue(a.change_password("correct horse", "another password"))
        a.sync_now()
        b.sync_now()
        self.assertEqual(b.sync["state"], "ok", b.sync)
        self.assertEqual(m2.unsigned(b.header), m1.unsigned(a.header))
        b.save()
        b2 = m2.Store()
        self.assertTrue(b2.unlock("another password"))

    def test_a_version_2_file_is_updated_then_joined(self):
        token = "t" * 40
        m1, a = self.device(0)
        m1.CURRENT = 2
        a.create("correct horse")
        m1.CURRENT = 3
        lid = a.view()["lists"][0]["id"]
        a.apply({"op": "add", "list": lid, "text": "milk"})
        a.save()
        self.assertTrue(a.connect("me/data", "", token, ""))
        a.sync_now()
        # A version 2 header cannot be signed: a new device waits for the update.
        m2, b = self.device(1)
        self.assertFalse(b.connect("me/data", "", token, "correct horse"))
        self.assertTrue(a.upgrade("correct horse"))
        a.sync_now()
        stored = json.loads(base64.b64decode(FakeGitHub.files["todo-lists.enc"][0]))
        self.assertEqual(stored["v"], 3)
        self.assertIn("mac", stored["header"])
        self.assertTrue(b.connect("me/data", "", token, "correct horse"))
        self.assertEqual(b.version, 3)
        b.apply({"op": "add", "list": lid, "text": "eggs"})
        b.dirty = True
        b.sync_now()
        a.sync_now()
        self.assertEqual(sorted(x["text"] for x in a.view()["lists"][0]["items"]), ["eggs", "milk"])

    def test_a_header_changed_on_github_is_refused(self):
        token = "t" * 40
        m1, a = self.device(0)
        a.create("correct horse")
        self.assertTrue(a.connect("me/data", "", token, ""))
        a.sync_now()
        env = json.loads(base64.b64decode(FakeGitHub.files["todo-lists.enc"][0]))
        env["header"]["at"] += 10**6  # "newer", but not signed by the data key
        FakeGitHub.files["todo-lists.enc"] = (base64.b64encode(json.dumps(env).encode()).decode(), "forged")
        a.etag = None
        a.sync_now()
        self.assertEqual(a.sync["state"], "error")
        self.assertIn("header", a.sync["error"])
        m2, b = self.device(1)
        self.assertFalse(b.connect("me/data", "", token, "correct horse"))

    def test_public_repo_and_bad_token_are_refused(self):
        m, a = self.device(0)
        a.create("correct horse")
        FakeGitHub.private = False
        self.assertFalse(a.connect("me/data", "", "t" * 40, ""))
        self.assertIn("public", a.notice["text"])
        FakeGitHub.private = True
        self.assertFalse(a.connect("me/data", "", "u" * 40, ""))
        self.assertIn("token", a.notice["text"])
        self.assertNotIn("repo", a.settings)


if __name__ == "__main__":
    unittest.main()
