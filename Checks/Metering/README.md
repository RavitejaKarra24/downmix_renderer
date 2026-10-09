# Native metering regressions

```sh
Scripts/check_metering.sh
```

Strict format/typecheck and debug/optimized regressions execute the actual
`DownmixMeterNSView`, `MeterSource`, notifications and timers. The extractor copies
current product declarations verbatim, without test-side transport or ballistic
substitutes. No AppState, audio backend, preferences or hardware is instantiated.
Time, window visibility and Reduce Motion are controlled fixture inputs; real
window occlusion, system notifications and visual appearance remain manual gates.

AppState calls `MeterSource.reset()` on inactive transport statuses. Its durable
reset generation changes even when the snapshot is already empty. Native meters
clear displayed levels, all held peaks/deadlines and clipping immediately, then
suspend their settled timers. The generation also catches resets missed while a
view was unobserved. Ordinary running silence does not change it, so release and
peak history remain intact. New activity/window wakes resume only pending work.

Tests cover repeated reset of already-empty sources, clipping/peak clearing,
normal silent release, exact settlement, zero stopped repaint callbacks, restart,
hidden/unobserved views, source rebinding, sustained peaks and invalid levels.
The lifecycle suite separately verifies AppState reset intent. These tests do
not establish real-app CPU usage or pixel-level/audio-hardware qualification.
