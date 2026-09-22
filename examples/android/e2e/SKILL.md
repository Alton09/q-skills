---
name: e2e
description: >
  Run unattended Android end-to-end checks with Maestro and return a compact verdict.
  Use this skill after implementation when device-bound flows or [e2e] plan criteria
  need validation.
---

# E2E

Run the Android end-to-end suite from the assigned worktree. Do not prompt. This skill follows
`references/e2e.md` § "E2E Contract" and returns only its hand-back shape.

The 2026-09-19 MenuLens session `21163bb7` showed why this is separate from `/verify`: its
foreign worker ran only Gradle checks, while the independent gate booted an emulator, cleared
app state, launched the activity, and checked the seeded content with Maestro.

## Input

Accept the absolute worktree path and an optional list of `[e2e]` plan criteria. Run the normal
suite even when the list is empty.

```bash
cd "$WORKTREE"
```

Set these project-specific values before use:

```bash
E2E_AVD=<headless-test-avd>
E2E_PACKAGE=<application-id>
E2E_ACTIVITY=<application-id/.MainActivity>
E2E_EVIDENCE="/tmp/${E2E_PACKAGE//./-}-e2e-evidence"
mkdir -p "$E2E_EVIDENCE"
```

Keep the non-live Maestro flows in `.maestro/`. Each tagged criterion must name or map to a
non-live Maestro flow before it can be checked.

## 1. Reserve a Device

Reserve one device for the whole run before selecting it. Use an AVD-scoped lock that covers
selection, install, and Maestro. If the lock is held, do not use that device: return `env-error`.

```bash
exec 9>"/tmp/${E2E_AVD//[^[:alnum:]_-]/-}-e2e.lock"
flock -n 9 || { printf 'AVD lock held\n' > "$E2E_EVIDENCE/reservation-error.txt"; exit 1; }
```

Keep fd 9 open through install and Maestro so the reservation covers the whole run. On the
nonzero exit above, return the fixed-shape `env-error` hand-back with `E2E_EVIDENCE`.

Reuse `E2E_DEVICE_SERIAL` only when this run reserved it. Otherwise boot the dedicated AVD on
an unused emulator port. Do not select an arbitrary device from `adb devices`: it may belong to
another run.

```bash
E2E_EMULATOR_PORT=""
for candidate in $(seq 5554 2 5682); do
  if ! ss -ltn "sport = :$candidate" | grep -q LISTEN \
    && ! ss -ltn "sport = :$((candidate + 1))" | grep -q LISTEN; then
    E2E_EMULATOR_PORT="$candidate"
    break
  fi
done
[ -n "$E2E_EMULATOR_PORT" ] || exit 1
emulator -avd "$E2E_AVD" -port "$E2E_EMULATOR_PORT" -no-window -no-audio -no-boot-anim \
  -gpu swiftshader_indirect >"/tmp/${E2E_PACKAGE//./-}-e2e-emulator.log" 2>&1 &
E2E_DEVICE_SERIAL="emulator-$E2E_EMULATOR_PORT"
adb -s "$E2E_DEVICE_SERIAL" wait-for-device
until [ "$(adb -s "$E2E_DEVICE_SERIAL" shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do
  sleep 2
done
```

If boot, device readiness, or reservation fails, return `env-error` with the evidence directory.

## 2. Install and Prepare

Run these commands from the supplied worktree. An install failure is `env-error`.

```bash
ANDROID_SERIAL="$E2E_DEVICE_SERIAL" ./gradlew installDevDebug
adb -s "$E2E_DEVICE_SERIAL" shell pm clear "$E2E_PACKAGE"
adb -s "$E2E_DEVICE_SERIAL" shell am start -W -n "$E2E_ACTIVITY"
```

Clear state again before any flow or criterion that requires first-launch seeding. Launch the
activity explicitly after each clear; do not rely on Maestro to choose the launch state.

## 3. Run the Suite

Run the non-live Maestro suite. Let Maestro create its normal run directory under
`~/.maestro/tests/`; use that directory as `evidence`.

```bash
maestro --device "$E2E_DEVICE_SERIAL" test .maestro
```

Record each failed flow name. Re-run every failed flow once against the reserved device. A flow
that passes on that re-run is `flaky`; keep its Maestro output under the same evidence directory
and use `--device "$E2E_DEVICE_SERIAL"` for the re-run.

## 4. Check Tagged Criteria

After the suite, run the mapped non-live Maestro flow for each supplied `[e2e]` criterion. Clear
state and explicitly launch the activity first when the criterion requires first-launch state.
Re-run each failed criterion once. Count a passing re-run as `flaky`.

## Return Value

Return only the fixed shape from `references/e2e.md` § "Hand-back". `passed` counts suite flows
and tagged criteria that passed, including flaky items. `failed` contains only names that still
fail after their re-run. `flaky` is empty when none flaked. Do not return logs, failure messages,
or passing names; leave them under `evidence`.
