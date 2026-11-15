#ifndef XS_HOTKEYS_H
#define XS_HOTKEYS_H

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

typedef enum { ACT_LEFT, ACT_RIGHT, ACT_INDEX, ACT_LAST } ActKind;

typedef struct {
    char name[12];   // "left", "space3", ...
    ActKind kind;
    unsigned index;  // zero-based, for ACT_INDEX
    uint32_t key;    // kVK_* virtual key code
    uint32_t mods;   // Carbon modifier mask (cmdKey | optionKey | ...)
    bool enabled;
} Binding;

#define NBIND 19 // left, right, space1..16, last

typedef enum {
    BACKEND_TAP,    // HID-level keyDown tap: sees keys before macOS's own shortcuts, so it
                    // can take over Ctrl+arrows. Unbound keys are rejected by one bit test.
    BACKEND_CARBON, // WindowServer matches the combo; never sees normal typing, but macOS's
                    // own shortcuts win over it.
} Backend;

typedef struct {
    Binding binds[NBIND];
    Backend backend;
    bool swipe_override;
    bool menubar;        // read by the agent only to start the menu bar app at login
    bool check_updates;  // read by the app only
    double gesture_speed;
} Config;

void config_defaults(Config *cfg);
// Returns false on a parse error (message printed). *found=false if no file.
bool config_load(const char *path, Config *cfg, bool *found);
void config_print(const Config *cfg, FILE *out);
void binding_format(const Binding *b, char *buf, size_t len);

typedef void (*hotkey_fn)(const Binding *b);

// Arms every enabled binding with the configured backend. Returns how many
// are armed; failures are printed. With fn == NULL (dry run) the tap backend
// does not schedule retries.
int hotkeys_register(const Config *cfg, hotkey_fn fn, bool quiet);
void hotkeys_unregister_all(void);
bool hotkeys_tap_installed(void);
// Comma-separated names of bindings the last register call could not arm.
void hotkeys_failed(char *buf, size_t len);

#endif
