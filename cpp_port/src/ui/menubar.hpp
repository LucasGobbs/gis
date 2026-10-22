// Native menubar for the Qt port: on macOS a parentless QMenuBar becomes the
// system menu bar (zero height in the window); on Windows the same builder is
// re-parented in phase 2. Mirrors the Odin build's menu surface: File, Scene,
// Edit, Help.
#pragma once

#include "shell.hpp"

namespace shell {

// Builds the app's native menus, wired to the Shell's signals/slots. Call
// once from host_main before shell.show(). Owns its actions for the app's
// lifetime (Qt parents them to the menubar singleton).
void build_native_menus(Shell& shell);

} // namespace shell
