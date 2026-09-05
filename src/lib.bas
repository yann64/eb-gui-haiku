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

''' Tracked so widget-level GuiButtonConnectClicked/GuiEntryConnectChanged
''' (which the contract gives no window reference to) have somewhere to
''' attach their own per-object HHandler - eb-gui's own model has
''' exactly one GuiApplication per process anyway (matching this whole
''' framework's own single-application assumption throughout).
DIM ebGuiHaikuAppHandle AS ANY PTR

FUNCTION NewGuiApplication(appId AS ZSTRING) AS GuiApplication
    DIM realApp AS HApplication
    realApp = HApplicationCreate(appId)
    ebGuiHaikuAppHandle = realApp.handle
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

FUNCTION NewGuiButton(text AS ZSTRING) AS GuiButton
    DIM realBtn AS HButton
    realBtn = HButtonCreate(0, 0, 0, 0, "eb-gui-haiku-widget-button", text, 0)
    DIM result AS GuiButton
    result.handle = realBtn.handle
    NewGuiButton = result
END FUNCTION

SUB GuiButtonSetText(b AS GuiButton, text AS ZSTRING)
    DIM realBtn AS HButton
    realBtn.handle = b.handle
    CALL HButtonSetLabel(realBtn, text)
END SUB

FUNCTION GuiButtonGetText(b AS GuiButton) AS ZSTRING
    DIM realBtn AS HButton
    realBtn.handle = b.handle
    GuiButtonGetText = HButtonGetLabel(realBtn)
END FUNCTION

''' A fresh `HHandler`, attached to the APPLICATION's own `BLooper`
''' (`HApplicationAddHandler`, eb-haiku v0.14.3+) rather than a specific
''' window's - this contract function gets no window reference at all,
''' unlike `GuiMenuAddAction`/`GuiToolBarAddAction` (which always know
''' their owning window via the association table).
SUB GuiButtonConnectClicked(b AS GuiButton, handler AS ANY PTR, userData AS ANY PTR)
    DIM realBtn AS HButton
    realBtn.handle = b.handle
    DIM realApp AS HApplication
    realApp.handle = ebGuiHaikuAppHandle
    DIM h AS HHandler
    h = HHandlerCreate()
    CALL HApplicationAddHandler(realApp, h)
    CALL HButtonSetTarget(realBtn, h)
    CALL HHandlerSetCallback(h, handler, userData)
END SUB

FUNCTION NewGuiLabel(text AS ZSTRING) AS GuiLabel
    DIM realLbl AS HStringView
    realLbl = HStringViewCreate(0, 0, 0, 0, "eb-gui-haiku-label", text)
    DIM result AS GuiLabel
    result.handle = realLbl.handle
    NewGuiLabel = result
END FUNCTION

SUB GuiLabelSetText(l AS GuiLabel, text AS ZSTRING)
    DIM realLbl AS HStringView
    realLbl.handle = l.handle
    CALL HStringViewSetText(realLbl, text)
END SUB

FUNCTION NewGuiEntry(text AS ZSTRING) AS GuiEntry
    DIM realEntry AS HTextControl
    realEntry = HTextControlCreate(0, 0, 0, 0, "eb-gui-haiku-entry", "", text, 0)
    DIM result AS GuiEntry
    result.handle = realEntry.handle
    NewGuiEntry = result
END FUNCTION

SUB GuiEntrySetText(e AS GuiEntry, text AS ZSTRING)
    DIM realEntry AS HTextControl
    realEntry.handle = e.handle
    CALL HTextControlSetText(realEntry, text)
END SUB

FUNCTION GuiEntryGetText(e AS GuiEntry) AS ZSTRING
    DIM realEntry AS HTextControl
    realEntry.handle = e.handle
    GuiEntryGetText = HTextControlGetText(realEntry)
END FUNCTION

