# AudioSplit

Per-app audio output routing for macOS. Send a video app to the laptop speakers
and a call app to your AirPods, at the same time.

Free and open source. macOS 14.4+. Not sandboxed (Core Audio process taps and
aggregate devices are unavailable inside the App Sandbox), so it is distributed
directly, not through the Mac App Store.

**Status: macOS app complete, with an iPhone and iPad remote.**

## Building

Requires the Swift 6 toolchain (Command Line Tools are enough for the engine and
the probe).

```
swift build                       # engine, app and CLI harnesses
swift test                        # reconciler and store tests
Scripts/make-app.sh AudioSplitApp # signed AudioSplit.app in dist/
open dist/AudioSplit.app
```

The SwiftPM package is the source of truth for the engine, the harnesses and the
tests. `AudioSplit.xcodeproj` builds, signs and ships the app, consuming the
engine as a local package product so the sources exist once. Regenerate it with
`python3 Scripts/generate-xcodeproj.py` after adding app source files.

## M1 — discovery spike

`audiosplit-probe` lists every audio-producing process and every audio device,
and shows how each process is mapped to the app a route would be keyed by.

```
audiosplit-probe                 # apps currently producing output, plus devices
audiosplit-probe --all           # every process object the HAL knows about
audiosplit-probe --verbose       # executable paths, ancestry, responsibility
audiosplit-probe watch           # reprint on process/device changes
```

### What the spike established

**The process that emits audio is usually not the app the user sees.** This is
the single most important finding, and it changes how routing has to work.

| Observed process | HAL bundle ID | Actually belongs to |
| --- | --- | --- |
| `com.apple.WebKit.GPU` (pid 1190) | `com.apple.WebKit.GPU` | Safari |
| `com.apple.WebKit.GPU` (pid 20157) | `com.apple.WebKit.GPU` | Netflix web app |
| `com.apple.WebKit.GPU` (pid 35812) | `com.apple.WebKit.GPU` | YouTube web app |
| `Brave Browser Helper` ×2 | `com.brave.Browser.helper` | Brave Browser |
| `Claude Helper` ×2 | `com.anthropic.claudefordesktop.helper` | Claude |

All WebKit media playback happens in `com.apple.WebKit.GPU`. There is one
instance per host app, every instance is re-parented to launchd (`ppid` 1), and
every instance reports the same bundle ID and the same display name. Parent
walking and bundle-ID matching cannot tell them apart.

`ProcessIdentityResolver` resolves the owning app with a ladder, outside-in:

1. the process is itself a dock-visible application → it speaks for itself;
2. macOS names a different process as *responsible* for it → use that app;
3. the executable lives inside an outer `.app` bundle → use the outermost one;
4. the HAL's bundle ID matches a registered application;
5. the PID belongs to some running application;
6. walk the parent chain;
7. unresolved — not routable, surfaced as such.

Step 2 uses `responsibility_get_pid_responsible_for_pid`, which is exported by
libsystem but not declared in a public header. It is resolved with `dlsym` at
runtime and never linked, so if it disappears the app degrades to steps 3–7
rather than breaking. It is the only SPI in the project and is confined to
`ResponsibleProcess.swift`. Without it, Chromium-family browsers still resolve
correctly (step 3) but Safari and every other WebKit app collapse into a single
unroutable key.

Two consequences worth knowing:

- Safari **web apps** get their own bundle IDs (`com.apple.Safari.WebApp.<UUID>`)
  and their own names, so "Netflix" and "YouTube" are separately routable.
- A command-line player started from a terminal is attributed to the terminal,
  because that is what macOS's responsibility chain says. This matches how TCC
  attributes permissions and is intentional.

### Verified on this machine

macOS 26.6.2, Swift 6.3.3. Live output detection (`isRunningOutput`, the
per-process output device list) confirmed against a playing process. Device
enumeration returns names, UIDs, channel counts, sample rates and transport
types for built-in, Bluetooth, Continuity and aggregate devices, and flags the
current default input, default output and system output.

## M2 — one hardcoded route

Taps one app, builds an aggregate device around one output device, and copies
tap input to device output in a single IOProc. No UI, no persistence.

```
./Scripts/make-m2-app.sh
open "dist/AudioSplit M2.app" --stdout /tmp/m2.log --stderr /tmp/m2.log \
  --args --app com.apple.Safari --to "MacBook Pro Speakers"
tail -f /tmp/m2.log
pkill -INT -x audiosplit-m2      # tears down tap, aggregate and IOProc
```

The meter shows peak level per second. Silence means the tap is delivering
nothing; a level means audio is moving.

### Two findings that cost real time

