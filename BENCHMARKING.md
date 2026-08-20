# Benchmarking Central in Roblox Studio

A runbook for measuring `central`'s performance from a Claude Code session,
written from what actually worked (and what didn't) while re-measuring the
`## Performance` section of the README. Read this before re-deriving the
approach from scratch.

## The setup

- **Library**: this repo (`central`), a Wally package with no place file of
  its own.
- **Host game**: a separate Roblox project that vendors this library under
  `Packages/_Index/<owner>_central@<version>/central/lib`, which Rojo maps
  into `ReplicatedStorage.Packages._Index[...].central`. You need a host
  game with Rojo already wired up to benchmark against Studio at all.
- **Rojo**: `rojo serve default.project.json` in the host game's directory,
  with the Studio Rojo plugin connected. Check `netstat -an | grep 34872`
  before assuming you need to start a server — one may already be running.
  **The Studio plugin's connection can silently drop** (observed mid-session,
  no error, `netstat` still showed the server listening) — if new files stop
  appearing after a sync, that's the first thing to check, and reconnecting
  requires a human to click "Connect" in the plugin panel; it isn't
  scriptable from here.
- **Getting library code into Studio**: edit files under the vendored path
  directly (Rojo watches `Packages/`, not this repo), or edit here and mirror
  over with a small copy script. Either way, Rojo only syncs into Studio's
  **Edit**-mode datamodel. A running **Play** session snapshots that at the
  moment it starts and does not keep live-syncing — if a Play-mode test needs
  a file that didn't exist yet, sync it into Edit mode first, then start Play.

## You almost never need Play mode

If the code path you're measuring doesn't depend on `RunService` timing or
other engine scheduling, drive it directly:

```lua
local backend = HistoricalRefit.new(FRAME_CAP, AABB_PADDING)
backend:AddPart(PartRegister.new(part, FRAME_CAP, nil))
backend:UpdateFrame(1)
local hitbox, point, dist = backend:QueryRaycast({Name = "Ghost"} :: any, ...)
```

