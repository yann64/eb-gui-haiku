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

' 6. Widget/Layout Round 1 - GuiBox/GuiGrid nesting (a GuiGrid inside a
' GuiBox, via each's own holder-view mechanism - see this adapter's own
' src/lib.bas top comment), GuiEntry text round-trip, and
' GuiWindowSetContent appending into the shared content layout
' alongside StatusBar/MenuBar/ToolBar. GuiButtonConnectClicked/
' GuiEntryConnectChanged are only confirmed "connects without
' crashing" here: their own HHandler attaches to the APPLICATION's own
' BLooper (no window is known at connect time), and real BApplication
' runs its message loop on the SAME thread that calls
' GuiApplicationRun - unlike a BWindow's own separate thread, which
' already runs pre-Run() (why the menu/toolbar action checks above can
' fire-and-check before Run() at all) - so there is no safe point in
' this script to fire one and observe the result outside of Run()
' itself.
DIM widgetsBox AS GuiBox
widgetsBox = NewGuiBox(1, 4)

DIM formGrid AS GuiGrid
formGrid = NewGuiGrid()
DIM nameLbl AS GuiLabel
nameLbl = NewGuiLabel("Name:")
CALL GuiGridAttach(formGrid, nameLbl.handle, 0, 0, 1, 1)
DIM nameEntry AS GuiEntry
nameEntry = NewGuiEntry("")
CALL GuiGridAttach(formGrid, nameEntry.handle, 1, 0, 1, 1)
CALL GuiBoxAddChild(widgetsBox, formGrid.handle)

CALL GuiEntrySetText(nameEntry, "hello")
PRINT "entry text round-trip: ", GuiEntryGetText(nameEntry)
CALL GuiEntryConnectChanged(nameEntry, @OnActionTriggered, 0)
PRINT "entry connect changed did not crash"

DIM goBtn AS GuiButton
goBtn = NewGuiButton("Go")
CALL GuiButtonConnectClicked(goBtn, @OnActionTriggered, 0)
CALL GuiBoxAddChild(widgetsBox, goBtn.handle)

CALL GuiWindowSetContent(sbWin, widgetsBox.handle)
PRINT "GuiWindowSetContent composed with StatusBar/MenuBar/ToolBar without crashing"

' 6. Round 2: per-child constraints - expand/align/weight. Real
' Haiku's own effect isn't introspectable headlessly (it's a layout
' allocation-time effect) - this confirms the calls don't crash, the
' index-based item-weight tracking (EbGuiHaikuBoxNextChildIndex) stays
' correct across mixed AddChild/AddChildEx calls, and it composes with
' a nested Grid.
DIM constraintsBox AS GuiBox
constraintsBox = NewGuiBox(0, 4)
DIM growBtn AS GuiButton
growBtn = NewGuiButton("Grows")
CALL GuiBoxAddChildEx(constraintsBox, growBtn.handle, 1.0, GUI_ALIGN_FILL, GUI_ALIGN_CENTER)
DIM fixedBtn AS GuiButton
fixedBtn = NewGuiButton("Fixed")
CALL GuiBoxAddChildEx(constraintsBox, fixedBtn.handle, 0.0, GUI_ALIGN_END, GUI_ALIGN_START)

DIM constraintsGrid AS GuiGrid
constraintsGrid = NewGuiGrid()
DIM gridLbl AS GuiLabel
gridLbl = NewGuiLabel("Grid cell")
CALL GuiGridAttachEx(constraintsGrid, gridLbl.handle, 0, 0, 1, 1, GUI_ALIGN_CENTER, GUI_ALIGN_CENTER)
CALL GuiGridSetColumnWeight(constraintsGrid, 0, 1.0)
CALL GuiGridSetRowWeight(constraintsGrid, 0, 1.0)
CALL GuiBoxAddChild(constraintsBox, constraintsGrid.handle)
CALL GuiBoxAddChild(widgetsBox, constraintsBox.handle)
PRINT "Round 2 constraints (GuiBoxAddChildEx/GuiGridAttachEx/GuiGridSetColumnWeight/SetRowWeight) ran without crashing"

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
