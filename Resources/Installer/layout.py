from pathlib import Path

installer = Path(defines["artwork"])
app = Path(defines["app"]).resolve()
files = [str(app)]
symlinks = {"Applications": "/Applications"}
icon = str(app / "Contents/Resources/AppIcon.icns")
format = "ULFO"
filesystem = "APFS"
background = str(installer / "background.png")
window_rect = ((220, 160), (580, 252))
icon_locations = {app.name: (150, 88), "Applications": (430, 88)}
icon_size = 96
text_size = 14
show_toolbar = False
show_status_bar = False
