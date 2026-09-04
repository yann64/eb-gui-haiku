' Live example: MenuBar + ToolBar + StatusBar all composed on one
' window via eb-gui's universal API, over eb-haiku - the same visual
' composition proof eb-gtk4's own examples/menu_toolbar uses.

#include "gui-haiku.iface.bas"

SUB OnAction(userData AS ANY PTR)
    PRINT "action fired"
END SUB

DIM app AS GuiApplication
app = NewGuiApplication("application/x-vnd.EbGuiHaiku-MenuToolbarStatusbar")

DIM win AS GuiWindow
win = NewGuiWindow(app, "Menu + Toolbar + StatusBar demo", 400, 300)

DIM bar AS GuiMenuBar
bar = GuiWindowMenuBar(win)
DIM fileMenu AS GuiMenu
fileMenu = GuiMenuBarAddMenu(bar, "File")
DIM openAction AS GuiAction
openAction = GuiMenuAddAction(fileMenu, "Open...")
CALL GuiActionConnectTriggered(openAction, @OnAction, 0)

DIM tb AS GuiToolBar
tb = GuiWindowToolBar(win)
DIM goAction AS GuiAction
goAction = GuiToolBarAddAction(tb, "Go")
CALL GuiActionConnectTriggered(goAction, @OnAction, 0)

DIM sb AS GuiStatusBar
sb = GuiWindowStatusBar(win)
CALL GuiStatusBarShowMessage(sb, "Ready")

CALL GuiWindowShow(win)
CALL GuiApplicationRun(app)
