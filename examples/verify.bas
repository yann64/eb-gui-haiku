' Headless(-ish) verification of the eb-gui contract implemented over
' eb-haiku - every check is a direct function call + printed result,
' not a synthetic mouse/keyboard event, matching eb-gui-gtk4/
' eb-gui-qt6's own examples/verify discipline (and eb-haiku's own
' established "no real interactive input over SSH" limitation).

#include "gui-haiku.iface.bas"

' CONFIRMED, not assumed - a real, worth-documenting cross-toolkit
' asymmetry: on this backend, a PERMANENTLY-VETOING close callback
' blocks GuiApplicationQuit application-wide even on a window that was
' NEVER SHOWN (real BApplication::QuitRequested() asks every open
' window regardless of visibility) - unlike GTK4/Qt6, where an
' invisible window's veto has no such effect (see eb-gui-qt6's own
' README). So this callback allows the close (returns nonzero) -
' testing only "does connecting one crash," not veto behavior itself,
' which would otherwise deadlock this example's own later timer-driven
' quit.
FUNCTION OnCloseCallback(userData AS ANY PTR) AS INTEGER
    PRINT "close callback fired"
    OnCloseCallback = 1
END FUNCTION

DIM triggerCount AS INTEGER

SUB OnActionTriggered(userData AS ANY PTR)
    triggerCount = triggerCount + 1
END SUB

DIM app AS GuiApplication
app = NewGuiApplication("application/x-vnd.EbGuiHaiku-Verify")

' 1. Enable/disable - GuiWindowIsEnabled isn't bound on this backend
' (documented limitation, always reports 1), but SetEnabled itself
' should not crash regardless.
DIM win AS GuiWindow
win = NewGuiWindow(app, "verify", 300, 200)
CALL GuiWindowShow(win)
CALL GuiWindowSetEnabled(win, 0)
CALL GuiWindowSetEnabled(win, 1)
PRINT "enable/disable did not crash"

' 2. Modal, and real move/resize (this backend genuinely supports it -
' GuiWindowCanMove() should read 1, like eb-gui-qt6's own Qt6 backend,
' unlike eb-gui-gtk4's 0).
DIM childWin AS GuiWindow
childWin = NewGuiWindow(app, "child", 200, 100)
CALL GuiWindowSetModal(childWin, win)
CALL GuiWindowClearModal(childWin)
PRINT "modal set/clear did not crash"
PRINT "can move on this backend: ", GuiWindowCanMove()
CALL GuiWindowMove(childWin, 15, 15)
CALL GuiWindowResize(childWin, 250, 150)
PRINT "move/resize did not crash"

' 3. Close callback wiring - direct pass-through to eb-haiku's own
' HWindowSetQuitRequestedCallback (already the exact contract shape) -
' no crash is the bar here.
DIM closeWin AS GuiWindow
closeWin = NewGuiWindow(app, "close callback", 200, 100)
CALL GuiWindowSetCloseCallback(closeWin, @OnCloseCallback, 0)
PRINT "close callback connected without crashing"

' 4. StatusBar/MenuBar/ToolBar all composing on ONE window regardless
' of call order (shared content layout) - the same composition proof
' eb-gui-gtk4's own verify example uses.
DIM sbWin AS GuiWindow
sbWin = NewGuiWindow(app, "gui extras", 300, 200)
DIM sb AS GuiStatusBar
sb = GuiWindowStatusBar(sbWin)
CALL GuiStatusBarShowMessage(sb, "hello")
CALL GuiStatusBarClear(sb)
PRINT "status bar show/clear did not crash"

DIM mbar AS GuiMenuBar
mbar = GuiWindowMenuBar(sbWin)
DIM fileMenu AS GuiMenu
fileMenu = GuiMenuBarAddMenu(mbar, "File")
DIM menuAction AS GuiAction
menuAction = GuiMenuAddAction(fileMenu, "Test")
CALL GuiActionConnectTriggered(menuAction, @OnActionTriggered, 0)

DIM tbar1 AS GuiToolBar
tbar1 = GuiWindowToolBar(sbWin)
DIM tbar2 AS GuiToolBar
tbar2 = GuiWindowToolBar(sbWin)
PRINT "GuiWindowToolBar returns the same handle both times: ", (tbar1.handle = tbar2.handle)

DIM toolAction AS GuiAction
toolAction = GuiToolBarAddAction(tbar1, "Go")
CALL GuiActionConnectTriggered(toolAction, @OnActionTriggered, 0)

' All content built while hidden (matching eb-haiku's own established
' "build then show" convention) - now show and give the window/menu/
' handlers time to fully attach before invoking anything.
CALL GuiWindowShow(sbWin)
CALL Sleep(500)

' NOTE: unlike eb-gui-gtk4/eb-gui-qt6 (where a connected handler runs
' synchronously, already-fired by the time GuiActionTrigger returns),
' this backend's own per-object delivery goes through a real
' BMessenger/BHandler round-trip - ALWAYS asynchronous, even for a
' locally-targeted handler (confirmed by direct reproduction: omitting
' this Sleep reads triggerCount before delivery completes, on every
' run, not flakily) - a real, worth-documenting cross-toolkit
' asymmetry, not a bug in this adapter.
PRINT "before menu action trigger: ", triggerCount
CALL GuiActionTrigger(menuAction)
CALL Sleep(300)
PRINT "after menu action trigger: ", triggerCount

CALL GuiActionSetEnabled(menuAction, 0)
CALL GuiActionSetEnabled(menuAction, 1)
PRINT "menu action enable/disable did not crash"

CALL GuiActionTrigger(toolAction)
CALL Sleep(300)
PRINT "after toolbar action trigger: ", triggerCount

CALL GuiActionSetEnabled(toolAction, 0)
PRINT "toolbar action enabled after disable: ", GuiActionIsEnabled(toolAction)
CALL GuiActionSetEnabled(toolAction, 1)
PRINT "toolbar action enabled after re-enable: ", GuiActionIsEnabled(toolAction)

' 5. GuiTimer, and (via its own callback) GuiApplicationQuit stopping
' GuiApplicationRun - the same real running-loop quit proof eb-gtk4/
' eb-qt6's own equivalents use.
SUB OnTimeout(userData AS ANY PTR)
    PRINT "timer fired - quitting"
    CALL GuiApplicationQuit(app)
END SUB

DIM t AS GuiTimer
t = NewGuiTimer(win)
CALL GuiTimerSetInterval(t, 200)
CALL GuiTimerSetSingleShot(t, 1)
PRINT "timer active before start: ", GuiTimerIsActive(t)
CALL GuiTimerConnectTimeout(t, @OnTimeout, 0)
CALL GuiTimerStart(t)
PRINT "timer active after start: ", GuiTimerIsActive(t)

CALL GuiApplicationRun(app)
PRINT "GuiApplicationRun returned - timer-driven quit worked"
CALL GuiTimerDestroy(t)