''' Same application-attached `HHandler` mechanism as
''' `GuiButtonConnectClicked` above (`HTextControlSetTarget`, eb-haiku
''' v0.14.2+).
SUB GuiEntryConnectChanged(e AS GuiEntry, handler AS ANY PTR, userData AS ANY PTR)
    DIM realEntry AS HTextControl
    realEntry.handle = e.handle
    DIM realApp AS HApplication
    realApp.handle = ebGuiHaikuAppHandle
    DIM h AS HHandler
    h = HHandlerCreate()
    CALL HApplicationAddHandler(realApp, h)
    CALL HTextControlSetTarget(realEntry, h)
    CALL HHandlerSetCallback(h, handler, userData)
END SUB

''' A real `HGroupLayout` is NOT itself a `BView`, unlike GTK4's own
''' `Box` - so `GuiBox.handle` here is really a small holder `HView`
''' (created here, with the real layout applied via `HViewSetLayout`),
''' matching `eb-gui-qt6`'s identical holder-widget shape (see
''' `eb-gui`'s own README on this asymmetry). The real layout is
''' tracked separately (the generic association table) so
''' `GuiBoxAddChild` knows which one to call `HLayoutAddView` on.
FUNCTION NewGuiBox(orientation AS INTEGER, spacing AS INTEGER) AS GuiBox
    DIM realLayout AS HGroupLayout
    realLayout = HGroupLayoutCreate(orientation, spacing)
    DIM holder AS HView
    holder = HViewCreate(0, 0, 0, 0, "eb-gui-haiku-box", H_FOLLOW_ALL, 0)
    CALL HViewSetLayout(holder.handle, realLayout.handle)
    CALL EbGuiHaikuAssocSet(holder.handle, realLayout.handle)
    DIM result AS GuiBox
    result.handle = holder.handle
    NewGuiBox = result
END FUNCTION

''' Tracks each GuiBox's own running child count (0-based insertion
''' index) - HGroupLayoutSetItemWeight is index-based, not
''' view-identity-based (unlike eb-qt6's own stretch-factor-on-the-
''' widget-itself shape), so this adapter has to count. Returns the
''' index for the child being added right now, then increments.
DIM ebGuiHaikuBoxChildCountKeys(128) AS ANY PTR
DIM ebGuiHaikuBoxChildCountVals(128) AS INTEGER
DIM ebGuiHaikuBoxChildCountEntries AS INTEGER

FUNCTION EbGuiHaikuBoxNextChildIndex(boxHandle AS ANY PTR) AS INTEGER
    DIM i AS INTEGER
    FOR i = 0 TO ebGuiHaikuBoxChildCountEntries - 1
        IF ebGuiHaikuBoxChildCountKeys(i) = boxHandle THEN
            EbGuiHaikuBoxNextChildIndex = ebGuiHaikuBoxChildCountVals(i)
            ebGuiHaikuBoxChildCountVals(i) = ebGuiHaikuBoxChildCountVals(i) + 1
            EXIT FUNCTION
        END IF
    NEXT i
    ebGuiHaikuBoxChildCountKeys(ebGuiHaikuBoxChildCountEntries) = boxHandle
    ebGuiHaikuBoxChildCountVals(ebGuiHaikuBoxChildCountEntries) = 1
    ebGuiHaikuBoxChildCountEntries = ebGuiHaikuBoxChildCountEntries + 1
    EbGuiHaikuBoxNextChildIndex = 0
END FUNCTION

SUB GuiBoxAddChild(bx AS GuiBox, child AS ANY PTR)
    DIM realLayoutHandle AS ANY PTR
    realLayoutHandle = EbGuiHaikuAssocGet(bx.handle)
    CALL HLayoutAddView(realLayoutHandle, child)
    ' Keep the index counter in sync even for a plain (non-Ex) add, so
    ' mixing GuiBoxAddChild/GuiBoxAddChildEx calls on the same box still
    ' assigns each later GuiBoxAddChildEx child the correct real index.
    CALL EbGuiHaikuBoxNextChildIndex(bx.handle)
END SUB

''' Maps the contract's toolkit-neutral GUI_ALIGN_* onto real Haiku's
''' own H_ALIGN_* constants. GUI_ALIGN_FILL maps to the real
''' H_ALIGN_USE_FULL_WIDTH sentinel (eb-haiku v0.14.4+) - NOT the same
''' as H_ALIGN_CENTER. A real, found-the-hard-way bug during this
''' round's own verification: approximating "fill" as "center" doesn't
''' just fail to stretch, it actively BREAKS the default stretch
''' behavior a view already has before HViewSetExplicitAlignment is
''' ever called (a live screenshot showed a "fill"-requested button
''' rendering centered at its natural size, when it should have
''' spanned the full width) - see eb-haiku's own v0.14.4 changelog.
FUNCTION EbGuiHaikuMapHAlign(guiAlign AS INTEGER) AS INTEGER
    IF guiAlign = GUI_ALIGN_START THEN
        EbGuiHaikuMapHAlign = H_ALIGN_LEFT
    ELSEIF guiAlign = GUI_ALIGN_CENTER THEN
        EbGuiHaikuMapHAlign = H_ALIGN_CENTER
    ELSEIF guiAlign = GUI_ALIGN_END THEN
        EbGuiHaikuMapHAlign = H_ALIGN_RIGHT
    ELSE
        EbGuiHaikuMapHAlign = H_ALIGN_USE_FULL_WIDTH
    END IF
END FUNCTION

FUNCTION EbGuiHaikuMapVAlign(guiAlign AS INTEGER) AS INTEGER
    IF guiAlign = GUI_ALIGN_START THEN
        EbGuiHaikuMapVAlign = H_ALIGN_TOP
    ELSEIF guiAlign = GUI_ALIGN_CENTER THEN
        EbGuiHaikuMapVAlign = H_ALIGN_MIDDLE
    ELSEIF guiAlign = GUI_ALIGN_END THEN
        EbGuiHaikuMapVAlign = H_ALIGN_BOTTOM
    ELSE
        EbGuiHaikuMapVAlign = H_ALIGN_USE_FULL_HEIGHT
    END IF
END FUNCTION

''' Like GuiBoxAddChild, but also sets the child's real, proportional
''' item weight on the real HGroupLayout (a genuine ratio, like
''' eb-gui-qt6's own stretch factor - unlike eb-gui-gtk4's boolean-only
''' expand) and its alignment.
SUB GuiBoxAddChildEx(bx AS GuiBox, child AS ANY PTR, expand AS SINGLE, halign AS INTEGER, valign AS INTEGER)
    DIM realLayoutHandle AS ANY PTR
    realLayoutHandle = EbGuiHaikuAssocGet(bx.handle)
    CALL HLayoutAddView(realLayoutHandle, child)
    DIM idx AS INTEGER
    idx = EbGuiHaikuBoxNextChildIndex(bx.handle)
    DIM realLayout AS HGroupLayout
    realLayout.handle = realLayoutHandle
    CALL HGroupLayoutSetItemWeight(realLayout, idx, expand)
    CALL HViewSetExplicitAlignment(child, EbGuiHaikuMapHAlign(halign), EbGuiHaikuMapVAlign(valign))
END SUB

FUNCTION NewGuiGrid() AS GuiGrid
    DIM realLayout AS HGridLayout
    realLayout = HGridLayoutCreate(0, 0)
    DIM holder AS HView
    holder = HViewCreate(0, 0, 0, 0, "eb-gui-haiku-grid", H_FOLLOW_ALL, 0)
    CALL HViewSetLayout(holder.handle, realLayout.handle)
    CALL EbGuiHaikuAssocSet(holder.handle, realLayout.handle)
    DIM result AS GuiGrid
    result.handle = holder.handle
    NewGuiGrid = result
END FUNCTION

SUB GuiGridAttach(gr AS GuiGrid, child AS ANY PTR, column AS INTEGER, row AS INTEGER, columnSpan AS INTEGER, rowSpan AS INTEGER)
    DIM realLayout AS HGridLayout
    realLayout.handle = EbGuiHaikuAssocGet(gr.handle)
    CALL HGridLayoutAddViewAt(realLayout, child, column, row, columnSpan, rowSpan)
END SUB

''' Like GuiGridAttach, but also sets the child's alignment within its cell.
SUB GuiGridAttachEx(gr AS GuiGrid, child AS ANY PTR, column AS INTEGER, row AS INTEGER, columnSpan AS INTEGER, rowSpan AS INTEGER, halign AS INTEGER, valign AS INTEGER)
    CALL GuiGridAttach(gr, child, column, row, columnSpan, rowSpan)
    CALL HViewSetExplicitAlignment(child, EbGuiHaikuMapHAlign(halign), EbGuiHaikuMapVAlign(valign))
