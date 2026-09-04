# eb-gui-haiku

The native `BWindow`/`BApplication` (Haiku BeAPI) backend adapter for
[eb-gui](https://github.com/yann64/eb-gui), eBasic's universal,
cross-toolkit GUI API, managed with `ebpm`.

## Status

Full contract (`Application`/`Window`/`StatusBar`/`Timer`/`Menu`/
`Toolbar`/`Action`), Widget/Layout Round 1 (`GuiButton`/`GuiLabel`/
`GuiEntry` + `GuiBox`/`GuiGrid`), and Round 2 (per-child expand/
alignment + per-column/row weight constraints), implementing every
function in `eb-gui`'s own contract by calling into
[`eb-haiku`](https://github.com/yann64/eb-haiku). Needs **no native
code of its own at all** - every native piece this adapter needed
(window title/geometry/enable/modal, a reusable per-object callback
target plus its button/menu-item/text-field/application-level
attachment points, a `BMessageRunner`-based timer, the real "fill"
alignment sentinel) was added to `eb-haiku` itself (`v0.14.0`-`v0.14.4`)
as prerequisite work, exactly the same "extend the base binding first"
pattern `eb-gui-gtk4`/`eb-gui-qt6` each followed for their own
toolkits.

**`GuiButtonConnectClicked`/`GuiEntryConnectChanged` attach to the
APPLICATION's own `BLooper`** (`HApplicationAddHandler`, `eb-haiku`
v0.14.3+), unlike `GuiMenuAddAction`/`GuiToolBarAddAction`'s own
window-scoped `HHandler` - this contract's widget-connect functions get
no window reference at all (a button is typically wired up before
being added to any layout), so there's nowhere window-scoped to attach
to yet. A real, worth-knowing consequence: real `BApplication` runs its
message loop on the SAME thread that calls `GuiApplicationRun`, unlike
a `BWindow`'s own separate thread (which already runs pre-`Run()`) - so
a widget-level callback genuinely cannot fire until `GuiApplicationRun`
is actually executing, unlike a menu/toolbar action's own callback
(see `examples/verify`'s own comment on this for the concrete
consequence: no safe point exists in a script to fire-and-check a
button click outside of `Run()` itself, unlike actions).

`GuiBox`/`GuiGrid` need the same holder-view design `eb-gui-qt6`
needed for its own `BoxLayout`/`GridLayout`, for the identical
reason: a real `HGroupLayout`/`HGridLayout` is NOT itself a `BView`,
unlike GTK4's own `Box`/`Grid` widgets (see `eb-gui`'s own README on
this asymmetry) - `GuiBox`/`GuiGrid.handle` here is really a small
holder `HView` with the real layout applied via `HViewSetLayout`, the
real layout tracked separately via this adapter's own generic
association table.

**Why this adapter exists at all, given GTK4/Qt6 already run
unmodified on Haiku** (confirmed separately, see `eb-gui`'s own
README): a native `BWindow`-based path serves a narrower goal than
"support Haiku as a target" - apps that want zero GTK4/Qt6 runtime
dependency and Haiku's own always-present native look, at the cost of
Haiku-only portability (unlike `eb-gui-gtk4`/`eb-gui-qt6`, which also
run on Linux and now Haiku alike).

## Real capability differences from `eb-gui-gtk4`/`eb-gui-qt6`

- **`GuiWindowCanMove()` is `1`** - real Haiku genuinely supports
  programmatic window repositioning, like Qt6 and unlike GTK4 (which
  removed it upstream).
- **`GuiActionTrigger`'s delivery is asynchronous, unlike either other
  backend** - confirmed by direct reproduction, not assumed. GTK4's
  `GSimpleAction`/Qt6's `QAction` both deliver a connected handler
  *synchronously* - the handler has already run by the time
  `GuiActionTrigger` returns. This backend's own per-object callback
  (see "Why a small per-object callback target" below) goes through a
  real `BMessenger`/`BHandler` round-trip, which is **always
  asynchronous** even when the target is a locally-attached handler -
  a caller needing to observe the callback's effect right after
  `GuiActionTrigger` must give the target window's own message-loop
  thread a moment to actually process it (`examples/verify.bas` sleeps
  300ms after each trigger for exactly this reason - omitting it reads
  the "before" value on every run, not flakily).
- **A permanently-vetoing `GuiWindowSetCloseCallback` blocks
  `GuiApplicationQuit` application-wide, even on a window that was
  NEVER SHOWN** - confirmed by direct reproduction. Real
  `BApplication::QuitRequested()`'s default implementation asks every
  open window regardless of visibility, and a single veto aborts the
  whole quit. This is a *stricter* version of the same
  asymmetry `eb-gui-qt6`'s own README documents for Qt6 (there, only a
  *visible* window's veto has this effect) - GTK4 has no such
  negotiation at all (`GuiApplicationQuit` there always stops
  unconditionally). `examples/verify.bas`'s own close-callback test
  allows the close (returns nonzero) specifically to avoid this
  interaction with its own later timer-driven quit.
