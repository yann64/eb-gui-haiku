' The project's own established cross-backend proof - same calls, same
' shape as eb-gui-gtk4/eb-gui-qt6's own hello_window.bas, differing only
' in the #include target and two string literals.

#include "gui-haiku.iface.bas"

DIM app AS GuiApplication
app = NewGuiApplication("application/x-vnd.EbGuiHaiku-HelloWindow")

DIM win AS GuiWindow
win = NewGuiWindow(app, "Hello, eb-gui-haiku!", 400, 300)
CALL GuiWindowShow(win)

CALL GuiApplicationRun(app)