A plain Lua table stands in for a `Player` if the code only reads
`player.Name`. Build scratch parts in `ServerStorage` (a `PartRegister`
generally only cares that `part.Parent ~= nil`) and destroy them after. This
is synchronous, runs in `Edit` mode via `execute_luau`, and iterates far
faster than injecting a script and pressing Play. Only reach for Play mode
when you specifically need real engine scheduling — see
[Testing under a real simulation](#testing-under-a-real-simulation).

## Comparing two versions of code

To A/B an old commit, a different setting, or an experimental change against
current code in the *same* running Studio session:

1. `git show <rev>:path/to/File.luau > VendoredPath/FileOld.luau` — copy the
   other version in **beside** the current one, under a different name, in
   the same folder. Relative requires (`script.Parent.X`) still resolve,
   since both copies share the same neighbors.
2. For a single-file change (e.g. a different `GJK_TOLERANCE`), `sed` the one
   line that reads the setting, and `sed` whichever consumer's require to
   point at the new file:
   ```bash
   sed 's/local GJK_TOLERANCE = Settings.GJK_TOLERANCE/local GJK_TOLERANCE = 1e-4/' \
     HistoryQueries.luau > HistoryQueriesGjk1e4.luau
   sed 's/require(script.Parent.HistoryQueries)/require(script.Parent.HistoryQueriesGjk1e4)/' \
     HistoricalRefit.luau > HistoricalRefitGjk1e4.luau
   ```
3. **To isolate a code change from a settings change**, leave the old code's
   `require(...Settings)` pointed at the *current* `Settings.luau` rather
   than reconstructing the old settings file. Both old and new code then read
   identical settings automatically, and the only variable left is the code.
   Only fork a setting locally (step 2) when the setting itself is what
   you're varying.
4. If the old code depends on a module whose *shape* changed, not just its
   settings — this bit harder than it looks. Comparing this branch's HEAD
   against `master` needed the old `HistoricalHitboxes.luau`, the old
   `PartRegister.luau`, a `FrameRegister.luau` that had since been deleted
   entirely, and a whole pre-`0.9.0` copy of `lib/bolt` (bolt files require
   each other via `require("@self/...")`, which resolves relative to the
   requiring module regardless of its folder's name, so the copy can live
   anywhere and just needs `git show`-ing out file by file). Check what a
   commit's version of a file actually requires before assuming a one-file
   swap is enough.
5. **Delete all of it afterward.** `HistoricalHitboxesOld.luau`, `boltMaster/`,
   etc. are not meant to be committed. Verify with `git status` in the
   vendoring repo that it matches its state before you started.

## The `require()` cache will lie to you

`require()` caches per **Instance**, not per source text. If you edit a file
Rojo already synced and that has already been `require()`'d once this
session, re-`require()`ing the same Instance returns the **stale** cached
result — Rojo overwriting `.Source` does not bust the cache. Symptoms: a
fixed compile error still throws the old error, or an added field/function
reads back as `nil`.

Two ways out:

- **For a file you'll edit once or twice**: destroy the Instance and force a
  real Rojo resync (a no-op file touch may not be enough to trigger one —
  make an actual content change, even just an added blank line, then verify
  with `WaitForChild` that the new Instance actually reappeared before
  trusting anything downstream of it).
- **For a harness module you're iterating on rapidly**: skip `require()`
  entirely. Use `loadstring(instance.Source)()` instead — it recompiles and
  re-executes the current `.Source` fresh every call, with no caching. The
  cost: code loaded this way has no `script` variable, so it can't use
  `script.Parent`-relative requires; write such a module's own requires as
  absolute `game.ReplicatedStorage...` paths instead. This is what let
  iteration on a benchmark harness module stay fast without fighting the
  cache every edit.
- **When you need a guaranteed-fresh Instance immediately** (e.g. adding a
  counter to a copy of a query module you're about to use in the same
  breath): build the ModuleScript from a string and `require()` it in the
  *same* `execute_luau` call — a same-call Instance was never cached before,
  so there's nothing stale to hit.

One more trap in this family: **don't read a large generated Luau file back
into your own context to paste it into a tool call.** A ~300-line file is
fine; a 2000-line one (a single bolt module, or several files concatenated
for one injection) can burn tens of thousands of tokens for no reason. If a
file set is large, prefer letting Rojo sync it normally (stop Play, sync to
Edit, resume Play) over hand-injecting it through `execute_luau`. Reserve
direct injection for genuinely small, single-purpose files.

## Timing methodology

- **`os.clock()` here is a wall clock, not this script's CPU time.** Observed
  values in the tens of thousands of seconds — it's relative to some
  long-running session epoch, and it keeps advancing through real elapsed
  time regardless of what's executing, including time between tool calls.
  This matters a lot if anything you're benchmarking has its own real-time
  periodic cost (this codebase's `TREE_REBUILD_CHECK_INTERVAL` is a genuine
  10 *seconds*, checked against this same clock). A single batched
  measurement whose own wall-clock duration approaches that interval has a
  real chance of the periodic event firing **during** the measurement,
  landing inside every batch so `min()` can't filter it out. Confirmed
  directly in this session: an 800-hitbox capture-cost test batch that took
  ~3.8 seconds of wall time sometimes came back clean and sometimes didn't,
  depending on where in the 10-second cycle it started; shrinking the same
  test to ~0.4 seconds made it reliably clean. **Keep each batched
  measurement's total wall-clock duration well under the shortest real-time
  interval anything in the system cares about**, not just "long enough to
  feel statistically solid" — a longer run can manufacture the exact spike
  it was trying to average away.
- **Batch, don't time single calls.** Time `batchSize` consecutive calls in
  one `os.clock()` bracket and divide, rather than timing each call
  individually — this averages out per-call timer resolution and overhead.
  Repeat for several batches and take the **median or minimum** across
  batches (not a single batch). Minimum is the right choice specifically for
  filtering out one-sided stalls like the rebuild spike above, since a stall
  can only inflate a batch, never deflate one — as long as no single batch is
  long enough to always contain one.
- **Always discard a warmup batch** before the first timed one.
- **Keep unrelated setup out of the timed window, even inside a batch.** If
  each iteration needs some state change first (e.g. moving every hitbox
  before capturing it, so `tree:move()` takes its real remove-and-reinsert
  path instead of a cheap no-op when the move is smaller than
  `AABB_PADDING`), do that setup for the *whole batch* first, then time only
  the batch of actual calls. Mixing them in gives you the cost of the setup,
  not the thing you meant to measure — this produced numbers 30× too high
  the first time through this session, from timing `part.CFrame = ...`
  writes for dozens of parts alongside the capture call they were supposed
  to just be feeding.
- **Give each compared case its own fresh instance.** Reusing one backend
  across several sequential measurements lets earlier activity (a capture
  test that moved parts hundreds of times, a query that happened to trigger
  a rebuild) leave it in a different state than a cold one, contaminating
  whatever you measure next on it. Destroy and rebuild between cases, and
  call `:Destroy()` on backends and containers when done with them, both for
  correctness and to keep GC pressure from bleeding into later measurements
  within the same `execute_luau` call.

## Don't trust a synthetic "worst case" rig — instrument it

A scenario built to be "grazing" or "the expensive case" by construction can
silently fail to actually exercise the mechanism you think it does, and pure
timing numbers alone won't tell you that it's failing — they'll just look
smaller than expected, which is easy to write off as measurement noise
instead of a broken rig. This session's first attempt at a "grazing
shapecast" rig turned out, geometrically, to be indistinguishable from the
"direct hit" rig due to an unnoticed interaction between the grid spacing and
the cast shape's reach — both scenarios were exercising the exact same single
candidate.

The fix was to add a temporary counter to a throwaway copy of the query
module — broad-phase candidates reached, candidates rejected by the cheap
pre-filter, actual narrow-phase calls, hits — reset it, run one query, and
read the counts back before trusting any timing number. This turned "why
isn't this rig showing the effect I expect" from a guessing game into a
five-minute diagnosis. If a rig's timing doesn't match your mental model of
what it should be exercising, instrument before you start second-guessing
the timer.

Corollary: if a count from instrumentation looks implausibly large, check
whether you reset the counter inside the timed loop rather than once
outside it. A "241 candidates" reading in this session turned out to be 241
separate query calls each testing exactly one real candidate, accumulated
across an entire batched-timing run because the counter reset only happened
once, before the loop, not once per call.

## Testing under a real simulation

Isolated `Edit`-mode timing tells you steady-state cost under ideal
conditions. To check whether that holds up with the actual game loop
running (physics, other scripts, real engine scheduling):

1. Make sure any files you need are already synced into **Edit** mode first
   — see the Rojo caveat above.
2. Start Play mode. `execute_luau` targeting the `Server` datamodel becomes
   available, and — confirmed working — **can yield across real time**: a
   `task.wait(seconds)` inside the executed code genuinely waits and the
   call returns afterward with whatever you collected.
3. To match production exactly, hook the same primitive production code
   uses. This codebase's capture loop runs on
   `RunService:BindToSimulation(fn, Settings.StepFrequency, Settings.HitboxStepPriority)`,
   not `Heartbeat` — timing under `Heartbeat` instead gave very similar
   numbers here, but don't assume that generalizes; use the real one.
   `BindToSimulation` **returns an `RBXScriptConnection`** — disconnect via
   `:Disconnect()` on that connection. There is no `UnbindFromSimulation`
   method; calling it errors.
4. Collect every sample into a table over several real seconds rather than
   batching, then take min/median/max from the whole set. Live numbers
   track isolated `Edit`-mode numbers reasonably closely for the typical
   case, but **the worst-case tail can be substantially worse live** — a
   periodic stall landing on top of whatever else the engine is doing that
   frame, rather than in isolation. This session saw a 10× gap between a
   live worst-case sample and the same backend's isolated steady-state
   minimum, versus ~2-5× when measured in isolation. If tail latency matters
   for the thing you're evaluating, don't rely on an isolated harness alone.
5. Stop Play mode when done. Note that stopping does **not** revert changes
   made during the session to anything that started outside of it.

## Cleanup, every time

Before finishing, and periodically during a long session:

- Delete every throwaway vendored file (`*Old.luau`, `*Master`, instrumented
  copies, benchmark harness modules) from disk.
- Destroy every scratch Instance created directly in Studio (injected
  modules, part containers) — don't rely on them getting garbage collected.
- Diff `git status` in the vendoring repo against what it looked like before
  you started. It should match exactly; anything left over is a scratch file
  that didn't get cleaned up.

## Reporting the results

- State the exact commit and the settings a table was measured at. A number
  with no stated configuration is unverifiable and will go stale silently.
- Only report numbers you personally measured this session. If an old
  number can't be reproduced, say so with your own number next to it rather
  than quietly dropping it or quietly keeping the old one.
- If a result contradicts what the change was supposed to achieve, report
  that plainly. A benchmarking pass that only ever confirms the hoped-for
  outcome isn't measuring anything.
- Re-run a surprising result before writing it down. Several numbers in this
  session's first pass turned out to be artifacts (a require-cache staleness
  bug, a movement-cost-inside-the-timer bug, a rebuild-spike-inside-the-batch
  bug) that a second look caught before they reached the README.