- **`GuiWindowIsEnabled`/`GuiActionIsEnabled` for a menu action are not
  bound** (always report enabled) - `eb-haiku` has no window-level or
  menu-item-level "is enabled" query, only the `Set` half - matching
  `eb-gui-gtk4`'s own identical gaps. `GuiActionIsEnabled` for a
  **toolbar** action IS real (`HControlIsEnabled`, since a toolbar
  button is a real `BControl`).

## Why a small per-object callback target (`HHandler`)

`GuiActionConnectTriggered`/`GuiTimer`'s own timeout callback both need
a genuinely **per-object** callback. Real Haiku's own model is
thinner than either other toolkit here: `BMenuItem`/`BMessageRunner`/
`BButton` all deliver via a `BMessage` sent to a *target* `BHandler`,
which defaults to the window itself - fine for a single shared
dispatch point, not enough for a distinct callback per action/timer
the way GTK4's `GSimpleAction` "activate" signal or Qt6's
`QAction::triggered` already are natively.

`eb-haiku` (`v0.14.0`+) added `HHandler` for exactly this: one small,
reusable `BHandler` subclass, one instance per action/timer, attached
to the owning window's own `BLooper` (`HWindowAddHandler`) and set as
the real invocation target (`HMenuItemSetTarget`/`HButtonSetTarget`,
`v0.14.1`). This adapter creates one fresh `HHandler` per
`GuiMenuAddAction`/`GuiToolBarAddAction`/`NewGuiTimer` call - see
`eb-haiku`'s own README for the native-side rationale.

## A capability mismatch, same shape as `eb-gui-gtk4`'s own

`eb-gui`'s own contract follows Qt6's simpler "create a fresh action
per call" shape (see `eb-gui`'s own README) rather than exposing
GTK4's richer, action-sharing model. Real Haiku's `BMenuItem`s and
`BButton`s are two *completely separate, non-interchangeable* concrete
types with no common "action" base in this package's own binding, and
`eb-gui`'s `GuiAction` carries no discriminator of its own - so this
adapter tracks internally (`EbGuiHaikuIsButtonAction`) which concrete
type a given `GuiAction.handle` actually is, to dispatch
`GuiActionSetEnabled`/`IsEnabled`/`Trigger` to the right underlying
function (`HMenuItemSetEnabled`/`InvokeViaMessenger` vs.
`HControlSetEnabled`/`HButtonInvoke`).

## `GuiWindowStatusBar`/`GuiWindowMenuBar`/`GuiWindowToolBar` composition

Real Haiku has neither a text-status-line widget, an auto-owned "the
window's own menu bar" concept, nor a toolbar widget at all - this
adapter composes all three (`BStringView`, `BMenuBar`, a row of
`BButton`s respectively) into **one shared vertical `BGroupLayout` per
window** (`EbGuiHaikuContentLayout`, get-or-create, mirroring
`eb-gui-gtk4`'s own `WindowContentBox`), so they stack correctly
regardless of which is requested first. Each is its own
auto-created-once singleton - unlike `eb-gui-gtk4`, where a window can
only ever have ONE direct child so a *single* shared container
suffices, `eb-haiku`'s own `BWindow` supports any number of direct
children, but a window still needs at most one "the" status bar/menu
bar/tool bar for this contract, tracked via small per-purpose
association tables (`eBasic` has no generic map type, and a window
handle needs several *simultaneous* singleton lookups - content
layout, menu bar, tool bar, status bar, modal parent - so each gets
its own small table rather than sharing one keyed by the same window
handle, which would silently clobber the others).

## Building

No native code of its own - just `ebpm build`. Examples need the same
manual `ebc` invocation `eb-haiku`'s own tests use (its own linker-flag
auto-forwarding gap for several Kits, unrelated to this package):

```sh
$ ebc examples/hello_window.bas -o hello_window \
    -I target -I path/to/eb-haiku/target \
    -L target -l gui-haiku \
    -L path/to/eb-haiku/target -l eb-haiku \
    -L /boot/system/non-packaged/develop/lib -l ebhaikushim -l be \
    -l translation -l root -l bnetapi -l device -l package -l media \
    -l mail -l game -l GL -l midi2 -l screensaver
```

