# Fitness Smart: Hive web transaction patch — reconstructed, locally tested

This directory is reconstructed from the public Apache-2.0 Hive 2.2.3 archive
SHA-256 `8dcf6db979d7933da8217edcec84e9df1bdb4e4edc7fc77dbd5aa74356d6d941`.
The license is in `LICENSE`. Relative to that archive, the reconstructed web
transaction patch changes `lib/src/backend/js/native/storage_backend_js.dart`
(SHA-256 `68c9c3127384ca576841a1c58120dfe5c497b291802ac65d813838aad1292a56`).
A later, unshipped candidate also changes three box implementation files:
`lib/src/box/box_base_impl.dart`, `box_impl.dart`, and `lazy_box_impl.dart`.
Their exact tested hashes are recorded with the synthetic browser and VM
results; `keystore.dart` and the web backend were not changed by that later
candidate. The subsequent unshipped startup-recovery candidate also changes
`lib/src/hive_impl.dart`; its exact source hash and tests are recorded with the
+39 build and startup evidence.

**Important:** the previously tested local +26 backend had SHA-256
`8e666419aa85dde050445346495a102afba2e27d282a44012fdba2439197cf59`.
It disappeared when the workspace was restored after an out-of-memory failure.
The current source was independently reconstructed and is **not byte-identical**.
It was compiled to JavaScript and tested separately in disposable Chromium:
`checks/hive_web_commit_reconstructed.json` records **17 browser + 23 Dart
checks PASS**, with its current source hash. Historical `checks/hive_web_commit.json`
and +26 browser results apply to the old hash, not this backend.

The intended change encodes a write batch before opening a transaction,
attaches terminal `complete`/`abort` listeners before scheduling any requests,
schedules the batch without intermediate awaits, observes each request error,
attempts to abort on errors, and resolves only after the terminal event.
`clear()` also waits for the terminal event. This does not change the IndexedDB
schema, fix uncooperative legacy tabs, make cloud documents atomic, or guarantee
physical storage flush on every browser/OS/hardware failure. Hive web `flush()`
remains a no-op.

A separate `Box.clear()`/`Box.put()` memory-versus-persistence race was
reproduced in synthetic boxes. The later candidate adds an **in-isolate, per-box**
interlock: clear waits for admitted writes and explicit compactions (including
an admitted write's automatic compaction), then clears the backend and memory.
While clear is active, new writes, another clear, explicit compact, close and
`deleteFromDisk` fail with `HiveError`; they are **not queued or retried**.
The caller must handle the error and deliberately retry after clear finishes.
A previous write's failure is returned to its own caller; it does not by itself
cancel an already requested clear. Abort of clear releases the interlock.
Reads and `flush()` are not fenced. Close/delete versus ordinary writes or
compaction, parallel writes, other boxes, processes and tabs are not fixed by
this candidate. Existing watcher events can still be optimistic for writes and
rolled back on failure; see `HIVE_WRITE_SAFETY.md` for tested cases and limits.

A separate startup candidate observes the error on the internal `_openingBoxes`
coordination Future by attaching a `then<void>` error handler. The first open
caller still gets the rethrown error; other concurrent callers continue to
await the unchanged original Future and get the same error. This prevents an
unobserved duplicate zone error when there are no other waiters; it does not
hide errors from those callers, repair a failed backend or guarantee retry.
Synthetic `test/hive_open_failure_test.dart` exercises one caller, concurrent
waiters and a subsequent successful open. A browser injects an artificial
version-1 open denial; it is not a real quota or crash test. `then` avoids the
`Future.ignore()` API that requires Dart 2.14, but this vendor package's stated
Dart 2.12 minimum was not separately executed or verified. See
`STARTUP_RECOVERY_SAFETY.md`; do not infer release approval.

The application currently uses `LocalPreferences.clear()` (per-key removals),
and no direct `Box.clear()` call was found under `lib/`; the low-level test is
not proof of a real diary bug. No real user data was used. Browser
upgrade/rollback tests, real independent recovery, multi-tab coordination and
all other gates in `HIVE_WRITE_SAFETY.md`, `TAB_SAFETY.md`, and
`MIGRATION_RELEASE_GATE.md` remain necessary. These patches are not release
authorization.
