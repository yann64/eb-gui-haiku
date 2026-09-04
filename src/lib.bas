' Idiomatic layer: eb-gui's full contract, implemented over eb-haiku's
' native BWindow/BApplication binding.
'
' `GuiApplication.handle`/`GuiWindow.handle` are the exact same
' BApplication*/BWindow* eb-haiku's own HApplication/HWindow TYPEs wrap
' - this adapter just copies that field across the two TYPE shapes at
' each call (a cheap 8-byte pointer copy, not a real conversion), never
' allocating a second handle of its own.
'
' GuiWindowStatusBar/GuiWindowMenuBar/GuiWindowToolBar are all
' adapter-side compositions over eb-haiku primitives that have no
' dedicated status-bar/menu-bar-ownership/toolbar concept of their own
' (real Haiku has neither a text-status-line widget nor a toolbar
' widget, and no auto-created-once "the window's own menu bar" the way
' eb-gtk4's WindowMenuBar is) - a BStringView, a BMenuBar, and a row of
' BButtons respectively, matching eb-gui-gtk4's own precedent for the
' identical StatusBar/ToolBar gaps on GTK4. All three share ONE
' vertical BGroupLayout per window (EbGuiHaikuContentLayout below,
' get-or-create, mirroring eb-gtk4's own WindowContentBox) so they
' compose correctly regardless of call order - each is its own
' auto-created-once singleton, tracked via a small per-purpose
' association table (eBasic has no generic map type; a window handle
' needs several SIMULTANEOUS singleton lookups - content layout, menu
' bar, tool bar, status bar, modal parent - so each gets its OWN small
' table rather than sharing one keyed by the same window handle, which
' would silently clobber the others).
'
' GuiActionConnectTriggered/GuiTimer's own per-object callback both rely
' on eb-haiku's new HHandler (v0.14.0+) - a real per-object BHandler
' target, since Haiku's own BMenuItem/BMessageRunner/BButton otherwise
' all deliver via a BMessage sent to the shared window by default (no
' native per-object signal the way GTK4's GSimpleAction "activate" or
' Qt6's QAction::triggered already are).

#include "gui.iface.bas"
#include "eb-haiku.iface.bas"

CONST H_QUIT_ON_WINDOW_CLOSE = 1048576

' ---- Per-window singleton tables (see this file's own top comment for
' why these can't share one generic table keyed by window handle) ----

DIM ebGuiHaikuContentLayoutKeys(128) AS ANY PTR
DIM ebGuiHaikuContentLayoutVals(128) AS ANY PTR
DIM ebGuiHaikuContentLayoutCount AS INTEGER

DIM ebGuiHaikuMenuBarKeys(128) AS ANY PTR
DIM ebGuiHaikuMenuBarVals(128) AS ANY PTR
DIM ebGuiHaikuMenuBarCount AS INTEGER

DIM ebGuiHaikuToolBarKeys(128) AS ANY PTR
DIM ebGuiHaikuToolBarVals(128) AS ANY PTR
DIM ebGuiHaikuToolBarCount AS INTEGER

DIM ebGuiHaikuStatusBarKeys(128) AS ANY PTR
DIM ebGuiHaikuStatusBarVals(128) AS ANY PTR
DIM ebGuiHaikuStatusBarCount AS INTEGER

DIM ebGuiHaikuModalParentKeys(128) AS ANY PTR
DIM ebGuiHaikuModalParentVals(128) AS ANY PTR
DIM ebGuiHaikuModalParentCount AS INTEGER

''' Generic table (object handle -> a single associated pointer) for
''' every OTHER lookup this adapter needs, where each key object is a
''' distinct real pointer needing only one association (never a window
''' handle needing several simultaneous ones - see above): a menu's own
''' owning window, a tool bar view's own owning window, and an action's
''' own HHandler.
DIM ebGuiHaikuAssocKeys(256) AS ANY PTR
DIM ebGuiHaikuAssocVals(256) AS ANY PTR
DIM ebGuiHaikuAssocCount AS INTEGER

SUB EbGuiHaikuAssocSet(key AS ANY PTR, val AS ANY PTR)
    ebGuiHaikuAssocKeys(ebGuiHaikuAssocCount) = key
    ebGuiHaikuAssocVals(ebGuiHaikuAssocCount) = val
    ebGuiHaikuAssocCount = ebGuiHaikuAssocCount + 1
END SUB

