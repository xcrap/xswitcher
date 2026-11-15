#include "app.h"

#include <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern char **environ;

// Present in HIToolbox but no longer declared in the SDK headers.
extern OSStatus ReceiveNextEvent(ItemCount n, const EventTypeSpec *list, EventTimeout timeout,
                                 Boolean pull, EventRef *out);
extern EventTargetRef GetEventDispatcherTarget(void);
extern OSStatus AEProcessEvent(EventRef event);
extern void *objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void *pool);

// ------------------------------------------------------------ event pump --

// Pull Carbon events off the WindowServer port whenever the run loop wakes.
// This is what RunApplicationEventLoop does, minus its standard handlers.
// No polling: it only runs after something woke the loop.
static void pump(CFRunLoopObserverRef o, CFRunLoopActivity a, void *info) {
    (void)o; (void)a; (void)info;
    EventRef ev;
    while (ReceiveNextEvent(0, NULL, kEventDurationNoWait, true, &ev) == noErr) {
        if (GetEventClass(ev) == kEventClassAppleEvent) AEProcessEvent(ev);
        else SendEventToEventTarget(ev, GetEventDispatcherTarget());
        ReleaseEvent(ev);
    }
}

void events_start(void) {
    static bool done = false;
    if (done) return;
    done = true;
    // A first ReceiveNextEvent checks in with the WindowServer and attaches
    // HIToolbox's event port to the main run loop.
    EventRef ev;
    ReceiveNextEvent(0, NULL, kEventDurationNoWait, false, &ev);
    CFRunLoopObserverRef obs = CFRunLoopObserverCreate(
        NULL, kCFRunLoopAfterWaiting | kCFRunLoopBeforeWaiting, true, 0, pump, NULL);
    CFRunLoopAddObserver(CFRunLoopGetMain(), obs, kCFRunLoopCommonModes);
    CFRelease(obs);
}

// ------------------------------------------------------------ Apple events --

static AppCallbacks g_cb;
static bool g_skip_first_open = false;

static OSErr on_open(const AppleEvent *e, AppleEvent *reply, SRefCon ref) {
    (void)reply; (void)ref;
    DescType type;
    Size size;
    OSType value = 0;
    bool at_login = AEGetParamPtr(e, keyAEPropData, typeType, &type, &value, sizeof value, &size) == noErr &&
                    value == keyAELaunchedAsLogInItem;
    if (!at_login && !g_skip_first_open && g_cb.open_settings) g_cb.open_settings();
    return noErr;
}

static OSErr on_reopen(const AppleEvent *e, AppleEvent *reply, SRefCon ref) {
    (void)e; (void)reply; (void)ref;
    if (g_cb.open_settings) g_cb.open_settings();
    return noErr;
}

static OSErr on_quit(const AppleEvent *e, AppleEvent *reply, SRefCon ref) {
    (void)e; (void)reply; (void)ref;
    if (g_cb.quit) g_cb.quit();
    return noErr;
}

void app_init(const AppCallbacks *cb, bool skip_first_open) {
    g_cb = *cb;
    g_skip_first_open = skip_first_open;
    AEInstallEventHandler(kCoreEventClass, kAEOpenApplication, NewAEEventHandlerUPP(on_open), 0, false);
    AEInstallEventHandler(kCoreEventClass, kAEReopenApplication, NewAEEventHandlerUPP(on_reopen), 0, false);
    AEInstallEventHandler(kCoreEventClass, kAEQuitApplication, NewAEEventHandlerUPP(on_quit), 0, false);
    events_start();
}

// ------------------------------------------------------------- settings --

bool app_bundle_path(char *out, size_t len) {
    char exe[PATH_MAX], real[PATH_MAX];
    uint32_t sz = sizeof exe;
    if (_NSGetExecutablePath(exe, &sz) != 0 || !realpath(exe, real)) return false;
    char *p = strstr(real, ".app/Contents/MacOS/");
    if (!p) return false;
    p[4] = 0;
    strlcpy(out, real, len);
    return true;
}

void app_open_settings(bool menubar) {
    char app[PATH_MAX], helper[PATH_MAX];
    if (!app_bundle_path(app, sizeof app)) return;
    snprintf(helper, sizeof helper, "%s/Contents/Helpers/XSwitcher Settings.app", app);
    char *window[] = {"/usr/bin/open", "-a", helper, NULL};
    char *icon[] = {"/usr/bin/open", "-g", "-a", helper, "--args", "--menubar", NULL};
    pid_t pid;
    posix_spawn(&pid, "/usr/bin/open", NULL, NULL, menubar ? icon : window, environ);
}

void app_request_access(void) {
    const void *keys[] = {kAXTrustedCheckOptionPrompt};
    const void *vals[] = {kCFBooleanTrue};
    CFDictionaryRef opts = CFDictionaryCreate(NULL, keys, vals, 1, &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
    AXIsProcessTrustedWithOptions(opts);
    CFRelease(opts);
}

// ------------------------------------------------------------ login item --

static id sm_main_app(void) {
    if (!dlopen("/System/Library/Frameworks/ServiceManagement.framework/ServiceManagement", RTLD_LAZY)) return NULL;
    Class cls = objc_getClass("SMAppService");
    if (!cls) return NULL;
    return ((id (*)(Class, SEL))objc_msgSend)(cls, sel_registerName("mainAppService"));
}

static const char *status_name(long s) {
    switch (s) {
    case 0: return "off";
    case 1: return "on";
    case 2: return "needs-approval";
    default: return "off"; // not found
    }
}

int app_login_cli(const char *arg) {
    void *pool = objc_autoreleasePoolPush();
    int rc = 0;
    id svc = sm_main_app();
    if (!svc) {
        puts("unavailable");
        objc_autoreleasePoolPop(pool);
        return 1;
    }
    bool on = !strcmp(arg, "on"), off = !strcmp(arg, "off");
    if (on || off) {
        id err = NULL;
        SEL sel = sel_registerName(on ? "registerAndReturnError:" : "unregisterAndReturnError:");
        if (!((BOOL (*)(id, SEL, id *))objc_msgSend)(svc, sel, &err) && err) {
            CFStringRef d = (CFStringRef)((id (*)(id, SEL))objc_msgSend)(err, sel_registerName("localizedDescription"));
            char buf[512] = "";
            if (d) CFStringGetCString(d, buf, sizeof buf, kCFStringEncodingUTF8);
            fprintf(stderr, "login item: %s\n", buf);
        }
    }
    long st = ((long (*)(id, SEL))objc_msgSend)(svc, sel_registerName("status"));
    const char *name = status_name(st);
    puts(name);
    if (on && !strcmp(name, "off")) rc = 1;
    if (off && strcmp(name, "off")) rc = 1;
    objc_autoreleasePoolPop(pool);
    return rc;
}
