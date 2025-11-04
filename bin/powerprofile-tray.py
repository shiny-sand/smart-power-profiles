#!/usr/bin/env python3
# Power Profile Tray Indicator for Ubuntu 25.10
# Works with auto-powerprofile.sh to show and control current power mode.
# Supports AppIndicator3 or AyatanaAppIndicator3 depending on system.
# Author: ChatGPT (GPT-5)

import gi, subprocess, os, time, threading

gi.require_version("Gtk", "3.0")
try:
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3
except ValueError:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator3

from gi.repository import Gtk, GLib

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------
ICON_MAP = {
    "power-saver": "🌙",
    "balanced": "⚙️",
    "performance": "⚡"
}

STATE_FILE = os.path.expanduser("~/.cache/powerprofile.state")
OVERRIDE_FILE = os.path.expanduser("~/.cache/powerprofile.override")

# ------------------------------------------------------------
# HELPER FUNCTIONS
# ------------------------------------------------------------
def get_state():
    """Return the current active power profile."""
    try:
        return subprocess.check_output(["powerprofilesctl", "get"], text=True).strip()
    except Exception:
        return "unknown"

def set_state(mode):
    """Set a specific profile, or return to auto if 'auto' chosen."""
    if mode == "auto":
        if os.path.exists(OVERRIDE_FILE):
            os.remove(OVERRIDE_FILE)
        subprocess.call(["notify-send", "Power Profile", "Auto mode (override cleared)"])
        refresh_icon()
        return

    # Manual override
    with open(OVERRIDE_FILE, "w") as f:
        f.write(mode)
    subprocess.call(["powerprofilesctl", "set", mode])
    subprocess.call(["notify-send", "Power Profile", f"{mode.capitalize()} mode activated"])
    refresh_icon()

def refresh_icon():
    """Update tray label to match current power mode."""
    mode = get_state()
    icon = ICON_MAP.get(mode, "❔")
    indicator.set_label(icon, "")

def monitor_loop():
    """Watch for external profile changes and update the icon."""
    last = ""
    while True:
        mode = get_state()
        if mode != last:
            GLib.idle_add(indicator.set_label, ICON_MAP.get(mode, "❔"), "")
            last = mode
        time.sleep(5)

# ------------------------------------------------------------
# TRAY MENU SETUP
# ------------------------------------------------------------
indicator = AppIndicator3.Indicator.new(
    "powerprofile-indicator",
    "indicator-messages",  # invisible placeholder in most icon themes
    AppIndicator3.IndicatorCategory.APPLICATION_STATUS
)
indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
indicator.set_label("🌙", "")  # start with moon icon
refresh_icon()



menu = Gtk.Menu()
for label, mode in [
    ("Quiet (power-saver)", "power-saver"),
    ("Balanced", "balanced"),
    ("Performance", "performance"),
    ("Auto (remove override)", "auto"),
    ("Quit", "quit")
]:
    item = Gtk.MenuItem(label=label)
    if mode == "quit":
        item.connect("activate", lambda _: Gtk.main_quit())
    else:
        item.connect("activate", lambda _, m=mode: set_state(m))
    menu.append(item)

menu.show_all()
indicator.set_menu(menu)

# ------------------------------------------------------------
# BACKGROUND MONITOR
# ------------------------------------------------------------
threading.Thread(target=monitor_loop, daemon=True).start()

Gtk.main()
