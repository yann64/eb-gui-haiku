# eb-gui-haiku

The native `BWindow`/`BApplication` (Haiku BeAPI) backend adapter for
[eb-gui](https://github.com/yann64/eb-gui), eBasic's universal,
cross-toolkit GUI API, managed with `ebpm`.

## Status

Full contract (`Application`/`Window`/`StatusBar`/`Timer`/`Menu`/
`Toolbar`/`Action`), implementing every function in `eb-gui`'s own
contract by calling into
[`eb-haiku`](https://github.com/yann64/eb-haiku). Needs **no native
code of its own at all** - every native piece this adapter needed
(window title/geometry/enable/modal, a reusable per-object callback
target, a `BMessageRunner`-based timer) was added to `eb-haiku` itself
(`v0.14.0`/`v0.14.1`) as prerequisite work, exactly the same "extend
the base binding first" pattern `eb-gui-gtk4`/`eb-gui-qt6` each
followed for their own toolkits.

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
CALL GuiWindowShow(win)

CALL GuiApplicationRun(app)
```

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
  handle on repeated calls, and a `GuiTimer`-driven `GuiApplicationQuit`
  exiting `GuiApplicationRun` promptly.

## See also

- [`eb-gui`](https://github.com/yann64/eb-gui) - the shared contract this package implements.
- [`eb-gui-gtk4`](https://github.com/yann64/eb-gui-gtk4) - the GTK4 adapter.
- [`eb-gui-qt6`](https://github.com/yann64/eb-gui-qt6) - the Qt6 adapter.
- [`eb-haiku`](https://github.com/yann64/eb-haiku) - the underlying Haiku BeAPI binding.