END SUB

''' Real HGridLayoutSetColumnWeight/SetRowWeight - independent of which
''' view(s) occupy that column/row.
SUB GuiGridSetColumnWeight(gr AS GuiGrid, column AS INTEGER, weight AS SINGLE)
    DIM realLayout AS HGridLayout
    realLayout.handle = EbGuiHaikuAssocGet(gr.handle)
    CALL HGridLayoutSetColumnWeight(realLayout, column, weight)
END SUB

SUB GuiGridSetRowWeight(gr AS GuiGrid, row AS INTEGER, weight AS SINGLE)
    DIM realLayout AS HGridLayout
    realLayout.handle = EbGuiHaikuAssocGet(gr.handle)
    CALL HGridLayoutSetRowWeight(realLayout, row, weight)
END SUB

''' Direct pass-through to HViewSetExplicitMinSize/MaxSize - both
''' already real and bound, no prerequisite native work needed this
''' round (unlike eb-gui-gtk4's own GuiWidgetSetMaxSize, a documented
''' no-op - real GTK4 has no such API at all).
SUB GuiWidgetSetMinSize(handle AS ANY PTR, width AS INTEGER, height AS INTEGER)
    CALL HViewSetExplicitMinSize(handle, width, height)
END SUB

SUB GuiWidgetSetMaxSize(handle AS ANY PTR, width AS INTEGER, height AS INTEGER)
    CALL HViewSetExplicitMaxSize(handle, width, height)
