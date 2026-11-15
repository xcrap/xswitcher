// xswitcher-agent: the background half of XSwitcher.
// No AppKit, no windows: a CFRunLoop that sleeps until a shortcut or swipe.
// The Settings app talks to it through the config file, a status file and
// signals (HUP reload, USR1 pause, USR2 resume, TERM quit).
#include "hotkeys.h"
#include "spaces.h"
#include "swipe.h"

#include <ApplicationServices/ApplicationServices.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <malloc/malloc.h>
#include <pthread/qos.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#ifndef XS_VERSION
#define XS_VERSION "0.2.0"
#endif

extern char **environ;

static bool g_verbose = false;
static bool g_no_prompt = false;
static bool g_launch_menubar = true;
static char g_cfgpath[PATH_MAX];
static char g_supdir[PATH_MAX];
static Config g_cfg;
static bool g_cfg_ok = true;
static bool g_paused = false;
static int g_armed = 0;

// ------------------------------------------------------------- helpers --

static double us_since(uint64_t t0) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1000.0;
}

static void init_paths(void) {
    const char *home = getenv("HOME");
    if (!home) home = "";
    const char *env = getenv("XSWITCHER_CONFIG");
    const char *xdg = getenv("XDG_CONFIG_HOME");
    if (env && *env) strlcpy(g_cfgpath, env, sizeof g_cfgpath);
    else if (xdg && *xdg) snprintf(g_cfgpath, sizeof g_cfgpath, "%s/xswitcher/config", xdg);
    else snprintf(g_cfgpath, sizeof g_cfgpath, "%s/.config/xswitcher/config", home);

    const char *sd = getenv("XSWITCHER_SUPPORT_DIR");
    if (sd && *sd) strlcpy(g_supdir, sd, sizeof g_supdir);
    else snprintf(g_supdir, sizeof g_supdir, "%s/Library/Application Support/XSwitcher", home);
}

static void mkdirs(const char *path) {
    char tmp[PATH_MAX];
    strlcpy(tmp, path, sizeof tmp);
    for (char *p = tmp + 1; *p; p++) {
        if (*p != '/') continue;
        *p = 0;
        mkdir(tmp, 0755);
        *p = '/';
    }
    mkdir(tmp, 0755);
}

static bool load_config(bool quiet) {
    bool found = false;
    Config next;
    bool ok = config_load(g_cfgpath, &next, &found);
    if (!ok) {
        fprintf(stderr, "xswitcher-agent: config has errors, %s\n",
                quiet ? "keeping previous settings" : "using defaults for bad lines");
        if (quiet) return false;
    }
    if (!quiet) fprintf(stderr, "xswitcher-agent: config %s%s\n", g_cfgpath, found ? "" : " (not found, using defaults)");
    g_cfg = next;
    spaces_set_gesture_speed(g_cfg.gesture_speed);
    return ok;
}

static void print_permissions(FILE *out) {
    fprintf(out, "permissions:\n  post events (Accessibility): %s\n  listen to events:            %s\n",
            CGPreflightPostEventAccess() ? "yes" : "NO", CGPreflightListenEventAccess() ? "yes" : "NO");
}

// macOS 27.2+ ignores synthetic swipes when the trackpad's "swipe between
// full-screen apps" gesture is off (upstream issue #114).
static bool trackpad_gesture_on(void) {
    const CFStringRef domains[] = {CFSTR("com.apple.AppleMultitouchTrackpad"),
                                   CFSTR("com.apple.driver.AppleBluetoothMultitouch.trackpad")};
    const CFStringRef keys[] = {CFSTR("TrackpadThreeFingerHorizSwipeGesture"),
                                CFSTR("TrackpadFourFingerHorizSwipeGesture")};
    bool any = false, on = false;
    for (int d = 0; d < 2; d++) {
        CFPreferencesAppSynchronize(domains[d]);
        for (int k = 0; k < 2; k++) {
            CFPropertyListRef v = CFPreferencesCopyAppValue(keys[k], domains[d]);
            if (!v) continue;
            any = true;
            int n = 0;
            if (CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberIntType, &n);
            if (n == 2) on = true;
            CFRelease(v);
        }
    }
    return !any || on;
}