FUNCTION EbGuiHaikuAssocGet(key AS ANY PTR) AS ANY PTR
    DIM i AS INTEGER
    FOR i = 0 TO ebGuiHaikuAssocCount - 1
        IF ebGuiHaikuAssocKeys(i) = key THEN
            EbGuiHaikuAssocGet = ebGuiHaikuAssocVals(i)
            EXIT FUNCTION
        END IF
    NEXT i
    EbGuiHaikuAssocGet = 0
END FUNCTION

''' The window's own shared vertical layout - auto-created (and
''' installed via HWindowSetLayout) the first time this is called for a
''' given window; every subsequent caller (menu bar/tool bar/status
''' bar) just appends its own view into the same layout via
''' HGroupLayoutAddView, so composition works regardless of call order.
FUNCTION EbGuiHaikuContentLayout(BYVAL win AS HWindow) AS HGroupLayout
    DIM i AS INTEGER
    FOR i = 0 TO ebGuiHaikuContentLayoutCount - 1
        IF ebGuiHaikuContentLayoutKeys(i) = win.handle THEN
            DIM existing AS HGroupLayout
            existing.handle = ebGuiHaikuContentLayoutVals(i)
            EbGuiHaikuContentLayout = existing
            EXIT FUNCTION
        END IF
    NEXT i
    DIM layout AS HGroupLayout
    layout = HGroupLayoutCreate(H_VERTICAL, 0)
    CALL HWindowSetLayout(win, layout.handle)
    ebGuiHaikuContentLayoutKeys(ebGuiHaikuContentLayoutCount) = win.handle
    ebGuiHaikuContentLayoutVals(ebGuiHaikuContentLayoutCount) = layout.handle
    ebGuiHaikuContentLayoutCount = ebGuiHaikuContentLayoutCount + 1
    EbGuiHaikuContentLayout = layout
END FUNCTION

''' Records that a GuiAction's own handle is a real BButton (from
''' GuiToolBarAddAction), not a BMenuItem (from GuiMenuAddAction) -
''' eb-haiku has two completely separate, non-interchangeable concrete
''' APIs for the two (HMenuItem* vs HButton*/HControl*), and eb-gui's
''' own GuiAction carries no such discriminator itself, so
''' GuiActionSetEnabled/IsEnabled/Trigger need this to dispatch to the
''' right one. Absence means "a menu item" (the more common case).
DIM ebGuiHaikuButtonActionKeys(128) AS ANY PTR
DIM ebGuiHaikuButtonActionCount AS INTEGER

SUB EbGuiHaikuMarkButtonAction(handle AS ANY PTR)
    ebGuiHaikuButtonActionKeys(ebGuiHaikuButtonActionCount) = handle
    ebGuiHaikuButtonActionCount = ebGuiHaikuButtonActionCount + 1
END SUB

FUNCTION EbGuiHaikuIsButtonAction(handle AS ANY PTR) AS INTEGER
    DIM i AS INTEGER
    FOR i = 0 TO ebGuiHaikuButtonActionCount - 1
        IF ebGuiHaikuButtonActionKeys(i) = handle THEN
            EbGuiHaikuIsButtonAction = 1
            EXIT FUNCTION
        END IF
    NEXT i
    EbGuiHaikuIsButtonAction = 0
END FUNCTION

FUNCTION NewGuiApplication(appId AS ZSTRING) AS GuiApplication
    DIM realApp AS HApplication
    realApp = HApplicationCreate(appId)
    DIM result AS GuiApplication
    result.handle = realApp.handle
    NewGuiApplication = result
END FUNCTION

FUNCTION GuiApplicationRun(app AS GuiApplication) AS INTEGER
    DIM realApp AS HApplication
    realApp.handle = app.handle
    GuiApplicationRun = HApplicationRun(realApp)
END FUNCTION

SUB GuiApplicationQuit(app AS GuiApplication)
    DIM realApp AS HApplication
    realApp.handle = app.handle
    CALL HApplicationQuit(realApp)
END SUB

''' Always created with H_QUIT_ON_WINDOW_CLOSE, matching eb-gui's own
''' contract - the application owns every window it creates, and
''' GuiApplicationRun returns once the last one closes (see eb-gui's
''' own README "Ownership and the quit model").
FUNCTION NewGuiWindow(app AS GuiApplication, title AS ZSTRING, width AS INTEGER, height AS INTEGER) AS GuiWindow
    DIM win AS HWindow
    win = HWindowCreate(50, 50, 50 + width, 50 + height, title, H_QUIT_ON_WINDOW_CLOSE)
    DIM result AS GuiWindow
    result.handle = win.handle
    NewGuiWindow = result
