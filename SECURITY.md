# Security

To-Do Lists keeps your lists encrypted on your devices and in your own private GitHub repository. This page says
what that protects, how, and what it does not.

## What it protects against

- **GitHub, and anyone who gets the repository** (a leaked token, a stolen account): they see one encrypted file.
  Without the master password or the recovery key they cannot read a list or a to-do, and they cannot change the
  file's header (which carries the password and recovery wraps) without the devices noticing.
- **A lost laptop or phone that is locked**: the lists on it are the same encrypted file.
- **Someone at your unlocked computer** who does not know a **list password**: locked lists stay hidden; their
  to-dos are encrypted again with that password's key.

## What it does not protect against

- **Malware on your computer or phone**, or someone using it while the lists are open. On the computer, the master
  password's key is in your keyring, which any program running as you can read while you are logged in (as with
  passwords saved in a browser); Settings › Forget the master password here stops that. On the phone, the key is
  remembered in the app and the phone's own lock protects it.
- **Metadata**: GitHub sees when you sync (the commits' times), how large the file is, and your account. After the
  master password, the names of locked lists and how many to-dos they have are shown; only their text is locked.
- **A leaked old password together with the repository's history**: changing the master password or making a new
  recovery key does not replace the data key, so older copies of the file in the history open with the old one.
  If an old password or recovery key may have leaked, also delete the repository's history (or start a new
  repository).

## How

- **The file**: the lists are sealed with **AES-256-GCM** under a random 256-bit data key. The header wraps that
  key twice: with a key derived from the **master password** (**Argon2id**, 64 MiB, 3 passes, a random salt), and
  for the **recovery key** (160 random bits) through **P-256 ECDH** with HKDF-SHA256, so any device can wrap a new
  list's key for recovery without knowing the recovery key. The header is signed (**HMAC-SHA256**, a key derived
  from the data key with HKDF), and devices refuse a header that is not. Every sealed part carries a label of its
  own as associated data, so no part can be swapped for another.
- **Locked lists** have a random key of their own, wrapped with their list password (Argon2id) and for the recovery
  key. Their to-dos' text is sealed with it.
- **Limits**: a file may not ask for more than 256 MiB or 6 passes of Argon2id, so a changed file cannot freeze a
  device; files over 16 MiB are refused.
- **On the computer** (`bin/todo-lists`): the file is written as a fresh 0600 file in a 0700 folder; passwords,
  tokens and keys go to other programs (argon2, secret-tool, wl-copy) on stdin, never in their arguments; the
  token is kept encrypted with the data key; redirects never take the token to another host. The panel's fields are
  not Qt text fields (which read the whole clipboard), its texts are plain text, and the recovery key is copied as
  sensitive and cleared from the clipboard after a minute.
- **On the phone** ([MaNi4/todo-lists-web](https://github.com/MaNi4/todo-lists-web)): the browser's **WebCrypto**,
  and Argon2id in WebAssembly (hash-wasm). The data key and the signing key are kept as WebCrypto keys that cannot
  be read back out. The page may only talk to `api.github.com` (Content Security Policy), will not run inside
  another page's frame, and is served from a domain of its own, so no other site shares its storage.
- **Tests** check both apps against each other's files, signatures and syncing.

This design has not been reviewed by an independent auditor; the building blocks are standard (OpenSSL through
python-cryptography, the browser's WebCrypto, Argon2), the way they are put together is this project's.

## Reporting

Please report a security problem privately, through GitHub's **Report a vulnerability** on this repository, not in
a public issue.
