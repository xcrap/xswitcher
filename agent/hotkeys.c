// Config parsing + Carbon global hot keys without AppKit or a Carbon app loop.
#include "hotkeys.h"

#include <Carbon/Carbon.h>
#include <ctype.h>
#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <string.h>

// Present in HIToolbox but no longer declared in the SDK headers.
extern OSStatus ReceiveNextEvent(ItemCount n, const EventTypeSpec *list, EventTimeout timeout,
                                 Boolean pull, EventRef *out);
extern EventTargetRef GetEventDispatcherTarget(void);

// ------------------------------------------------------------- key names --

static const struct { const char *name; uint32_t code; } kKeys[] = {
    {"a", kVK_ANSI_A}, {"b", kVK_ANSI_B}, {"c", kVK_ANSI_C}, {"d", kVK_ANSI_D},
    {"e", kVK_ANSI_E}, {"f", kVK_ANSI_F}, {"g", kVK_ANSI_G}, {"h", kVK_ANSI_H},
    {"i", kVK_ANSI_I}, {"j", kVK_ANSI_J}, {"k", kVK_ANSI_K}, {"l", kVK_ANSI_L},
    {"m", kVK_ANSI_M}, {"n", kVK_ANSI_N}, {"o", kVK_ANSI_O}, {"p", kVK_ANSI_P},
    {"q", kVK_ANSI_Q}, {"r", kVK_ANSI_R}, {"s", kVK_ANSI_S}, {"t", kVK_ANSI_T},
    {"u", kVK_ANSI_U}, {"v", kVK_ANSI_V}, {"w", kVK_ANSI_W}, {"x", kVK_ANSI_X},
    {"y", kVK_ANSI_Y}, {"z", kVK_ANSI_Z},
    {"0", kVK_ANSI_0}, {"1", kVK_ANSI_1}, {"2", kVK_ANSI_2}, {"3", kVK_ANSI_3},
    {"4", kVK_ANSI_4}, {"5", kVK_ANSI_5}, {"6", kVK_ANSI_6}, {"7", kVK_ANSI_7},
    {"8", kVK_ANSI_8}, {"9", kVK_ANSI_9},
    {"f1", kVK_F1}, {"f2", kVK_F2}, {"f3", kVK_F3}, {"f4", kVK_F4}, {"f5", kVK_F5},
    {"f6", kVK_F6}, {"f7", kVK_F7}, {"f8", kVK_F8}, {"f9", kVK_F9}, {"f10", kVK_F10},
    {"f11", kVK_F11}, {"f12", kVK_F12}, {"f13", kVK_F13}, {"f14", kVK_F14},
    {"f15", kVK_F15}, {"f16", kVK_F16}, {"f17", kVK_F17}, {"f18", kVK_F18},
    {"f19", kVK_F19}, {"f20", kVK_F20},
    {"left", kVK_LeftArrow}, {"right", kVK_RightArrow}, {"up", kVK_UpArrow}, {"down", kVK_DownArrow},
    {"space", kVK_Space}, {"tab", kVK_Tab}, {"return", kVK_Return}, {"enter", kVK_Return},
    {"escape", kVK_Escape}, {"esc", kVK_Escape}, {"delete", kVK_Delete}, {"backspace", kVK_Delete},
    {"forwarddelete", kVK_ForwardDelete}, {"home", kVK_Home}, {"end", kVK_End},
    {"pageup", kVK_PageUp}, {"pagedown", kVK_PageDown},
    {"minus", kVK_ANSI_Minus}, {"equal", kVK_ANSI_Equal}, {"leftbracket", kVK_ANSI_LeftBracket},
    {"rightbracket", kVK_ANSI_RightBracket}, {"semicolon", kVK_ANSI_Semicolon},
    {"quote", kVK_ANSI_Quote}, {"comma", kVK_ANSI_Comma}, {"period", kVK_ANSI_Period},
    {"slash", kVK_ANSI_Slash}, {"backslash", kVK_ANSI_Backslash}, {"grave", kVK_ANSI_Grave},
    {"keypad0", kVK_ANSI_Keypad0}, {"keypad1", kVK_ANSI_Keypad1}, {"keypad2", kVK_ANSI_Keypad2},
    {"keypad3", kVK_ANSI_Keypad3}, {"keypad4", kVK_ANSI_Keypad4}, {"keypad5", kVK_ANSI_Keypad5},
    {"keypad6", kVK_ANSI_Keypad6}, {"keypad7", kVK_ANSI_Keypad7}, {"keypad8", kVK_ANSI_Keypad8},
    {"keypad9", kVK_ANSI_Keypad9}, {"keypadplus", kVK_ANSI_KeypadPlus},
    {"keypadminus", kVK_ANSI_KeypadMinus}, {"keypadmultiply", kVK_ANSI_KeypadMultiply},
    {"keypaddivide", kVK_ANSI_KeypadDivide}, {"keypadenter", kVK_ANSI_KeypadEnter},
    {"keypaddecimal", kVK_ANSI_KeypadDecimal}, {"keypadequals", kVK_ANSI_KeypadEquals},
    {"keypadclear", kVK_ANSI_KeypadClear},
};
#define NKEYS (sizeof kKeys / sizeof kKeys[0])