(`libebhaikushim.a` must already be built and installed - see
`eb-haiku`'s own README "Building".)

## Using as a dependency

```toml
[dependencies]
gui-haiku = { git = "https://github.com/yann64/eb-gui-haiku.git" }
```

```basic
' Only the adapter's own interface is needed - it already carries a
' full copy of GuiApplication/GuiWindow/etc.
#include "gui-haiku.iface.bas"

DIM app AS GuiApplication
app = NewGuiApplication("application/x-vnd.you.yourapp")

DIM win AS GuiWindow
win = NewGuiWindow(app, "Hello", 320, 240)

DIM box AS GuiBox
box = NewGuiBox(1, 8)   ' 1 = vertical

DIM lbl AS GuiLabel
lbl = NewGuiLabel("Type something, then click Go")
CALL GuiBoxAddChild(box, lbl.handle)

DIM entry AS GuiEntry
entry = NewGuiEntry("")
CALL GuiBoxAddChild(box, entry.handle)

SUB OnGo(userData AS ANY PTR)
    DIM e AS GuiEntry
    e.handle = userData
    CALL GuiLabelSetText(lbl, GuiEntryGetText(e))
END SUB

DIM btn AS GuiButton
btn = NewGuiButton("Go")
CALL GuiButtonConnectClicked(btn, @OnGo, entry.handle)
CALL GuiBoxAddChild(box, btn.handle)

CALL GuiWindowSetContent(win, box.handle)
CALL GuiWindowShow(win)

CALL GuiApplicationRun(app)
```

Round 2 constraints (expand/align/weight):

```basic
DIM growBtn AS GuiButton
growBtn = NewGuiButton("Grows")
CALL GuiBoxAddChildEx(box, growBtn.handle, 1.0, GUI_ALIGN_FILL, GUI_ALIGN_CENTER)

DIM fixedBtn AS GuiButton
fixedBtn = NewGuiButton("Fixed")
CALL GuiBoxAddChildEx(box, fixedBtn.handle, 0.0, GUI_ALIGN_END, GUI_ALIGN_START)
```

`GuiBoxAddChildEx` sets a real, proportional `HGroupLayoutSetItemWeight`
(index-based - this adapter tracks each `GuiBox`'s own running child
count internally, `EbGuiHaikuBoxNextChildIndex`, since Haiku's weight
API is index-based rather than view-identity-based like `eb-qt6`'s own
stretch factor) plus `HViewSetExplicitAlignment`. `GUI_ALIGN_FILL` maps
to real Haiku's own `H_ALIGN_USE_FULL_WIDTH`/`HEIGHT` sentinel
(`eb-haiku` v0.14.4+) - **not** `H_ALIGN_CENTER`. A real bug caught via
this round's own live screenshot: approximating "fill" as "center"
doesn't just fail to stretch a view, it actively breaks the default
fill/stretch behavior a view already has before
`HViewSetExplicitAlignment` is ever called - confirmed by a button
rendering centered at its natural size instead of spanning the full
box width, then fixed by adding the missing real sentinel to
`eb-haiku` rather than working around it here. `GuiGridSetColumnWeight`/
`SetRowWeight` are real, direct `HGridLayoutSetColumnWeight`/
`SetRowWeight` pass-throughs.

## Verifying

Real hardware only, over SSH (this package binds `libbe.so`, which
doesn't exist anywhere else) - no headless story for GUI work on Haiku
any more than on `eb-qt6`.

- `examples/hello_window.bas` - a plain window appears, title set
  through the universal API (screenshot-verified live on real Haiku
  hardware - visually distinct from `eb-gui-gtk4`/`eb-gui-qt6`'s own
  equivalents only in native Haiku theming, never in behavior).
- `examples/menu_toolbar_statusbar.bas` - `MenuBar` + `ToolBar` +
  `StatusBar` all composed on one window (screenshot-verified live,
  correctly stacked: menu bar, content, status bar).
- `examples/verify.bas` - every contract function exercised via direct
  calls + printed results: enable/disable, modal set/clear, real
  move/resize, close-callback wiring, `StatusBar`/`MenuBar`/`ToolBar`
  composing correctly regardless of call order, `GuiActionTrigger`
  genuinely reaching a connected handler for both a menu action and a
  toolbar action (confirmed asynchronous - see "Real capability
  differences" above), `GuiWindowToolBar` returning the identical
  handle on repeated calls, `GuiEntrySetText`/`GetText` round-tripping
  through a `GuiGrid` nested inside a `GuiBox`, `GuiWindowSetContent`
  composing with StatusBar/MenuBar/ToolBar without crashing,
  `GuiBoxAddChildEx`/`GuiGridAttachEx`/`GuiGridSetColumnWeight`/
  `SetRowWeight` (Round 2 constraints) running without crashing with
  correct index tracking across mixed `AddChild`/`AddChildEx` calls,
  and a `GuiTimer`-driven `GuiApplicationQuit` exiting
  `GuiApplicationRun` promptly.
- `examples/widgets_form.bas` - a `GuiBox` containing a `GuiLabel` +
  `GuiEntry` + `GuiButton`, clicking the button reads the entry and
  updates the label; the `Go` button is added via `GuiBoxAddChildEx`
  with `expand=1.0`/`GUI_ALIGN_FILL` and visibly spans the full box
  width (screenshot-verified live on real Haiku hardware - this is the
  screenshot that caught the `H_ALIGN_FILL`-vs-`CENTER` bug above).

## See also

- [`eb-gui`](https://github.com/yann64/eb-gui) - the shared contract this package implements.
- [`eb-gui-gtk4`](https://github.com/yann64/eb-gui-gtk4) - the GTK4 adapter.
- [`eb-gui-qt6`](https://github.com/yann64/eb-gui-qt6) - the Qt6 adapter.
- [`eb-haiku`](https://github.com/yann64/eb-haiku) - the underlying Haiku BeAPI binding.
