# Engine sync, engine store and engine updates

- engine-01: The patch queue applies to the pin.
- engine-02: A latest.json whose signature does not verify is never acted on.
- engine-03: A downloaded engine tree whose .engine-id is not the one the manifest names is refused.
- engine-04: A changed series or pin makes engine/ stale, and sync rebuilds it.
- engine-05: A commit in engine/ makes the checkout's engine stale, on the Mac and on Windows.
- engine-06: On this Mac, the engine the launcher's preferences name is in its engine store with that .engine-id.
- engine-07: Given the folder tools/try-pr made for a candidate, the app carries the engine its latest.json names, and after the first start the launcher uses it.