static const char *key_name(uint32_t code) {
    for (size_t i = 0; i < NKEYS; i++)
        if (kKeys[i].code == code) return kKeys[i].name;
    return "?";
}

// ---------------------------------------------------------------- config --

// Defaults: the keys macOS itself uses (Ctrl+arrows), taken over so they are
// instant. Everything else starts off and is set in Settings.
void config_defaults(Config *cfg) {
    memset(cfg, 0, sizeof *cfg);
    cfg->gesture_speed = 2000.0;
    cfg->backend = BACKEND_TAP;
    cfg->check_updates = true;
    Binding *b = cfg->binds;
    b[0] = (Binding){"left", ACT_LEFT, 0, kVK_LeftArrow, controlKey, true};
    b[1] = (Binding){"right", ACT_RIGHT, 0, kVK_RightArrow, controlKey, true};
    for (unsigned i = 0; i < 16; i++) {
        b[2 + i] = (Binding){"", ACT_INDEX, i, 0, 0, false};
        snprintf(b[2 + i].name, sizeof b[2 + i].name, "space%u", i + 1);
    }
    b[18] = (Binding){"last", ACT_LAST, 0, 0, 0, false};
}

static char *trim(char *s) {
    while (isspace((unsigned char)*s)) s++;
    char *e = s + strlen(s);
    while (e > s && isspace((unsigned char)e[-1])) *--e = 0;
    return s;
}

static bool parse_combo(char *v, Binding *b, char *err, size_t errlen) {
    for (char *p = v; *p; p++) *p = (char)tolower((unsigned char)*p);
    if (!strcmp(v, "none") || !strcmp(v, "off") || !*v) { b->enabled = false; return true; }

    uint32_t mods = 0;
    char *key = NULL, *save = NULL;
    for (char *tok = strtok_r(v, "+", &save); tok; tok = strtok_r(NULL, "+", &save)) {
        tok = trim(tok);
        if (key) { // previous token was not the last one, so it must be a modifier
            if (!strcmp(key, "ctrl") || !strcmp(key, "control")) mods |= controlKey;
            else if (!strcmp(key, "alt") || !strcmp(key, "opt") || !strcmp(key, "option")) mods |= optionKey;
            else if (!strcmp(key, "cmd") || !strcmp(key, "command")) mods |= cmdKey;
            else if (!strcmp(key, "shift")) mods |= shiftKey;
            else { snprintf(err, errlen, "unknown modifier '%s'", key); return false; }
        }
        key = tok;
    }
    if (!key || !*key) { snprintf(err, errlen, "missing key"); return false; }
    for (size_t i = 0; i < NKEYS; i++) {
        if (!strcmp(kKeys[i].name, key)) {
            b->key = kKeys[i].code;
            b->mods = mods;
            b->enabled = true;
            return true;
        }
    }
    snprintf(err, errlen, "unknown key '%s'", key);
    return false;
}