// ---------------------------------------------------------- status file --
// Plain key=value lines the Settings app reads. Rewritten atomically, and
// only when something changed.

static const char *yesno(bool b) { return b ? "yes" : "no"; }

static size_t format_status(char *buf, size_t len) {
    char failed[256];
    hotkeys_failed(failed, sizeof failed);
    return (size_t)snprintf(buf, len,
        "pid=%d\nversion=%s\naccessibility=%s\nhotkeys_backend=%s\nhotkeys_armed=%d\n"
        "hotkeys_failed=%s\nhotkeys_paused=%s\nhotkey_tap=%s\nswipe_override=%s\nswipe_tap=%s\n"
        "trackpad_gesture=%s\nconfig=%s\nconfig_ok=%s\n",
        getpid(), XS_VERSION, yesno(CGPreflightPostEventAccess()),
        g_cfg.backend == BACKEND_TAP ? "tap" : "carbon", g_armed, failed, yesno(g_paused),
        g_cfg.backend == BACKEND_TAP ? yesno(hotkeys_tap_installed()) : "n/a",
        g_cfg.swipe_override ? "on" : "off", g_cfg.swipe_override ? yesno(swipe_enabled()) : "n/a",
        trackpad_gesture_on() ? "on" : "off", g_cfgpath, yesno(g_cfg_ok));
}

static char g_last_status[2048];

static void write_status(void) {
    char buf[2048];
    format_status(buf, sizeof buf);
    if (!strcmp(buf, g_last_status)) return;
    strlcpy(g_last_status, buf, sizeof g_last_status);
    char path[PATH_MAX], tmp[PATH_MAX];
    snprintf(path, sizeof path, "%s/status", g_supdir);
    snprintf(tmp, sizeof tmp, "%s/status.tmp", g_supdir);
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fputs(buf, f);
    fprintf(f, "updated=%ld\n", (long)time(NULL));
    fclose(f);
    rename(tmp, path);
}

static void remove_status(void) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/status", g_supdir);
    unlink(path);
}

// While permission or a tap is still missing, re-check every 2 s so the
// Settings window updates as soon as you grant Accessibility. Once all is
// well the timer stops: an idle agent never wakes up.
static bool g_watching = false;

static bool something_pending(void) {
    return !CGPreflightPostEventAccess() ||
           (!g_paused && g_cfg.backend == BACKEND_TAP && !hotkeys_tap_installed()) ||
           (g_cfg.swipe_override && !swipe_enabled());
}

static void watch_tick(void *ctx) {
    (void)ctx;
    write_status();
    if (!something_pending()) { g_watching = false; return; }
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), NULL, watch_tick);
}

static void watch_start(void) {
    write_status();
    if (g_watching || !something_pending()) return;
    g_watching = true;
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), NULL, watch_tick);
}

// ------------------------------------------------- last-space tracking --

static struct { char display[128]; int cur, last; } g_track = {"", -1, -1};

static void track_observe(const SpaceInfo *i) {
    int cur = (int)spaces_current(i);
    if (strcmp(g_track.display, i->display) != 0) {
        strlcpy(g_track.display, i->display, sizeof g_track.display);
        g_track.cur = cur;
        g_track.last = -1;
    } else if (cur != g_track.cur) {
        g_track.last = g_track.cur;
        g_track.cur = cur;
    }
}

static void track_moved(int target) {
    if (target != g_track.cur) {
        g_track.last = g_track.cur;
        g_track.cur = target;
    }
}

// ------------------------------------------------------------- actions --

static void on_hotkey(const Binding *b) {
    uint64_t t0 = mach_absolute_time();
    SpaceInfo info;
    bool have = spaces_query(&info, true);
    if (have) track_observe(&info);

    unsigned target = 0;
    bool ok = false;
    switch (b->kind) {
    case ACT_LEFT: ok = spaces_go(have ? &info : NULL, DIR_LEFT, &target); break;
    case ACT_RIGHT: ok = spaces_go(have ? &info : NULL, DIR_RIGHT, &target); break;
    case ACT_INDEX: ok = have && spaces_go_to(&info, b->index, &target); break;
    case ACT_LAST:
        ok = have && g_track.last >= 0 && g_track.last != g_track.cur &&
             spaces_go_to(&info, (unsigned)g_track.last, &target);
        break;
    }
    if (ok && have) track_moved((int)target);

    if (g_verbose) {
        double us = us_since(t0);
        if (!ok) fprintf(stderr, "%-7s -> nothing to do (%.0f us)\n", b->name, us);
        else if (have) fprintf(stderr, "%-7s -> space %u/%u, posted in %.0f us\n", b->name, target + 1, info.count, us);
        else fprintf(stderr, "%-7s -> posted blind (no space info), %.0f us\n", b->name, us);
    }
}

