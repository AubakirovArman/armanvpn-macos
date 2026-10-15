from pathlib import Path

project = Path(defines["project"])
app = project / ".build/distribution/Build/Products/Release/armanVPN.app"
format = "UDZO"
filesystem = "HFS+"
files = [str(app), str(project / "packaging/Начать здесь.txt")]
symlinks = {"Applications": "/Applications"}
background = "#10151e"
window_rect = ((220, 160), (600, 430))
default_view = "icon-view"
icon_locations = {"armanVPN.app": (150, 150), "Applications": (450, 150), "Начать здесь.txt": (300, 330)}
icon_size = 104
text_size = 13
show_status_bar = False
show_toolbar = False
show_sidebar = False
show_tab_view = False
show_pathbar = False
icon = str(app / "Contents/Resources/AppIcon.icns")