static bool parse_bool(const char *v, bool *out) {
    if (!strcasecmp(v, "on") || !strcasecmp(v, "true") || !strcasecmp(v, "yes") || !strcmp(v, "1")) { *out = true; return true; }
    if (!strcasecmp(v, "off") || !strcasecmp(v, "false") || !strcasecmp(v, "no") || !strcmp(v, "0")) { *out = false; return true; }
    return false;
}

bool config_load(const char *path, Config *cfg, bool *found) {
    config_defaults(cfg);
    FILE *f = fopen(path, "r");
    *found = f != NULL;
    if (!f) return true;

    char line[256];
    int lineno = 0;
    bool ok = true;
    while (fgets(line, sizeof line, f)) {
        lineno++;
        char *hash = strchr(line, '#');
        if (hash) *hash = 0;
        char *s = trim(line);
        if (!*s) continue;
        char *eq = strchr(s, '=');
        if (!eq) { fprintf(stderr, "%s:%d: expected 'name = value'\n", path, lineno); ok = false; continue; }
        *eq = 0;
        char *name = trim(s), *val = trim(eq + 1);
        char err[96] = "";

        if (!strcmp(name, "hotkeys")) {
            if (!strcasecmp(val, "carbon")) cfg->backend = BACKEND_CARBON;
            else if (!strcasecmp(val, "tap")) cfg->backend = BACKEND_TAP;
            else { fprintf(stderr, "%s:%d: hotkeys must be carbon or tap\n", path, lineno); ok = false; }
            continue;
        }
        bool *flag = !strcmp(name, "swipe_override") ? &cfg->swipe_override
                   : !strcmp(name, "menubar")        ? &cfg->menubar
                   : !strcmp(name, "check_updates")  ? &cfg->check_updates : NULL;
        if (flag) {
            if (!parse_bool(val, flag)) { fprintf(stderr, "%s:%d: %s must be on/off\n", path, lineno, name); ok = false; }
            continue;
        }
        if (!strcmp(name, "gesture_speed")) {
            double sp = atof(val);
            if (sp <= 0) { fprintf(stderr, "%s:%d: gesture_speed must be > 0\n", path, lineno); ok = false; }
            else cfg->gesture_speed = sp;
            continue;
        }
        Binding *b = NULL;
        for (int i = 0; i < NBIND; i++)
            if (!strcmp(cfg->binds[i].name, name)) b = &cfg->binds[i];
        if (!b) { fprintf(stderr, "%s:%d: unknown setting '%s'\n", path, lineno, name); ok = false; continue; }
        if (!parse_combo(val, b, err, sizeof err)) { fprintf(stderr, "%s:%d: %s: %s\n", path, lineno, name, err); ok = false; }
    }
    fclose(f);
    return ok;
}

void binding_format(const Binding *b, char *buf, size_t len) {
    if (!b->enabled) { snprintf(buf, len, "none"); return; }
    snprintf(buf, len, "%s%s%s%s%s",
             (b->mods & controlKey) ? "ctrl+" : "", (b->mods & optionKey) ? "alt+" : "",
             (b->mods & cmdKey) ? "cmd+" : "", (b->mods & shiftKey) ? "shift+" : "",
             key_name(b->key));
}

void config_print(const Config *cfg, FILE *out) {
    char buf[64];
    for (int i = 0; i < NBIND; i++) {
        binding_format(&cfg->binds[i], buf, sizeof buf);
        fprintf(out, "  %-8s = %s\n", cfg->binds[i].name, buf);
    }
    fprintf(out, "  hotkeys        = %s\n  swipe_override = %s\n  menubar        = %s\n"
                 "  check_updates  = %s\n  gesture_speed  = %g\n",
            cfg->backend == BACKEND_TAP ? "tap" : "carbon", cfg->swipe_override ? "on" : "off",
            cfg->menubar ? "on" : "off", cfg->check_updates ? "on" : "off", cfg->gesture_speed);
}