static void on_swipe(const SpaceInfo *before, unsigned target) {
    track_observe(before);
    track_moved((int)target);
    if (g_verbose) fprintf(stderr, "swipe   -> space %u/%u\n", target + 1, before->count);
}

// ---------------------------------------------------------- swipe tap --

static bool g_want_swipe = false, g_retry_pending = false;

static void swipe_retry(void *ctx) {
    (void)ctx;
    g_retry_pending = false;
    if (!g_want_swipe || swipe_enabled()) return;
    if (swipe_enable(on_swipe)) {
        fprintf(stderr, "xswitcher-agent: swipe override on\n");
        write_status();
        return;
    }
    g_retry_pending = true;
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), NULL, swipe_retry);
}

static void apply_swipe(bool want) {
    g_want_swipe = want;
    if (!want) {
        if (swipe_enabled()) { swipe_disable(); fprintf(stderr, "xswitcher-agent: swipe override off\n"); }
        return;
    }
    if (swipe_enabled() || g_retry_pending) return;
    if (swipe_enable(on_swipe)) { fprintf(stderr, "xswitcher-agent: swipe override on\n"); return; }
    fprintf(stderr, "xswitcher-agent: swipe override needs Accessibility; retrying every 2 s\n");
    g_retry_pending = true;
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), NULL, swipe_retry);
}

// ----------------------------------------------------- menu bar launch --

// Path of the enclosing XSwitcher.app, if the agent runs from inside one.
static bool bundle_path(char *out, size_t len) {
    char exe[PATH_MAX], real[PATH_MAX];
    uint32_t sz = sizeof exe;
    if (_NSGetExecutablePath(exe, &sz) != 0 || !realpath(exe, real)) return false;
    char *p = strstr(real, ".app/Contents/MacOS/");
    if (!p) return false;
    p[4] = 0;
    strlcpy(out, real, len);
    return true;
}

static void launch_menubar(void) {
    char app[PATH_MAX];
    if (!bundle_path(app, sizeof app)) return;
    char *argv[] = {"/usr/bin/open", "-g", "-a", app, "--args", "--menubar", NULL};
    pid_t pid;
    if (posix_spawn(&pid, "/usr/bin/open", NULL, NULL, argv, environ) == 0)
        fprintf(stderr, "xswitcher-agent: started menu bar icon\n");
}

// ------------------------------------------------------------ commands --

static dispatch_source_t on_signal(int sig, dispatch_block_t handler) {
    signal(sig, SIG_IGN);
    dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)sig, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(s, handler);
    dispatch_resume(s);
    return s;
}

// The Settings window's "Allow" button posts this so the agent itself shows
// up in the Accessibility list. Under launchd it is its own entry there,
// separate from the XSwitcher app.
static void on_request_access(CFNotificationCenterRef c, void *o, CFNotificationName n,
                              const void *obj, CFDictionaryRef info) {
    (void)c; (void)o; (void)n; (void)obj; (void)info;
    if (!CGPreflightPostEventAccess()) CGRequestPostEventAccess();
    watch_start();
}

static bool acquire_lock(void) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/agent.lock", g_supdir);
    int fd = open(path, O_RDWR | O_CREAT, 0644);
    if (fd < 0) return true; // can't lock: run anyway
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) { close(fd); return false; }
    return true; // fd stays open (and locked) for the life of the process
}