**A Swift 6 closure written inside a `@MainActor` type cannot be an IOProc.**
It inherits main-actor isolation, and the compiler injects a
`swift_task_isCurrentExecutor` check — a `dispatch_assert_queue` — at the top of
it. On the realtime IO thread that assertion fails on the very first callback:

```
_dispatch_assert_queue_fail
swift_task_isCurrentExecutorWithFlags
closure #1 in RouteEngine.startRoute(...)
HALC_ProxyIOContext::IOWorkLoop()
```

The block is therefore built by `makeRouteIOBlock`, a file-scope nonisolated
function. This is invisible in review — the code looks correct either way — so
the rule is: IOProc blocks are constructed outside any actor-isolated context,
always.

**A process tap returns silence, not an error, until TCC grants audio capture.**
`AudioHardwareCreateProcessTap` succeeds, the aggregate builds, the IOProc runs
at the right rate with the right buffer geometry, and every sample is zero. A
global tap of the entire system behaves the same way, which is what separates
"not authorised" from "wrong processes tapped".

TCC will not grant a binary that has no bundle identity, and a binary launched
from a terminal inherits the terminal's responsibility, so it can never be
granted on its own behalf. The tool therefore has to run as a signed `.app`
launched via `open`. Once it does, audio flows immediately.

Practical consequence for later milestones: anything that creates a tap must be
a signed bundle with `NSAudioCaptureUsageDescription`, and silence must be
treated as a first-class diagnostic state — it is the symptom of a permission
problem, a DRM-protected stream, and an uncapturable app alike.

**`dispatchMain()` invalidates `MainActor.assumeIsolated`.** Under
`dispatchMain()` the main queue may be drained by a worker thread rather than
the main thread, so a handler scheduled on `.main` is not on the MainActor's
executor. Swift 6.4 diagnoses this as a data race; Swift 6.3 let it through
silently. Use `RunLoop.main.run()`.

### Verified on this machine

A 25-second 440/660 Hz test tone played by a process whose default output was
AirPods, routed to the built-in speakers, arrived at the destination at
-11.2 dBFS — the tone's own level. Aggregate input and output both negotiated
48 kHz stereo float32 interleaved, 512-frame buffers, tap channel offset 0.
Teardown left no aggregate in the device list and no stray process.

Toolchains: Swift 6.3.3 (Command Line Tools) and Swift 6.4 / Xcode 27, macOS
26.6.2.

## M3 — generalized engine

N routes to N destinations, driven by a reconciler, reacting to apps and devices
appearing and disappearing.

```
Scripts/make-app.sh audiosplit-m3
open "dist/AudioSplit M3.app" --stdout /tmp/m3.log --stderr /tmp/m3.log --args \
  --route com.apple.Safari="MacBook Pro Speakers" \
  --route com.apple.Music="AirPods"
tail -f /tmp/m3.log

.build/debug/audiosplit-m3 --churn 25 --route com.apple.Safari="MacBook Pro Speakers"
.build/debug/audiosplit-m3 --orphans
```

### The reconciler

`RouteReconciler` imports no Core Audio. It takes desired routes, the set of
connected devices and the current process objects per app, and returns the
actions needed to make the hardware match, plus a status per route. It is
idempotent: reconciling against the state it just asked for produces nothing.

Every event funnels into the same call — app start, app quit, device plug,
device unplug, wake from sleep, user edit. 15 unit tests cover the cases that
matter, including the ones that are awkward to reproduce on hardware: a device
being unplugged parks its routes instead of deleting them, an app quitting tears
down its aggregate but keeps the route, moving an app between devices destroys
before it creates, and two routes claiming the same app resolve deterministically
instead of double-tapping it.

One aggregate exists per *destination*, not per route. Apps sharing a
destination share one tap, one aggregate and one IOProc, so N destinations means
N IOProcs no matter how many apps are routed.

### Taps are updated in place

An app's set of audio processes changes constantly — browser helpers and
renderers come and go per tab. Rebuilding the aggregate each time would glitch
the audio, so `TapController.setProcessObjectIDs` reads the live description,
mutates its process list and writes it back, preserving the tap's UUID and
therefore the UID the aggregate refers to.

Measured: with one tone playing, the route sat at -11.2 dBFS; starting a second
process for the same app logged `update (2 procs)` rather than a rebuild, and
the level moved to -5.3 dBFS — the +6 dB of two identical tones summing into one
tap, with no dropout.

Processes that are alive but silent are included in the tap deliberately. A tap
that already covers them captures the first buffer of audio, instead of letting
it leak to the old device while we notice and catch up.

### Aggregate destruction is asynchronous