// --------------------------------------------------------------- hotkeys --

static const OSType kSig = 'xswt';
static EventHotKeyRef g_refs[NBIND];
static Binding g_active[NBIND];
static hotkey_fn g_fn = NULL;

static OSStatus on_hotkey(EventHandlerCallRef next, EventRef ev, void *ud) {
    (void)next; (void)ud;
    EventHotKeyID id;
    if (GetEventParameter(ev, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof id, NULL, &id) != noErr)
        return eventNotHandledErr;
    if (id.signature != kSig || id.id >= NBIND || !g_fn) return eventNotHandledErr;
    g_fn(&g_active[id.id]);
    return noErr;
}

// Pull Carbon events off the WindowServer port whenever the run loop wakes.
// This is what RunApplicationEventLoop does, minus its standard handlers
// (measured ~1.7 MB heavier). No polling: we only run after a wakeup.
static void pump(CFRunLoopObserverRef o, CFRunLoopActivity a, void *info) {
    (void)o; (void)a; (void)info;
    EventRef ev;
    EventTargetRef target = GetEventDispatcherTarget();
    while (ReceiveNextEvent(0, NULL, kEventDurationNoWait, true, &ev) == noErr) {
        SendEventToEventTarget(ev, target);
        ReleaseEvent(ev);
    }
}

static void install_once(void) {
    static bool done = false;
    if (done) return;
    done = true;
    EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallApplicationEventHandler(NewEventHandlerUPP(on_hotkey), 1, &spec, NULL, NULL);
    // A first ReceiveNextEvent attaches HIToolbox's event port to the main run loop.
    EventRef ev;
    ReceiveNextEvent(0, NULL, kEventDurationNoWait, false, &ev);
    CFRunLoopObserverRef obs = CFRunLoopObserverCreate(
        NULL, kCFRunLoopAfterWaiting | kCFRunLoopBeforeWaiting, true, 0, pump, NULL);
    CFRunLoopAddObserver(CFRunLoopGetMain(), obs, kCFRunLoopCommonModes);
    CFRelease(obs);
}

// ------------------------------------------------------- tap backend ----
// One active keyDown tap. A 128-bit bitmap of bound key codes rejects normal
// typing with a single AND before anything else is read from the event.

static CFMachPortRef g_ktap = NULL;
static CFRunLoopSourceRef g_ksrc = NULL;
static uint64_t g_keybits[2];
static bool g_tap_wanted = false, g_tap_retry = false;

static uint32_t carbon_mods(CGEventFlags f) {
    uint32_t m = 0;
    if (f & kCGEventFlagMaskControl) m |= controlKey;
    if (f & kCGEventFlagMaskAlternate) m |= optionKey;
    if (f & kCGEventFlagMaskCommand) m |= cmdKey;
    if (f & kCGEventFlagMaskShift) m |= shiftKey;
    return m;
}

static void run_binding(void *ctx) {
    int i = (int)(intptr_t)ctx;
    if (g_fn && i >= 0 && i < NBIND) g_fn(&g_active[i]);
}

static CGEventRef key_cb(CGEventTapProxy proxy, CGEventType type, CGEventRef ev, void *ref) {
    (void)proxy; (void)ref;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (g_ktap) CGEventTapEnable(g_ktap, true);
        return ev;
    }
    if (type != kCGEventKeyDown) return ev;
    int64_t kc = CGEventGetIntegerValueField(ev, kCGKeyboardEventKeycode);
    if (kc < 0 || kc >= 128 || !(g_keybits[kc >> 6] & (1ULL << (kc & 63)))) return ev;
    uint32_t m = carbon_mods(CGEventGetFlags(ev));
    for (int i = 0; i < NBIND; i++) {
        const Binding *b = &g_active[i];
        if (b->enabled && b->key == (uint32_t)kc && b->mods == m) {
            // Release the event pipeline first, switch right after.
            dispatch_async_f(dispatch_get_main_queue(), (void *)(intptr_t)i, run_binding);
            return NULL;
        }
    }
    return ev;
}

