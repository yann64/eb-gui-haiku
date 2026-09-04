' Live example: a GuiBox containing a GuiLabel + GuiEntry + GuiButton -
' clicking the button reads the entry's text and updates the label,
' via eb-gui's universal Widget/Layout contract (Round 1 widgets/
' layout + Round 2 constraints + Round 3 min/max size). Same shape as
' eb-gui-gtk4/eb-gui-qt6's own examples/widgets_form. The "Go" button
' is added with GuiBoxAddChildEx(expand=1.0, GUI_ALIGN_FILL, ...) so it
' visibly stretches to the box's full width - the visual proof Round
' 2's per-child weight/alignment actually takes effect on real Haiku.
'
' Round 3's GuiWidgetSetMinSize/SetMaxSize are deliberately NOT
' demoed visually here: like every real box-layout system (GTK4's
' hexpand/vexpand, Qt6's stretch factor), min/max size are a floor/
' ceiling on the space the layout is ALLOWED to allocate, not a growth
' mechanism by themselves - a min-size'd item with no weight (the case
' here) just gets clamped up to its floor when squeezed, but doesn't
' claim leftover slack, so it wouldn't visibly grow in this already-
' spacious window. eb-haiku's own pre-existing
' tests/nested_layout_basics.bas pairs HViewSetExplicitMinSize with a
' nonzero HGroupLayoutSetItemWeight for exactly this reason - see
' eb-gui's own README for the full explanation.

#include "gui-haiku.iface.bas"

CONST GUI_ORIENTATION_VERTICAL = 1

DIM lbl AS GuiLabel

SUB OnClicked(userData AS ANY PTR)
    DIM e AS GuiEntry
    e.handle = userData
    CALL GuiLabelSetText(lbl, GuiEntryGetText(e))
END SUB

DIM app AS GuiApplication
app = NewGuiApplication("application/x-vnd.EbGuiHaiku-WidgetsForm")

DIM win AS GuiWindow
win = NewGuiWindow(app, "eb-gui-haiku Widgets Form", 320, 200)

DIM formBox AS GuiBox
formBox = NewGuiBox(GUI_ORIENTATION_VERTICAL, 8)

lbl = NewGuiLabel("Type something, then click Go")
CALL GuiBoxAddChild(formBox, lbl.handle)

DIM entryField AS GuiEntry
entryField = NewGuiEntry("")
CALL GuiBoxAddChild(formBox, entryField.handle)

DIM btn AS GuiButton
btn = NewGuiButton("Go")
CALL GuiButtonConnectClicked(btn, @OnClicked, entryField.handle)
CALL GuiBoxAddChildEx(formBox, btn.handle, 1.0, GUI_ALIGN_FILL, GUI_ALIGN_CENTER)

CALL GuiWindowSetContent(win, formBox.handle)
CALL GuiWindowShow(win)

CALL GuiApplicationRun(app)
PRINT "GuiApplicationRun returned"