static int cmd_run(void) {
    mkdirs(g_supdir);
    if (!acquire_lock()) {
        fprintf(stderr, "xswitcher-agent: already running\n");
        return 0; // exit 0 so launchd does not keep retrying
    }
    // Shortcuts and taps run on this thread; keep it on the fast cores.
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    spaces_init();
    g_cfg_ok = load_config(false);

    if (!CGPreflightPostEventAccess()) {
        fprintf(stderr, "xswitcher-agent: no Accessibility permission yet. Allow XSwitcher in System Settings >\n"
                        "      Privacy & Security > Accessibility.\n");
        if (!g_no_prompt) CGRequestPostEventAccess();
    }

    // Open the WindowServer connection now (~1.7 MB, ~25 ms) so the first
    // shortcut doesn't pay for it.
    uint64_t t0 = mach_absolute_time();
    SpaceInfo warm;
    bool warm_ok = spaces_query(&warm, true);
    if (g_verbose) fprintf(stderr, "xswitcher-agent: warm-up query %s in %.0f us\n", warm_ok ? "ok" : "FAILED", us_since(t0));

    g_armed = hotkeys_register(&g_cfg, on_hotkey, false);
    apply_swipe(g_cfg.swipe_override);

    CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), NULL, on_request_access,
                                    CFSTR("local.xswitcher.requestAccess"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    signal(SIGCHLD, SIG_IGN); // reap /usr/bin/open
    on_signal(SIGHUP, ^{
        bool ok = load_config(true);
        g_cfg_ok = ok;
        if (!ok) { write_status(); return; }
        if (!g_paused) g_armed = hotkeys_register(&g_cfg, on_hotkey, false);
        apply_swipe(g_cfg.swipe_override);
        fprintf(stderr, "xswitcher-agent: reloaded, %d shortcuts\n", g_armed);
        watch_start();
    });
    on_signal(SIGUSR1, ^{ // pause while Settings records a shortcut
        hotkeys_unregister_all();
        g_paused = true;
        g_armed = 0;
        write_status();
    });
    on_signal(SIGUSR2, ^{
        g_paused = false;
        g_armed = hotkeys_register(&g_cfg, on_hotkey, true);
        watch_start();
    });
    dispatch_block_t quit = ^{
        remove_status();
        exit(0); // a clean exit tells launchd not to restart us
    };
    on_signal(SIGTERM, quit);
    on_signal(SIGINT, quit);

    fprintf(stderr, "xswitcher-agent %s: running (pid %d), %d shortcuts, macOS %s gesture path\n", XS_VERSION,
            getpid(), g_armed, spaces_requires_augmentation() ? "27+" : "legacy");
    watch_start();
    if (g_launch_menubar && g_cfg.menubar) launch_menubar();

    // Start-up (mostly the WindowServer connection) leaves freed but dirty
    // malloc pages behind. Hand them back once the loop is idle.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        malloc_zone_pressure_relief(NULL, 0);
    });
    CFRunLoopRun();
    return 0;
}

static int cmd_switch(int argc, char **argv) {
    const char *what = argv[0];
    uint64_t t0 = mach_absolute_time();
    SpaceInfo info;
    bool have = spaces_query(&info, true);
    unsigned target = 0;
    bool ok;
    if (!strcmp(what, "index")) {
        if (argc < 2 || atoi(argv[1]) < 1) { fprintf(stderr, "usage: xswitcher-agent index <n>   (n starts at 1)\n"); return 2; }
        ok = have && spaces_go_to(&info, (unsigned)atoi(argv[1]) - 1, &target);
    } else {
        ok = spaces_go(have ? &info : NULL, !strcmp(what, "right") ? DIR_RIGHT : DIR_LEFT, &target);
    }
    double us = us_since(t0);
    if (!CGPreflightPostEventAccess())
        fprintf(stderr, "xswitcher-agent: warning: no Accessibility permission, the system will drop the events\n");
    if (!ok) { fprintf(stderr, "xswitcher-agent: nothing to do (edge of the space list?)\n"); return 1; }
    if (g_verbose) fprintf(stderr, "xswitcher-agent: -> space %u, posted in %.0f us\n", target + 1, us);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false); // let the events flush before exit
    return 0;
}