END SUB

''' Appends `content` into the window's existing shared content layout
''' (`EbGuiHaikuContentLayout`) - call after `GuiWindowMenuBar`/
''' `GuiWindowToolBar` and before `GuiWindowStatusBar` for the expected
''' top-to-bottom visual order (unenforced convention, matching
''' `eb-gui-gtk4`'s identical precedent).
SUB GuiWindowSetContent(win AS GuiWindow, content AS ANY PTR)
    DIM realWin AS HWindow
    realWin.handle = win.handle
    DIM layout AS HGroupLayout
    layout = EbGuiHaikuContentLayout(realWin)
    CALL HLayoutAddView(layout.handle, content)
END SUB

FUNCTION NewGuiCheckBox(text AS ZSTRING) AS GuiCheckBox
    DIM realCb AS HCheckBox
    realCb = HCheckBoxCreate(0, 0, 0, 0, "eb-gui-haiku-checkbox", text, 0)
    DIM result AS GuiCheckBox
    result.handle = realCb.handle
    NewGuiCheckBox = result
END FUNCTION

SUB GuiCheckBoxSetChecked(cb AS GuiCheckBox, checked AS INTEGER)
    DIM realCb AS HCheckBox
    realCb.handle = cb.handle
    CALL HCheckBoxSetValue(realCb, checked)
END SUB

FUNCTION GuiCheckBoxIsChecked(cb AS GuiCheckBox) AS INTEGER
    DIM realCb AS HCheckBox
    realCb.handle = cb.handle
    GuiCheckBoxIsChecked = HCheckBoxGetValue(realCb)
END FUNCTION

''' Same application-attached `HHandler` mechanism as
''' `GuiButtonConnectClicked` (this contract function gets no window
''' reference at all).
SUB GuiCheckBoxConnectToggled(cb AS GuiCheckBox, handler AS ANY PTR, userData AS ANY PTR)
    DIM realCb AS HCheckBox
    realCb.handle = cb.handle
    DIM realApp AS HApplication
    realApp.handle = ebGuiHaikuAppHandle
    DIM h AS HHandler
    h = HHandlerCreate()
    CALL HApplicationAddHandler(realApp, h)
    CALL HCheckBoxSetTarget(realCb, h)
    CALL HHandlerSetCallback(h, handler, userData)
END SUB

FUNCTION NewGuiRadioButton(text AS ZSTRING) AS GuiRadioButton
    DIM realRb AS HRadioButton
    realRb = HRadioButtonCreate(0, 0, 0, 0, "eb-gui-haiku-radiobutton", text, 0)
    DIM result AS GuiRadioButton
    result.handle = realRb.handle
    NewGuiRadioButton = result
END FUNCTION

SUB GuiRadioButtonSetChecked(rb AS GuiRadioButton, checked AS INTEGER)
    DIM realRb AS HRadioButton
    realRb.handle = rb.handle
    CALL HRadioButtonSetValue(realRb, checked)
END SUB

FUNCTION GuiRadioButtonIsChecked(rb AS GuiRadioButton) AS INTEGER
    DIM realRb AS HRadioButton
    realRb.handle = rb.handle
    GuiRadioButtonIsChecked = HRadioButtonGetValue(realRb)
END FUNCTION

SUB GuiRadioButtonConnectToggled(rb AS GuiRadioButton, handler AS ANY PTR, userData AS ANY PTR)
    DIM realRb AS HRadioButton
    realRb.handle = rb.handle
    DIM realApp AS HApplication
    realApp.handle = ebGuiHaikuAppHandle
    DIM h AS HHandler
    h = HHandlerCreate()
    CALL HApplicationAddHandler(realApp, h)
    CALL HRadioButtonSetTarget(realRb, h)
    CALL HHandlerSetCallback(h, handler, userData)