END FUNCTION

SUB GuiWindowSetTitle(win AS GuiWindow, title AS ZSTRING)
    DIM realWin AS HWindow
    realWin.handle = win.handle
    CALL HWindowSetTitle(realWin, title)
END SUB

SUB GuiWindowShow(win AS GuiWindow)
    DIM realWin AS HWindow
    realWin.handle = win.handle
    CALL HWindowShow(realWin)
END SUB

SUB GuiWindowHide(win AS GuiWindow)
    DIM realWin AS HWindow
    realWin.handle = win.handle
    CALL HWindowHide(realWin)
END SUB

SUB GuiWindowSetEnabled(win AS GuiWindow, enabled AS INTEGER)
    DIM realWin AS HWindow
    realWin.handle = win.handle
    CALL HWindowSetEnabled(realWin, enabled)
END SUB

''' Not bound at all on this backend (eb-haiku has no window-level
''' IsEnabled query, only the SetEnabled composition above) - always
''' reports enabled, matching eb-gui-gtk4's own identical limitation.
FUNCTION GuiWindowIsEnabled(win AS GuiWindow) AS INTEGER
    GuiWindowIsEnabled = 1
END FUNCTION

''' Always 1 on this backend - real Haiku genuinely supports
''' programmatic window repositioning (unlike GTK4, which removed it
''' upstream).
FUNCTION GuiWindowCanMove() AS INTEGER
    GuiWindowCanMove = 1
END FUNCTION

SUB GuiWindowMove(win AS GuiWindow, x AS INTEGER, y AS INTEGER)
    DIM realWin AS HWindow
    realWin.handle = win.handle
    CALL HWindowMoveTo(realWin, x, y)
END SUB

SUB GuiWindowResize(win AS GuiWindow, width AS INTEGER, height AS INTEGER)
    DIM realWin AS HWindow
    realWin.handle = win.handle
    CALL HWindowResizeTo(realWin, width, height)
END SUB

''' Real Haiku modal (SetFeel(B_MODAL_SUBSET_WINDOW_FEEL)+AddToSubset) -
''' best set before `win` is first shown for reliable behavior.
SUB GuiWindowSetModal(win AS GuiWindow, parent AS GuiWindow)
    DIM realWin AS HWindow
    realWin.handle = win.handle
    DIM realParent AS HWindow
    realParent.handle = parent.handle
    CALL HWindowSetModal(realWin, realParent)
    ebGuiHaikuModalParentKeys(ebGuiHaikuModalParentCount) = win.handle
    ebGuiHaikuModalParentVals(ebGuiHaikuModalParentCount) = parent.handle
    ebGuiHaikuModalParentCount = ebGuiHaikuModalParentCount + 1
END SUB

''' `HWindowClearModal` needs the same parent reference `SetModal` was
''' given - tracked via this adapter's own table so the contract's own
''' parameterless GuiWindowClearModal(win) shape works.
SUB GuiWindowClearModal(win AS GuiWindow)
    DIM realWin AS HWindow
    realWin.handle = win.handle
    DIM parentHandle AS ANY PTR
    parentHandle = 0
    DIM i AS INTEGER
    FOR i = 0 TO ebGuiHaikuModalParentCount - 1
        IF ebGuiHaikuModalParentKeys(i) = win.handle THEN
            parentHandle = ebGuiHaikuModalParentVals(i)
            EXIT FOR
        END IF
    NEXT i
    DIM realParent AS HWindow
    realParent.handle = parentHandle
    CALL HWindowClearModal(realWin, realParent)
END SUB

''' `handler` is `FUNCTION(userData AS ANY PTR) AS INTEGER`, nonzero =
''' allow the close - eb-haiku's own HWindowSetQuitRequestedCallback
''' already matches this exact shape, so this is a direct pass-through
''' (unlike eb-gui-gtk4, which needs a native trampoline for GTK4's own
''' differently-shaped/polarized "close-request" signal).
SUB GuiWindowSetCloseCallback(win AS GuiWindow, handler AS ANY PTR, userData AS ANY PTR)
    DIM realWin AS HWindow
    realWin.handle = win.handle
    CALL HWindowSetQuitRequestedCallback(realWin, handler, userData)
END SUB

''' Only meaningful for a window never Run/shown - see eb-gui's own
''' README "Ownership and the quit model". Real Haiku has no HWindowFree
''' (Haiku itself deletes a BWindow once it actually closes) - closing
''' it is the closest equivalent.
SUB GuiWindowDestroy(win AS GuiWindow)
    DIM realWin AS HWindow
    realWin.handle = win.handle
    CALL HWindowClose(realWin)
