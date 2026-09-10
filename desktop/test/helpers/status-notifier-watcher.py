#!/usr/bin/env python3
"""Minimal StatusNotifierWatcher used by the Linux tray integration test."""

import os
import pathlib

import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib


INTERFACE = "org.kde.StatusNotifierWatcher"
OBJECT_PATH = "/StatusNotifierWatcher"


class StatusNotifierWatcher(dbus.service.Object):
    def __init__(self, bus, marker):
        self.marker = marker
        super().__init__(bus, OBJECT_PATH)

    @dbus.service.method(INTERFACE, in_signature="s", out_signature="")
    def RegisterStatusNotifierItem(self, service):
        self.marker.write_text(str(service), encoding="utf-8")

    @dbus.service.method(INTERFACE, in_signature="s", out_signature="")
    def RegisterStatusNotifierHost(self, _service):
        return

    @dbus.service.method(
        "org.freedesktop.DBus.Properties",
        in_signature="ss",
        out_signature="v",
    )
    def Get(self, interface, prop):
        if interface != INTERFACE:
            raise dbus.exceptions.DBusException(
                "unknown interface", name="org.freedesktop.DBus.Error.UnknownInterface"
            )
        values = {
            "RegisteredStatusNotifierItems": dbus.Array([], signature="s"),
            "IsStatusNotifierHostRegistered": dbus.Boolean(True),
            "ProtocolVersion": dbus.Int32(0),
        }
        if prop not in values:
            raise dbus.exceptions.DBusException(
                "unknown property", name="org.freedesktop.DBus.Error.UnknownProperty"
            )
        return values[prop]

    @dbus.service.method(
        "org.freedesktop.DBus.Properties", in_signature="s", out_signature="a{sv}"
    )
    def GetAll(self, interface):
        if interface != INTERFACE:
            return {}
        return {
            "RegisteredStatusNotifierItems": dbus.Array([], signature="s"),
            "IsStatusNotifierHostRegistered": dbus.Boolean(True),
            "ProtocolVersion": dbus.Int32(0),
        }


def main():
    marker = pathlib.Path(os.environ["CODESTATUS_TRAY_MARKER"])
    ready = pathlib.Path(os.environ["CODESTATUS_TRAY_READY"])
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    name = dbus.service.BusName(INTERFACE, bus=bus, do_not_queue=True)
    watcher = StatusNotifierWatcher(bus, marker)
    ready.touch()
    GLib.MainLoop().run()
    # Keep these alive for the lifetime of the loop.
    _ = (name, watcher)


if __name__ == "__main__":
    main()