END SUB

''' A documented no-op - real Haiku `BRadioButton`s that are direct
''' siblings in the same container already enforce mutual exclusivity
''' completely automatically (confirmed via a real 2-radio-button
''' sibling test on hardware, `eb-haiku` v0.15.0's own README) - no
''' group object of any kind needed.
SUB GuiRadioButtonSetGroup(rb AS GuiRadioButton, firstInGroup AS GuiRadioButton)
END SUB

''' `GuiComboBox` wraps `HMenuField`/`HMenu` (Haiku's real combo-box
''' analog) in radio mode (`HMenuSetRadioMode`, auto-exclusive marking
''' on selection - the same mechanism this package's own menu radio
''' items already use) plus `HMenuSetLabelFromMarked` (the field's own
''' displayed text follows whichever item is marked, matching a real
''' combo box's "shows the current selection" behavior). Neither
''' `HMenuItem` nor `HMenuField` expose a label-getter or a
''' which-item-is-selected query, so this adapter tracks each combo's
''' own items (handle + text, in insertion order) itself - the same
''' small-parallel-array pattern already used elsewhere in this
''' package, keyed by the combo's own field handle.
DIM ebGuiHaikuComboFieldKeys(256) AS ANY PTR
DIM ebGuiHaikuComboItemHandles(256) AS ANY PTR
DIM ebGuiHaikuComboItemTexts(256) AS STRING
DIM ebGuiHaikuComboCount AS INTEGER

FUNCTION NewGuiComboBox() AS GuiComboBox
    DIM realMenu AS HMenu
    realMenu = HMenuCreate("eb-gui-haiku-combo-menu")
    CALL HMenuSetRadioMode(realMenu, 1)
    CALL HMenuSetLabelFromMarked(realMenu, 1)
    DIM field AS HMenuField
    field = HMenuFieldCreate(0, 0, 0, 0, "eb-gui-haiku-combo", "", realMenu)
    DIM result AS GuiComboBox
    result.handle = field.handle
    NewGuiComboBox = result
END FUNCTION

SUB GuiComboBoxAddItem(cb AS GuiComboBox, text AS ZSTRING)
    DIM field AS HMenuField
    field.handle = cb.handle
    DIM realMenu AS HMenu
    realMenu = HMenuFieldMenu(field)
    DIM msg AS HMessage
    msg = HMessageCreate(0)
    DIM item AS HMenuItem
    item = HMenuItemCreate(text, msg)
    CALL HMenuAddItem(realMenu, item)

    ebGuiHaikuComboFieldKeys(ebGuiHaikuComboCount) = cb.handle
    ebGuiHaikuComboItemHandles(ebGuiHaikuComboCount) = item.handle
    ebGuiHaikuComboItemTexts(ebGuiHaikuComboCount) = text
    ebGuiHaikuComboCount = ebGuiHaikuComboCount + 1

    ' The first item added becomes selected by default (matches a real
    ' combo box always showing some current value) - mark it directly
    ' rather than waiting for a real or simulated selection.
    IF GuiComboBoxGetSelectedIndex(cb) < 0 THEN
        DIM firstItem AS HMenuItem
        firstItem.handle = item.handle
        CALL HMenuItemSetMarked(firstItem, 1)
    END IF
END SUB

''' Real 0-based insertion index among just THIS combo's own items
''' (found by scanning this adapter's own tracking table for the item
''' `HMenuItemIsMarked` reports true for) - real Haiku radio mode
''' guarantees at most one marked item at a time. Returns -1 if none
''' marked yet (an empty combo, or before the first AddItem call).
FUNCTION GuiComboBoxGetSelectedIndex(cb AS GuiComboBox) AS INTEGER
    DIM i AS INTEGER
    DIM localIndex AS INTEGER
    localIndex = 0
    FOR i = 0 TO ebGuiHaikuComboCount - 1
        IF ebGuiHaikuComboFieldKeys(i) = cb.handle THEN
            DIM item AS HMenuItem
            item.handle = ebGuiHaikuComboItemHandles(i)
            IF HMenuItemIsMarked(item) THEN
                GuiComboBoxGetSelectedIndex = localIndex
                EXIT FUNCTION
            END IF
            localIndex = localIndex + 1
        END IF
    NEXT i
    GuiComboBoxGetSelectedIndex = -1
END FUNCTION

SUB GuiComboBoxSetSelectedIndex(cb AS GuiComboBox, index AS INTEGER)
    DIM i AS INTEGER
    DIM localIndex AS INTEGER
    localIndex = 0
    FOR i = 0 TO ebGuiHaikuComboCount - 1
        IF ebGuiHaikuComboFieldKeys(i) = cb.handle THEN
            IF localIndex = index THEN
                DIM item AS HMenuItem
                item.handle = ebGuiHaikuComboItemHandles(i)
                CALL HMenuItemSetMarked(item, 1)
                EXIT SUB
            END IF
            localIndex = localIndex + 1
        END IF
    NEXT i
END SUB

FUNCTION GuiComboBoxGetSelectedText(cb AS GuiComboBox) AS ZSTRING
    DIM selectedIndex AS INTEGER
    selectedIndex = GuiComboBoxGetSelectedIndex(cb)
    DIM i AS INTEGER
    DIM localIndex AS INTEGER
    localIndex = 0
    FOR i = 0 TO ebGuiHaikuComboCount - 1
        IF ebGuiHaikuComboFieldKeys(i) = cb.handle THEN
            IF localIndex = selectedIndex THEN
                GuiComboBoxGetSelectedText = ebGuiHaikuComboItemTexts(i)
                EXIT FUNCTION
            END IF
            localIndex = localIndex + 1
        END IF
    NEXT i
    GuiComboBoxGetSelectedText = ""
END FUNCTION

''' Every item this combo owns AT THE TIME OF THIS CALL shares the same
''' target/callback - a real selection change (of any item) fires it,
''' matching "changed" semantics; call GuiComboBoxGetSelectedIndex/
''' GetSelectedText yourself from inside the handler to see which one.
''' Call this AFTER all GuiComboBoxAddItem calls for this combo -
''' items added afterward won't have the target wired (matching this
''' package's own established call-order conventions elsewhere, e.g.
''' GuiWindowSetContent).
SUB GuiComboBoxConnectChanged(cb AS GuiComboBox, handler AS ANY PTR, userData AS ANY PTR)
    DIM realApp AS HApplication
    realApp.handle = ebGuiHaikuAppHandle
    DIM h AS HHandler
    h = HHandlerCreate()
    CALL HApplicationAddHandler(realApp, h)
    CALL HHandlerSetCallback(h, handler, userData)

    DIM i AS INTEGER
    FOR i = 0 TO ebGuiHaikuComboCount - 1
        IF ebGuiHaikuComboFieldKeys(i) = cb.handle THEN
            DIM item AS HMenuItem
            item.handle = ebGuiHaikuComboItemHandles(i)
            CALL HMenuItemSetTarget(item, h)
        END IF
    NEXT i
END SUB

''' Real Haiku's actual progress-bar widget (`HStatusBar`, wrapping
''' `BStatusBar`) has no minimum-value concept at all - `min` in
''' `GuiProgressBarSetRange` is a documented, accepted no-op here
''' (matching the "document the loss, don't block the feature"
''' precedent already established for GTK4's own missing grid weight
''' and max-size).
FUNCTION NewGuiProgressBar() AS GuiProgressBar
    DIM realBar AS HStatusBar
    realBar = HStatusBarCreate(0, 0, 0, 0, "eb-gui-haiku-progressbar", "", "")
    DIM result AS GuiProgressBar
    result.handle = realBar.handle
    NewGuiProgressBar = result
END FUNCTION

SUB GuiProgressBarSetRange(pb AS GuiProgressBar, min AS INTEGER, max AS INTEGER)
    DIM realBar AS HStatusBar
    realBar.handle = pb.handle
    CALL HStatusBarSetMaxValue(realBar, max)
END SUB

FUNCTION GuiProgressBarGetValue(pb AS GuiProgressBar) AS INTEGER
    DIM realBar AS HStatusBar
    realBar.handle = pb.handle
    GuiProgressBarGetValue = HStatusBarCurrentValue(realBar)
END FUNCTION

SUB GuiProgressBarSetValue(pb AS GuiProgressBar, value AS INTEGER)
    DIM realBar AS HStatusBar
    realBar.handle = pb.handle
    CALL HStatusBarSetTo(realBar, value)
END SUB

FUNCTION NewGuiSlider(orientation AS INTEGER) AS GuiSlider
    DIM realSlider AS HSlider
    realSlider = HSliderCreate(0, 0, 0, 0, "eb-gui-haiku-slider", "", 0, 100, 0)
    DIM result AS GuiSlider
    result.handle = realSlider.handle
    NewGuiSlider = result
END FUNCTION

SUB GuiSliderSetRange(s AS GuiSlider, min AS INTEGER, max AS INTEGER)
    DIM realSlider AS HSlider
    realSlider.handle = s.handle
    CALL HSliderSetLimits(realSlider, min, max)
END SUB

FUNCTION GuiSliderGetValue(s AS GuiSlider) AS INTEGER
    DIM realSlider AS HSlider
    realSlider.handle = s.handle
    GuiSliderGetValue = HSliderGetValue(realSlider)
END FUNCTION

SUB GuiSliderSetValue(s AS GuiSlider, value AS INTEGER)
    DIM realSlider AS HSlider
    realSlider.handle = s.handle
    CALL HSliderSetValue(realSlider, value)
END SUB

''' Same application-attached `HHandler` mechanism as
''' `GuiButtonConnectClicked`.
SUB GuiSliderConnectValueChanged(s AS GuiSlider, handler AS ANY PTR, userData AS ANY PTR)
    DIM realSlider AS HSlider
    realSlider.handle = s.handle
    DIM realApp AS HApplication
    realApp.handle = ebGuiHaikuAppHandle
    DIM h AS HHandler
    h = HHandlerCreate()
    CALL HApplicationAddHandler(realApp, h)
    CALL HSliderSetTarget(realSlider, h)
    CALL HHandlerSetCallback(h, handler, userData)
END SUB

''' Real `BListView` (`eb-haiku`'s own `HListView`) has no by-index
''' item-text getter at all - only each item's own `HStringItemGetText`
''' - and no way to read the item HANDLE back at a given index either.
''' This adapter tracks each list box's own item texts itself, the same
''' small-parallel-array pattern already used for `GuiComboBox` above.
DIM ebGuiHaikuListBoxKeys(1024) AS ANY PTR
DIM ebGuiHaikuListBoxItemTexts(1024) AS STRING
DIM ebGuiHaikuListBoxCount AS INTEGER

FUNCTION NewGuiListBox() AS GuiListBox
    DIM realList AS HListView
    realList = HListViewCreate(0, 0, 0, 0, "eb-gui-haiku-listbox", 0)
    DIM result AS GuiListBox
    result.handle = realList.handle
    NewGuiListBox = result
END FUNCTION

SUB GuiListBoxAddItem(lb AS GuiListBox, text AS ZSTRING)
    DIM realList AS HListView
    realList.handle = lb.handle
    DIM item AS HStringItem
    item = HStringItemCreate(text)
    CALL HListViewAddItem(realList, item.handle)

    ebGuiHaikuListBoxKeys(ebGuiHaikuListBoxCount) = lb.handle
    ebGuiHaikuListBoxItemTexts(ebGuiHaikuListBoxCount) = text
    ebGuiHaikuListBoxCount = ebGuiHaikuListBoxCount + 1
END SUB

FUNCTION GuiListBoxGetItemText(lb AS GuiListBox, index AS INTEGER) AS ZSTRING
    DIM i AS INTEGER
    DIM localIndex AS INTEGER
    localIndex = 0
    FOR i = 0 TO ebGuiHaikuListBoxCount - 1
        IF ebGuiHaikuListBoxKeys(i) = lb.handle THEN
            IF localIndex = index THEN
                GuiListBoxGetItemText = ebGuiHaikuListBoxItemTexts(i)
                EXIT FUNCTION
            END IF
            localIndex = localIndex + 1
        END IF
    NEXT i
    GuiListBoxGetItemText = ""
END FUNCTION

FUNCTION GuiListBoxGetCount(lb AS GuiListBox) AS INTEGER
    DIM realList AS HListView
    realList.handle = lb.handle
    GuiListBoxGetCount = HListViewCountItems(realList)
END FUNCTION

''' Also drops this list box's own tracked item texts (compacts the
''' shared table) - same reasoning as eb-gui-qt6's own GuiListBoxClear.
SUB GuiListBoxClear(lb AS GuiListBox)
    DIM realList AS HListView
    realList.handle = lb.handle
    CALL HListViewMakeEmpty(realList)

    DIM i AS INTEGER
    DIM writeIndex AS INTEGER
    writeIndex = 0
    FOR i = 0 TO ebGuiHaikuListBoxCount - 1
        IF ebGuiHaikuListBoxKeys(i) <> lb.handle THEN
            ebGuiHaikuListBoxKeys(writeIndex) = ebGuiHaikuListBoxKeys(i)
            ebGuiHaikuListBoxItemTexts(writeIndex) = ebGuiHaikuListBoxItemTexts(i)
            writeIndex = writeIndex + 1
        END IF
    NEXT i
    ebGuiHaikuListBoxCount = writeIndex
END SUB

''' Direct pass-through - real BListView::CurrentSelection() already
''' returns -1 when nothing is selected, exactly matching this
''' contract function's own convention.
FUNCTION GuiListBoxGetSelectedIndex(lb AS GuiListBox) AS INTEGER
    DIM realList AS HListView
    realList.handle = lb.handle
    GuiListBoxGetSelectedIndex = HListViewCurrentSelection(realList)
END FUNCTION

SUB GuiListBoxSetSelectedIndex(lb AS GuiListBox, index AS INTEGER)
    DIM realList AS HListView
    realList.handle = lb.handle
    CALL HListViewSelect(realList, index)
END SUB

''' Direct pass-through to `HListViewSetSelectionChangedCallback` - NOT
''' the usual `HApplicationAddHandler`+`SetTarget` pattern used by
''' `GuiButtonConnectClicked`/`GuiSliderConnectValueChanged` above: real
''' `BListView` has no `BInvoker`/target+message mechanism for
''' per-selection-change notification at all (see `eb-haiku`'s own
''' `listview.bas` top comment), so its own `ShimListView` subclass
''' forwards straight from a real virtual `SelectionChanged()` override
''' to a plain callback - already self-contained, no `HHandler` needed.
SUB GuiListBoxConnectSelectionChanged(lb AS GuiListBox, handler AS ANY PTR, userData AS ANY PTR)
    DIM realList AS HListView
    realList.handle = lb.handle
    CALL HListViewSetSelectionChangedCallback(realList, handler, userData)
END SUB

FUNCTION NewGuiTextView() AS GuiTextView
    DIM realView AS HTextView
    realView = HTextViewCreate(0, 0, 0, 0, "eb-gui-haiku-textview")
    DIM result AS GuiTextView
    result.handle = realView.handle
    NewGuiTextView = result
END FUNCTION

SUB GuiTextViewSetText(tv AS GuiTextView, text AS ZSTRING)
    DIM realView AS HTextView
    realView.handle = tv.handle
    CALL HTextViewSetText(realView, text)
END SUB

''' Borrowed from real BTextView's own long-lived storage - no
''' heap allocation, no leak (unlike eb-gui-gtk4/eb-gui-qt6's own
''' GuiTextViewGetText, which each leak a small per-call buffer).
FUNCTION GuiTextViewGetText(tv AS GuiTextView) AS ZSTRING
    DIM realView AS HTextView
    realView.handle = tv.handle
    GuiTextViewGetText = HTextViewGetText(realView)
END FUNCTION

SUB GuiTextViewSetEditable(tv AS GuiTextView, editable AS INTEGER)
    DIM realView AS HTextView
    realView.handle = tv.handle
    CALL HTextViewMakeEditable(realView, editable)
END SUB

''' A documented, accepted no-op - CONFIRMED via 6 standalone C++
''' probes directly against real BGroupLayout/BButton on real Haiku
''' hardware (not assumed from the API's own name or documentation):
''' real BView::SetExplicitPreferredSize correctly STORES the value
''' (PreferredSize() reports it back when queried directly), but
''' BGroupLayout never actually CONSULTS it when computing an item's
''' real rendered size - not with fill alignment, not with nonzero
''' weight, not under a forced resize/squeeze, not for the enclosing
''' window's own auto-sizing. SetExplicitMinSize (GuiWidgetSetMinSize,
''' Round 3), tested identically, DOES reliably enforce its floor in
''' every one of those same scenarios - confirming this is a real,
''' specific gap in how BGroupLayout uses PreferredSize(), not a
''' mistake in this adapter's own call. See eb-gui's own README for
''' the full probe writeup.
SUB GuiWidgetSetPreferredSize(handle AS ANY PTR, width AS INTEGER, height AS INTEGER)
END SUB