`AudioHardwareDestroyAggregateDevice` returns `noErr` well before the HAL removes
the device from `kAudioHardwarePropertyDevices`. Scanning immediately after
teardown reports a device that is already dead — which looks exactly like a leak.
Poll for disappearance rather than trusting a single read. This matters for M6's
"restore all audio to normal", which must not report failure prematurely.

### Verified on this machine

25 churn cycles over 2 routes created and destroyed 50 aggregates with nothing
left behind. Two simultaneous routes to two destinations ran with independent
level metering. Starting and stopping apps produced `create`, in-place `update`
and `destroy` in the right order, with routes preserved across their apps
quitting. Teardown left no aggregate devices and no stray processes.

## M4 — menu bar app

A `MenuBarExtra` listing every route: which app, which device, volume, mute, a
live peak meter and why a route is or is not working. Routes are added from a
picker that lists apps currently using audio, with the ones actually making noise
first. Everything is persisted to `~/Library/Application Support/AudioSplit/routes.json`.

### A flaw in the original design, and the fix

The spec called for one tap per *destination*, shared by every app routed there.
That cannot work, because `CATapDescription(stereoMixdownOfProcesses:)` mixes the
processes it covers down to stereo inside the tap. Two apps sharing a tap arrive
already summed, so per-route volume, mute and delay — features 2 and 3 — are
impossible to apply to either of them.

AudioSplit therefore creates one tap per *route* and puts all of a destination's
taps in the same aggregate. Every hard constraint survives: one aggregate and one
IOProc per destination, one clock, no ring buffer, no sample rate conversion. The
aggregate presents one input buffer per tap in tap-list order, so the IOProc
applies each route's gain and sums them onto the destination.

Measured: routing a 440/660 Hz tone at 100% arrived at -11.2 dBFS; the same route
at 25% arrived at -23.3 dBFS, against a predicted -23.2.

### Volume is not topology

Gain and mute are pushed to the realtime thread as relaxed atomics and are
deliberately absent from `AggregateSpec`. If they were part of it, every frame of
a slider drag would look like a structural change and tear down the audio path.
A unit test pins this: changing volume and mute produces zero reconciler actions.

Mute is a gain of zero rather than a teardown, so unmuting is instant and does
not repeat the tap-and-aggregate setup.

### Atomics without raising the deployment floor

Swift's `Synchronization.Atomic` requires macOS 15; AudioSplit supports 14.4. The
realtime parameter block is therefore a small C struct with relaxed atomic
accessors (`Sources/CAudioSplitAtomics`), which on arm64 compile to plain aligned
loads and stores. The accessors take the whole slot rather than a field address
on purpose — Swift's inout-to-pointer conversion may hand back a temporary copy,
which would silently make the operation non-atomic.

### Silence is a first-class state

A tap with no audio-capture permission succeeds, runs, and returns silence. There
is no error anywhere. The app watches for routes that are active but have never
produced a sample and surfaces a banner pointing at Privacy & Security, because
that is the only signal macOS gives.

## M5 — delay and input switching

A per-route delay slider up to 500 ms, a system input switcher in the menu, and a
global hotkey that flips between two input devices.

### The delay line

`RingBuffer.swift` holds the only ring buffer in the project, and it exists
solely to delay one route. It never bridges two devices — the aggregate does
that, on one clock, in one IOProc. If a ring buffer ever appears between two
IOProcs, the design has gone wrong.

Storage is sized for the 500 ms cap at route creation, from the aggregate's real
sample rate and the largest block the device says it may ask for, plus a full
block of headroom so a maximum delay can never collide with the block being
written. Changing the delay moves a read offset; nothing reallocates, and the
realtime thread only ever reads a frame count — milliseconds are converted on the
control thread so the IOProc never divides or touches the sample rate.

The delay line is fed even when a route is muted. Skipping it would leave stale
audio in the buffer, and unmuting would replay it.

Seven unit tests cover it directly: zero delay is pass-through, a delay shifts by
exactly the requested frames, a partial delay lines up across block boundaries,
audio survives wrapping the buffer several times, and an excessive delay is
clamped rather than reading uninitialised memory.

### Input switching

`kAudioHardwarePropertyDefaultInputDevice` is settable, so this is the same
system-wide change the Sound pane makes. It is not routing and involves no taps —
per-app *input* routing is explicitly out of scope.

The hotkey uses Carbon's `RegisterEventHotKey`. An `NSEvent` global monitor would
also work, but it needs Accessibility access — a much larger ask than this
feature justifies, and one that would put AudioSplit in the same privacy bucket
as a keylogger. It is off by default and needs two devices chosen before it can
be enabled.