static int cmd_info(void) {
    SpaceInfo c, m;
    double best = 1e9;
    for (int i = 0; i < 5; i++) {
        uint64_t t0 = mach_absolute_time();
        spaces_query(&c, true);
        double us = us_since(t0);
        if (us < best) best = us;
    }
    bool hc = spaces_query(&c, true), hm = spaces_query(&m, false);
    printf("xswitcher-agent %s, macOS %s gesture path\n", XS_VERSION, spaces_requires_augmentation() ? "27+" : "legacy");
    if (hc) printf("cursor display:   %s  space %u of %u\n", c.display, c.current + 1, c.count);
    else printf("cursor display:   unavailable\n");
    if (hm) printf("menu-bar display: %s  space %u of %u\n", m.display, m.current + 1, m.count);
    printf("all displays:\n");
    spaces_dump(stdout);
    printf("space query: %.0f us (best of 5)\n", best);
    printf("trackpad swipe-between-spaces gesture: %s\n", trackpad_gesture_on() ? "on" : "OFF");
    print_permissions(stdout);
    return hc ? 0 : 1;
}

static int cmd_check(void) {
    bool found = false;
    bool ok = config_load(g_cfgpath, &g_cfg, &found);
    printf("config: %s%s%s\n", g_cfgpath, found ? "" : " (not found, defaults)", ok ? "" : "  [errors above]");
    config_print(&g_cfg, stdout);
    int want = 0;
    for (int i = 0; i < NBIND; i++) want += g_cfg.binds[i].enabled;
    if (g_cfg.backend == BACKEND_TAP) {
        printf("shortcuts: %d set, taken over at the keyboard level (needs Accessibility: %s)\n", want,
               CGPreflightPostEventAccess() ? "granted" : "NOT granted");
        print_permissions(stdout);
        return ok ? 0 : 1;
    }
    int n = hotkeys_register(&g_cfg, NULL, false);
    hotkeys_unregister_all();
    printf("shortcuts: carbon backend, %d of %d can be registered%s\n", n, want,
           n < want ? " (a running agent holds its own; stop it first to check)" : "");
    print_permissions(stdout);
    return ok && n == want ? 0 : 1;
}

static void usage(FILE *out) {
    fprintf(out,
            "xswitcher-agent %s: background half of XSwitcher\n\n"
            "usage: xswitcher-agent [run] [-v]     run the agent (default)\n"
            "       xswitcher-agent left | right   switch once and exit\n"
            "       xswitcher-agent index <n>      go to desktop n (1-based) and exit\n"
            "       xswitcher-agent info           show displays, desktops, permissions\n"
            "       xswitcher-agent check          validate the config\n\n"
            "  -c file             config file (default: $XSWITCHER_CONFIG or ~/.config/xswitcher/config)\n"
            "  -v                  log every action with its timing\n"
            "  --no-prompt         don't open the Accessibility permission prompt\n"
            "  --no-menubar-launch don't start the menu bar icon (used by the Settings app)\n",
            XS_VERSION);
}

int main(int argc, char **argv) {
    init_paths();
    const char *cmd = "run";
    char *rest[4];
    int nrest = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-v")) g_verbose = true;
        else if (!strcmp(argv[i], "--no-prompt")) g_no_prompt = true;
        else if (!strcmp(argv[i], "--no-menubar-launch")) g_launch_menubar = false;
        else if (!strcmp(argv[i], "-c") && i + 1 < argc) strlcpy(g_cfgpath, argv[++i], sizeof g_cfgpath);
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help") || !strcmp(argv[i], "help")) { usage(stdout); return 0; }
        else if (!strcmp(argv[i], "--version")) { printf("%s\n", XS_VERSION); return 0; }
        else if (nrest < 4) rest[nrest++] = argv[i];
    }
    if (nrest > 0) cmd = rest[0];

    if (!spaces_available()) { fprintf(stderr, "xswitcher-agent: CGS space APIs are missing on this macOS\n"); return 1; }
    if (!strcmp(cmd, "run")) return cmd_run();
    if (!strcmp(cmd, "info")) return cmd_info();
    if (!strcmp(cmd, "check")) return cmd_check();
    if (!strcmp(cmd, "left") || !strcmp(cmd, "right") || !strcmp(cmd, "index")) return cmd_switch(nrest, rest);
    usage(stderr);
    return 2;
}
