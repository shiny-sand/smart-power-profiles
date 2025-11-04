#!/usr/bin/env python3
# Smart Power Profiles Tray — text-only label that tracks the daemon's state.
# Prefers ~/.cache/powerprofile.state (written by auto-powerprofile.sh) and
# falls back to `powerprofilesctl get` if that file is missing.

import os
import sys
import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib

# --- Prefer Ayatana first (Ubuntu 25.10+), then fall back to legacy AppIndicator3 ---
IndicatorNS = None
try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as IndicatorNS
except Exception:
    try:
        gi.require_version("AppIndicator3", "0.1")
        from gi.repository import AppIndicator3 as IndicatorNS
    except Exception:
        sys.stderr.write(
            "No compatible AppIndicator binding found.\n"
            "Install: gir1.2-ayatanaappindicator3-0.1 libayatana-appindicator3-1 python3-gi gir1.2-gtk-3.0\n"
            "Also verify the typelib exists:\n"
            "  /usr/lib/x86_64-linux-gnu/girepository-1.0/AyatanaAppIndicator3-0.1.typelib\n"
        )
        sys.exit(1)

APP_ID     = "smart-power-profiles"
CACHE_DIR  = os.path.expanduser("~/.cache")
STATE_FILE = os.path.join(CACHE_DIR, "powerprofile.state")   # written by daemon
LAST_FILE  = os.path.join(CACHE_DIR, "powerprofile.last")    # last profile applied (also written by daemon)
OVERRIDE   = os.path.join(CACHE_DIR, "powerprofile.override")
SILENT     = os.path.join(CACHE_DIR, "powerprofile.silent")

PROFILE_NAMES = {
    "power-saver": "Power Saver",
    "balanced": "Balanced",
    "performance": "Performance",
}

def sh(cmd: str) -> str:
    from subprocess import run, PIPE, DEVNULL
    out = run(cmd, shell=True, stdout=PIPE, stderr=DEVNULL, text=True)
    return (out.stdout or "").strip()

def read_cached_profile() -> str | None:
    # Prefer STATE_FILE; fall back to LAST_FILE; else None
    for path in (STATE_FILE, LAST_FILE):
        try:
            if os.path.exists(path):
                with open(path, "r", encoding="utf-8") as f:
                    val = f.read().strip()
                if val:
                    return val
        except Exception:
            pass
    return None

def read_live_profile() -> str:
    return sh("powerprofilesctl get") or "balanced"

def get_profile() -> str:
    cached = read_cached_profile()
    return cached if cached else read_live_profile()

def is_auto() -> bool:
    return not os.path.exists(OVERRIDE)

def notifications_enabled() -> bool:
    return not os.path.exists(SILENT)

def set_state(mode: str):
    # Write override file (manual), or remove it (auto).
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        if mode == "auto":
            if os.path.exists(OVERRIDE):
                os.remove(OVERRIDE)
        else:
            with open(OVERRIDE, "w", encoding="utf-8") as f:
                f.write(mode)
        # Ask power-profiles-daemon too; daemon will enforce if it refuses.
        if mode != "auto":
            from subprocess import run, DEVNULL
            run(["powerprofilesctl", "set", mode], stdout=DEVNULL, stderr=DEVNULL)
    except Exception:
        pass

def toggle_notifications(enable: bool):
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        if enable:
            if os.path.exists(SILENT):
                os.remove(SILENT)
        else:
            with open(SILENT, "w", encoding="utf-8") as f:
                f.write("1")
    except Exception:
        pass

def label_for(profile: str, auto: bool) -> str:
    prefix = "A" if auto else "M"
    return f"{prefix}: {PROFILE_NAMES.get(profile, profile.title())}"

class Tray:
    def __init__(self):
        # Stable symbolic icon so GNOME doesn’t render an ellipsis.
        icon_name = "preferences-system-symbolic"

        # Build indicator
        self.ind = IndicatorNS.Indicator.new(
            APP_ID,
            icon_name,
            IndicatorNS.IndicatorCategory.APPLICATION_STATUS
        )
        self.ind.set_status(IndicatorNS.IndicatorStatus.ACTIVE)

        self._last_snapshot = None
        self._menu_items = {}  # map profile -> Gtk.CheckMenuItem for checks

        # Build UI and prime label
        self.build_menu(initial=True)
        self._apply_label(get_profile(), is_auto())

        # Poll with GLib timer (keeps all GTK on the main thread)
        GLib.timeout_add_seconds(1, self._tick)

    def _apply_label(self, profile: str, auto: bool):
        text = label_for(profile, auto)
        if hasattr(self.ind, "set_label"):
            # Some builds lack set_label; guard it
            try:
                self.ind.set_label(text, "")
            except Exception:
                pass
        if hasattr(self.ind, "set_title"):
            try:
                self.ind.set_title(text)
            except Exception:
                pass

    def build_menu(self, initial=False):
        menu = Gtk.Menu()
        prof = get_profile()
        auto = is_auto()
        notify = notifications_enabled()

        # Auto toggle
        it_auto = Gtk.CheckMenuItem(label="Auto Mode")
        it_auto.set_active(auto)
        it_auto.connect("activate", self._on_auto)
        menu.append(it_auto)

        menu.append(Gtk.SeparatorMenuItem())

        # Manual picks (check the active one only when in Manual)
        self._menu_items.clear()
        for title, mode in [
            ("Power Saver", "power-saver"),
            ("Balanced", "balanced"),
            ("Performance", "performance"),
        ]:
            mi = Gtk.CheckMenuItem(label=title)
            mi.set_active((prof == mode) and (not auto))
            mi.connect("activate", self._on_pick, mode)
            self._menu_items[mode] = mi
            menu.append(mi)

        menu.append(Gtk.SeparatorMenuItem())

        # Notifications toggle
        it_notif = Gtk.CheckMenuItem(label="Notifications")
        it_notif.set_active(notify)
        it_notif.connect("activate", self._on_notify)
        menu.append(it_notif)

        menu.append(Gtk.SeparatorMenuItem())
        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", lambda _w: Gtk.main_quit())
        menu.append(quit_item)

        menu.show_all()
        self.ind.set_menu(menu)

        # Update label on build
        self._apply_label(prof, auto)

    # Callbacks
    def _on_auto(self, w):
        set_state("auto" if w.get_active() else "balanced")
        self.build_menu()

    def _on_pick(self, w, mode):
        # Only act on "check" events that are turning on
        if not w.get_active():
            return
        set_state(mode)
        # Reflect single-selection behavior among manual picks
        for m, item in self._menu_items.items():
            if m != mode:
                item.set_active(False)
        self.build_menu()

    def _on_notify(self, w):
        toggle_notifications(w.get_active())
        self.build_menu()

    # Periodic tick (returns True to keep the timer)
    def _tick(self):
        prof = get_profile()
        auto = is_auto()
        notify = notifications_enabled()
        snap = (prof, auto, notify)
        if snap != self._last_snapshot:
            self._apply_label(prof, auto)
            self.build_menu()
            self._last_snapshot = snap
        return True

def main():
    try:
        Gtk.set_prgname(APP_ID)
    except Exception:
        pass
    Tray()
    Gtk.main()

if __name__ == "__main__":
    main()
