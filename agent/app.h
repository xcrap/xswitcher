#ifndef XS_APP_H
#define XS_APP_H

#include <stdbool.h>
#include <stddef.h>

// The agent is XSwitcher.app's main program, so macOS sees one app: one
// Accessibility entry, one login item. This file is the "app" part: Apple
// events from Finder/Spotlight, opening the Settings helper, login item.

typedef struct {
    void (*open_settings)(void); // the user opened XSwitcher (or opened it again)
    void (*quit)(void);          // logout, or Quit from outside
} AppCallbacks;

// Starts delivering Carbon and Apple events on the main run loop. Idempotent.
void events_start(void);

// Installs the open / reopen / quit handlers and starts the event pump.
// skip_first_open: launched by the Settings helper, so don't open it again.
void app_init(const AppCallbacks *cb, bool skip_first_open);

// Path of the enclosing XSwitcher.app, if running from inside one.
bool app_bundle_path(char *out, size_t len);

// Opens "XSwitcher Settings.app" (Contents/Helpers). menubar: icon only.
void app_open_settings(bool menubar);

// Shows macOS's Accessibility prompt for XSwitcher, adding it to the list.
void app_request_access(void);

// "Open at login" through SMAppService.mainApp, loaded only when called.
// arg: "on", "off" or "status". Prints on / off / needs-approval.
int app_login_cli(const char *arg);

#endif