static bool key_tap_install(void) {
    if (g_ktap) return true;
    // HID level: before WindowServer matches macOS's own shortcuts, so swallowing
    // Ctrl+arrow here stops the animated Mission Control switch.
    g_ktap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                              CGEventMaskBit(kCGEventKeyDown), key_cb, NULL);
    if (!g_ktap) return false;
    g_ksrc = CFMachPortCreateRunLoopSource(NULL, g_ktap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), g_ksrc, kCFRunLoopCommonModes);
    CGEventTapEnable(g_ktap, true);
    return true;
}

static void key_tap_remove(void) {
    if (!g_ktap) return;
    CGEventTapEnable(g_ktap, false);
    CFRunLoopRemoveSource(CFRunLoopGetMain(), g_ksrc, kCFRunLoopCommonModes);
    CFRelease(g_ksrc);
    CFMachPortInvalidate(g_ktap);
    CFRelease(g_ktap);
    g_ktap = NULL;
    g_ksrc = NULL;
}

static void key_tap_retry(void *ctx) {
    (void)ctx;
    g_tap_retry = false;
    if (!g_tap_wanted || g_ktap) return;
    if (key_tap_install()) { fprintf(stderr, "xswitcher-agent: hotkey tap installed\n"); return; }
    g_tap_retry = true;
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), NULL, key_tap_retry);
}

bool hotkeys_tap_installed(void) { return g_ktap != NULL; }

static uint32_t g_failed_mask = 0;

void hotkeys_failed(char *buf, size_t len) {
    buf[0] = 0;
    for (int i = 0; i < NBIND; i++) {
        if (!(g_failed_mask & (1u << i))) continue;
        if (buf[0]) strlcat(buf, ",", len);
        strlcat(buf, g_active[i].name, len);
    }
}

// ------------------------------------------------------------- register --

void hotkeys_unregister_all(void) {
    for (int i = 0; i < NBIND; i++) {
        if (g_refs[i]) UnregisterEventHotKey(g_refs[i]);
        g_refs[i] = NULL;
    }
    g_tap_wanted = false;
    key_tap_remove();
}

int hotkeys_register(const Config *cfg, hotkey_fn fn, bool quiet) {
    hotkeys_unregister_all();
    g_fn = fn;
    g_failed_mask = 0;
    memcpy(g_active, cfg->binds, sizeof g_active);
    int n = 0;

    if (cfg->backend == BACKEND_TAP) {
        memset(g_keybits, 0, sizeof g_keybits);
        for (int i = 0; i < NBIND; i++) {
            if (!g_active[i].enabled || g_active[i].key >= 128) continue;
            g_keybits[g_active[i].key >> 6] |= 1ULL << (g_active[i].key & 63);
            n++;
        }
        g_tap_wanted = true;
        if (key_tap_install()) return n;
        if (!fn) return 0; // dry run: report, don't retry
        if (!quiet) fprintf(stderr, "xswitcher-agent: hotkey tap needs Accessibility; retrying every 2 s\n");
        if (!g_tap_retry) {
            g_tap_retry = true;
            dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), NULL, key_tap_retry);
        }
        return n;
    }

    install_once();
    for (int i = 0; i < NBIND; i++) {
        const Binding *b = &g_active[i];
        if (!b->enabled) continue;
        EventHotKeyID id = {kSig, (UInt32)i};
        OSStatus s = RegisterEventHotKey(b->key, b->mods, id, GetApplicationEventTarget(), 0, &g_refs[i]);
        if (s == noErr) { n++; continue; }
        g_refs[i] = NULL;
        g_failed_mask |= 1u << i;
        if (!quiet) {
            char buf[64];
            binding_format(b, buf, sizeof buf);
            fprintf(stderr, "xswitcher-agent: could not register %s (%s): %s\n", b->name, buf,
                    s == eventHotKeyExistsErr ? "already taken by another app" : "error");
        }
    }
    return n;
}