### Verified on this machine

The delay line's behaviour is pinned by unit tests rather than by listening.
End to end, a routed tone measured -11.2 dBFS with no delay and -11.2 dBFS with
400 ms of delay — identical level, so the delay path neither attenuates nor
corrupts. Switching the default input to another device and back worked through
the same call the UI makes.

## iPhone and iPad

There is no iOS port of the routing engine, and there cannot be one.

Verified against the iOS 27 SDK: `AudioHardware.h` and `AudioHardwareTapping.h`
are not present, and `AudioHardwareCreateProcessTap`,
`AudioHardwareCreateAggregateDevice`, `AudioDeviceCreateIOProcIDWithBlock`,
`AudioObjectGetPropertyData`, `kAudioHardwarePropertyProcessObjectList` and
`CATapDescription` do not exist there at all. iOS has no Core Audio HAL. More
fundamentally, AudioSplit works by capturing other apps' audio and muting them
at the source, which is exactly what the iOS sandbox exists to prevent — a tap
API on iOS would be a system-wide eavesdropping primitive.

What does work is a remote control. `AudioSplitRemote` is a SwiftUI app for
iPhone and iPad that drives the Mac over the local network: add and remove
routes, change destinations, volume, mute and delay, switch the system input and
output, and hit Restore All Audio from across the room. No audio crosses the
wire — only state and intent.

```
open AudioSplit.xcodeproj      # schemes: AudioSplit (macOS), AudioSplitRemote (iOS)
```

On the Mac, turn it on under **Remote → Allow remote control**; it is off by
default. Pair by typing the six-character code the Mac shows.

### Why a pairing code rather than open on the LAN

AudioSplit is deliberately not sandboxed and can mute or re-route every app on
the machine. An unauthenticated listener would hand that to anyone on the same
network. The connection is TLS with a pre-shared key derived from the pairing
code, so an unpaired device fails the handshake — there is no unauthenticated
request to reject later, and nothing readable on the wire. Bonjour advertises
the service for discovery, but discovery is not authorisation. Issuing a new
code drops every paired device, which is how you revoke one.

### The module split

`AudioSplitShared` holds everything both platforms can use: the `Route` and
`Preferences` models, `DelayLimits`, and the wire protocol and transport.
`AudioSplitEngine` holds everything that requires the HAL. The boundary is
checked rather than assumed — `AudioSplitShared` typechecks for
`arm64-apple-ios17.0` on the device and simulator SDKs, and `AudioSplitEngine`
deliberately does not.

### App Store

The iOS remote can ship to the App Store; it touches no restricted API. The
macOS app cannot — process taps and aggregate devices do not work under App
Sandbox, which the Mac App Store requires. macOS distribution is Developer ID
plus notarization.

## Building a release

```
Scripts/make-dmg.sh                    # release build, signed, wrapped in a DMG
Scripts/notarize.sh dist/AudioSplit-1.0.dmg
```

`make-dmg.sh` refuses to package an app without Hardened Runtime, since
notarization would reject it later and the failure is easier to read here.

### Hardened Runtime and taps

Whether Core Audio process taps survive Hardened Runtime was the last unverified
assumption in the project, and it mattered because notarization requires it.
They do. A build signed `flags=0x10000(runtime)` with
`com.apple.security.device.audio-input` captures a routed tone and shows level
on the meter. Signing applies it by default; `HARDENED=0 Scripts/make-app.sh
AudioSplitApp` builds without it for comparison when debugging a capture
failure.

### What you need to distribute

An **Apple Development** certificate is enough for your own Mac. On anyone
else's, Gatekeeper rejects it — verifiable with
`spctl --assess --type execute dist/AudioSplit.app`, which reports `rejected`
for an un-notarized build. Distribution needs a paid Apple Developer Program
membership, a Developer ID Application certificate, and notarization.

The Mac App Store is not an option at all: process taps and aggregate devices do
not work under App Sandbox, which the store requires.

### Only one copy at a time

Two instances each hold their own `mutedWhenTapped` taps. When both tap the same
app, its audio is pulled out of its original path twice and neither instance can
tell — each sees a healthy route, a live aggregate and a running IOProc while
the user hears nothing. A second copy therefore refuses to start.

The check lives in `AppModel.init`, not in an `NSApplicationDelegate` callback:
SwiftUI constructs `@State` before any delegate hook runs, and a guard in the
delegate let the second copy load routes, register the hotkey and open its
remote listener before quitting. The milestone harnesses keep their own bundle
identifiers and are allowed to run, but are named in Activity, because a
leftover harness holding a tap on Safari is exactly the invisible failure this
guards against.

## License













MIT.
