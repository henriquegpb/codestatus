'use strict';

// Starting with the session.
//
// Electron's app.setLoginItemSettings is macOS and Windows only; on Linux it is
// a no-op that reports back whatever you last set, so the settings toggle would
// appear to work and nothing would happen. There is no API to call because
// Linux has no login-item registry — what it has is a directory, specified by
// the XDG autostart spec and honoured by GNOME, KDE, XFCE, Cinnamon, MATE, LXQt
// and Budgie alike: a .desktop file in ~/.config/autostart is launched when the
// session starts.
//
// So this is a file, written and deleted. The one subtlety is which command to
// put in it, and it is the same question linux/runtime.js answers for the hook:
// a path inside an AppImage mount is gone by the next login, so a .desktop file
// naming one is a broken launcher rather than an autostart entry.

const fs = require('fs');
const path = require('path');

const { paths } = require('./paths');
const { isEphemeral } = require('./runtime');

const FILE_NAME = 'codestatus.desktop';

function desktopFile() {
  return path.join(paths.autostart, FILE_NAME);
}

// $APPIMAGE is set by the AppImage runtime to the path of the .AppImage file
// itself, which — unlike everything inside the mount — is where the user put it
// and is still there at the next login.
function launchCommand() {
  const appImage = process.env.APPIMAGE;
  if (appImage && !isEphemeral(appImage)) return appImage;
  return process.execPath;
}

function isEnabled() {
  try {
    return fs.statSync(desktopFile()).isFile();
  } catch {
    return false;
  }
}

// Entries are written with our own name in the filename, so this only ever
// touches a file we created.
function setEnabled(enabled) {
  const target = desktopFile();

  if (!enabled) {
    try {
      fs.unlinkSync(target);
    } catch { /* already gone is the state we wanted */ }
    return { enabled: false, path: target };
  }

  const command = launchCommand();
  if (isEphemeral(command)) {
    throw new Error(
      'CodeStatus is running from an AppImage mount, whose path changes every '
      + 'time it starts. Move the .AppImage somewhere permanent and open it from '
      + 'there, or install the .deb or .rpm.',
    );
  }

  // X-GNOME-Autostart-enabled is GNOME's, and harmless elsewhere; the two Hidden
  // and NoDisplay keys keep the entry out of application menus, where an
  // autostart file would otherwise show up as a duplicate launcher.
  const contents = [
    '[Desktop Entry]',
    'Type=Application',
    'Name=CodeStatus',
    'Comment=Session monitor for Claude Code',
    // Quoted because the path may contain a space, and Exec is parsed by the
    // desktop-entry rules rather than by a shell.
    `Exec="${command}"`,
    'Icon=codestatus',
    'Terminal=false',
    'NoDisplay=true',
    'X-GNOME-Autostart-enabled=true',
    '',
  ].join('\n');

  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, contents, 'utf8');
  return { enabled: true, path: target };
}

module.exports = { isEnabled, setEnabled, desktopFile, launchCommand, FILE_NAME };