END SUB

''' Real Haiku has no text-status-line widget - this adapter composes
''' one BStringView, appended into the window's own shared content
''' layout (EbGuiHaikuContentLayout above), auto-created-once.
FUNCTION GuiWindowStatusBar(win AS GuiWindow) AS GuiStatusBar
    DIM realWin AS HWindow
    realWin.handle = win.handle
    DIM i AS INTEGER
    FOR i = 0 TO ebGuiHaikuStatusBarCount - 1
        IF ebGuiHaikuStatusBarKeys(i) = win.handle THEN
            DIM existingResult AS GuiStatusBar
            existingResult.handle = ebGuiHaikuStatusBarVals(i)
            GuiWindowStatusBar = existingResult
            EXIT FUNCTION
        END IF
    NEXT i
    DIM layout AS HGroupLayout
    layout = EbGuiHaikuContentLayout(realWin)
    DIM sb AS HStringView
    sb = HStringViewCreate(0, 0, 0, 0, "eb-gui-haiku-statusbar", "")
    CALL HGroupLayoutAddView(layout, sb.handle)
    ebGuiHaikuStatusBarKeys(ebGuiHaikuStatusBarCount) = win.handle
    ebGuiHaikuStatusBarVals(ebGuiHaikuStatusBarCount) = sb.handle
    ebGuiHaikuStatusBarCount = ebGuiHaikuStatusBarCount + 1
    DIM result AS GuiStatusBar
    result.handle = sb.handle
    GuiWindowStatusBar = result
END FUNCTION

SUB GuiStatusBarShowMessage(sb AS GuiStatusBar, text AS ZSTRING)
    DIM realSb AS HStringView
    realSb.handle = sb.handle
    CALL HStringViewSetText(realSb, text)
END SUB

SUB GuiStatusBarClear(sb AS GuiStatusBar)
    DIM realSb AS HStringView
    realSb.handle = sb.handle
    CALL HStringViewSetText(realSb, "")
END SUB

''' `parent` is required (the timer's own HHandler needs a window's
''' BLooper to attach to, matching eb-qt6's own NewQTimer(parent)
''' requirement, not eb-gtk4's parentless GtkTimer). eb-haiku's own
''' HTimer carries TWO fields (`handle` AND its own `target AS
''' HHandler`) - GuiTimer.handle can only smuggle one pointer across
''' the contract boundary, so the target handler's own handle is
''' tracked separately via the association table and reattached in
''' GuiTimerConnectTimeout below (the only other HTimer function that
''' actually reads `.target`).
FUNCTION NewGuiTimer(parent AS GuiWindow) AS GuiTimer
    DIM realParent AS HWindow
    realParent.handle = parent.handle
    DIM t AS HTimer
    t = HTimerCreate(realParent)
    CALL EbGuiHaikuAssocSet(t.handle, t.target.handle)
    DIM result AS GuiTimer
    result.handle = t.handle
    NewGuiTimer = result
END FUNCTION

SUB GuiTimerSetInterval(t AS GuiTimer, milliseconds AS INTEGER)
    DIM realT AS HTimer
    realT.handle = t.handle
    CALL HTimerSetInterval(realT, CLngInt(milliseconds) * 1000)
END SUB

SUB GuiTimerSetSingleShot(t AS GuiTimer, singleShot AS INTEGER)
    DIM realT AS HTimer
    realT.handle = t.handle
    CALL HTimerSetSingleShot(realT, singleShot)
END SUB

SUB GuiTimerConnectTimeout(t AS GuiTimer, handler AS ANY PTR, userData AS ANY PTR)
    DIM realT AS HTimer
    realT.handle = t.handle
    realT.target.handle = EbGuiHaikuAssocGet(t.handle)
    CALL HTimerConnectTimeout(realT, handler, userData)
END SUB

SUB GuiTimerStart(t AS GuiTimer)
    DIM realT AS HTimer
    realT.handle = t.handle
    CALL HTimerStart(realT)
END SUB

SUB GuiTimerStop(t AS GuiTimer)
    DIM realT AS HTimer
    realT.handle = t.handle
    CALL HTimerStop(realT)
END SUB

FUNCTION GuiTimerIsActive(t AS GuiTimer) AS INTEGER
    DIM realT AS HTimer
    realT.handle = t.handle
    GuiTimerIsActive = HTimerIsActive(realT)
END FUNCTION

SUB GuiTimerDestroy(t AS GuiTimer)
    DIM realT AS HTimer
    realT.handle = t.handle
    CALL HTimerDestroy(realT)
END SUB

''' Real Haiku has no `BMenuBar`-owns-the-window auto-create-once
''' behavior of its own (unlike `eb-gtk4`'s `WindowMenuBar`) - this
''' adapter creates one, appended into the window's own shared content
''' layout, auto-created-once.
FUNCTION GuiWindowMenuBar(win AS GuiWindow) AS GuiMenuBar
    DIM realWin AS HWindow
    realWin.handle = win.handle
    DIM i AS INTEGER
    FOR i = 0 TO ebGuiHaikuMenuBarCount - 1
        IF ebGuiHaikuMenuBarKeys(i) = win.handle THEN
            DIM existingResult AS GuiMenuBar
            existingResult.handle = ebGuiHaikuMenuBarVals(i)
            GuiWindowMenuBar = existingResult
            EXIT FUNCTION
        END IF
    NEXT i
    DIM layout AS HGroupLayout
    layout = EbGuiHaikuContentLayout(realWin)
    DIM bar AS HMenu
    bar = HMenuBarCreate("eb-gui-haiku-menubar")
    CALL HGroupLayoutAddView(layout, bar.handle)
    ebGuiHaikuMenuBarKeys(ebGuiHaikuMenuBarCount) = win.handle
    ebGuiHaikuMenuBarVals(ebGuiHaikuMenuBarCount) = bar.handle
    ebGuiHaikuMenuBarCount = ebGuiHaikuMenuBarCount + 1
    CALL EbGuiHaikuAssocSet(bar.handle, win.handle)
    DIM result AS GuiMenuBar
    result.handle = bar.handle
    GuiWindowMenuBar = result
END FUNCTION

FUNCTION GuiMenuBarAddMenu(bar AS GuiMenuBar, title AS ZSTRING) AS GuiMenu
    DIM realBar AS HMenu
    realBar.handle = bar.handle
    DIM m AS HMenu
    m = HMenuCreate(title)
    CALL HMenuAddSubmenu(realBar, m)
    DIM winHandle AS ANY PTR
    winHandle = EbGuiHaikuAssocGet(bar.handle)
    CALL EbGuiHaikuAssocSet(m.handle, winHandle)
    DIM result AS GuiMenu
    result.handle = m.handle
    GuiMenuBarAddMenu = result
END FUNCTION

''' A brand-new `HMenuItem`, plus its own `HHandler` (attached to
''' `guiMenu`'s owning window's own `BLooper`) redirected via
''' `HMenuItemSetTarget` - the real per-object callback path eb-haiku's
''' own `v0.14.0` added specifically for this.
FUNCTION GuiMenuAddAction(guiMenu AS GuiMenu, text AS ZSTRING) AS GuiAction
    DIM winHandle AS ANY PTR
    winHandle = EbGuiHaikuAssocGet(guiMenu.handle)
    DIM realWin AS HWindow
    realWin.handle = winHandle
    DIM realMenu AS HMenu
    realMenu.handle = guiMenu.handle
    DIM msg AS HMessage
    msg = HMessageCreate(1)
    DIM item AS HMenuItem
    item = HMenuItemCreate(text, msg)
    CALL HMenuAddItem(realMenu, item)
    DIM h AS HHandler
    h = HHandlerCreate()
    CALL HWindowAddHandler(realWin, h)
    CALL HMenuItemSetTarget(item, h)
    CALL EbGuiHaikuAssocSet(item.handle, h.handle)
    DIM result AS GuiAction
    result.handle = item.handle
    GuiMenuAddAction = result
END FUNCTION

''' Bridged directly to the action's own `HHandler` (tracked via this
''' adapter's association table, set at creation).
SUB GuiActionConnectTriggered(a AS GuiAction, handler AS ANY PTR, userData AS ANY PTR)
    DIM handlerHandle AS ANY PTR
    handlerHandle = EbGuiHaikuAssocGet(a.handle)
    DIM h AS HHandler
    h.handle = handlerHandle
    CALL HHandlerSetCallback(h, handler, userData)
END SUB

''' Dispatches to whichever concrete type `a` actually is - see
''' EbGuiHaikuIsButtonAction's own doc comment above for why this
''' bookkeeping is needed at all.
SUB GuiActionSetEnabled(a AS GuiAction, enabled AS INTEGER)
    IF EbGuiHaikuIsButtonAction(a.handle) = 1 THEN
        CALL HControlSetEnabled(a.handle, enabled)
    ELSE
        DIM realItem AS HMenuItem
        realItem.handle = a.handle
        CALL HMenuItemSetEnabled(realItem, enabled)
    END IF
END SUB

''' Real for a toolbar action (HControlIsEnabled) - not bound at all for
''' a menu action (eb-haiku has no HMenuItemIsEnabled), where this
''' always reports enabled, matching eb-gui-gtk4's own identical
''' limitation.
FUNCTION GuiActionIsEnabled(a AS GuiAction) AS INTEGER
    IF EbGuiHaikuIsButtonAction(a.handle) = 1 THEN
        GuiActionIsEnabled = HControlIsEnabled(a.handle)
    ELSE
        GuiActionIsEnabled = 1
    END IF
END FUNCTION

SUB GuiActionTrigger(a AS GuiAction)
    IF EbGuiHaikuIsButtonAction(a.handle) = 1 THEN
        DIM realBtn AS HButton
        realBtn.handle = a.handle
        CALL HButtonInvoke(realBtn)
    ELSE
        DIM realItem AS HMenuItem
        realItem.handle = a.handle
        CALL HMenuItemInvokeViaMessenger(realItem)
    END IF
END SUB

''' Real Haiku has no toolbar widget at all - this adapter composes a
''' horizontal row of `BButton`s (the same "just a row of buttons"
''' shape `eb-gui-gtk4`'s own toolbar uses for the identical GTK4 gap),
''' appended into the window's own shared content layout,
''' auto-created-once.
FUNCTION GuiWindowToolBar(win AS GuiWindow) AS GuiToolBar
    DIM realWin AS HWindow
    realWin.handle = win.handle
    DIM i AS INTEGER
    FOR i = 0 TO ebGuiHaikuToolBarCount - 1
        IF ebGuiHaikuToolBarKeys(i) = win.handle THEN
            DIM existingResult AS GuiToolBar
            existingResult.handle = ebGuiHaikuToolBarVals(i)
            GuiWindowToolBar = existingResult
            EXIT FUNCTION
        END IF
    NEXT i
    DIM outerLayout AS HGroupLayout
    outerLayout = EbGuiHaikuContentLayout(realWin)
    DIM barLayout AS HGroupLayout
    barLayout = HGroupLayoutCreate(H_HORIZONTAL, 0)
    DIM barView AS HView
    barView = HViewCreate(0, 0, 0, 0, "eb-gui-haiku-toolbar", H_FOLLOW_ALL, 0)
    CALL HViewSetLayout(barView.handle, barLayout.handle)
    CALL HGroupLayoutAddView(outerLayout, barView.handle)
    ebGuiHaikuToolBarKeys(ebGuiHaikuToolBarCount) = win.handle
    ebGuiHaikuToolBarVals(ebGuiHaikuToolBarCount) = barView.handle
    ebGuiHaikuToolBarCount = ebGuiHaikuToolBarCount + 1
    CALL EbGuiHaikuAssocSet(barView.handle, win.handle)
    DIM result AS GuiToolBar
    result.handle = barView.handle
    GuiWindowToolBar = result
END FUNCTION

''' A brand-new `HButton`, plus its own `HHandler`, redirected via the
''' same per-object-target mechanism `GuiMenuAddAction` uses for menu
''' items (`HButtonSetTarget`, eb-haiku v0.14.1+).
FUNCTION GuiToolBarAddAction(bar AS GuiToolBar, text AS ZSTRING) AS GuiAction
    DIM winHandle AS ANY PTR
    winHandle = EbGuiHaikuAssocGet(bar.handle)
    DIM realWin AS HWindow
    realWin.handle = winHandle
    DIM barView AS HView
    barView.handle = bar.handle
    DIM btn AS HButton
    btn = HButtonCreate(0, 0, 0, 0, "eb-gui-haiku-toolbar-button", text, 0)
    CALL HViewAddChild(barView, btn.handle)
    DIM h AS HHandler
    h = HHandlerCreate()
    CALL HWindowAddHandler(realWin, h)
    CALL HButtonSetTarget(btn, h)
    CALL EbGuiHaikuAssocSet(btn.handle, h.handle)
    CALL EbGuiHaikuMarkButtonAction(btn.handle)
    DIM result AS GuiAction
    result.handle = btn.handle
    GuiToolBarAddAction = result
END FUNCTION
