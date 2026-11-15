// Optional trackpad override: turns a native horizontal Dock swipe into an
// instant switch. Logic ported from InstantSpaceSwitcher (MIT, (c) 2026 jurplel).
//
// Differences from the original:
//  * the tap only exists while the override is on, and only asks for gesture
//    events (29/30), never keyboard events;
//  * no Exposé check (a full window-list copy) inside the callback.
#include "swipe.h"
#include "cgs.h"
#include "spaces.h"

static CFMachPortRef g_tap = NULL;
static CFRunLoopSourceRef g_src = NULL;
static bool g_tracking = false, g_fired = false;
static swipe_switched_fn g_cb = NULL;

static void fire(Dir d) {
    SpaceInfo info;
    unsigned target = 0;
    if (!spaces_query(&info, true)) {
        spaces_go(NULL, d, NULL);
        return;
    }
    if (spaces_go(&info, d, &target) && g_cb) g_cb(&info, target);
}

static CGEventRef tap_cb(CGEventTapProxy proxy, CGEventType type, CGEventRef ev, void *ref) {
    (void)proxy; (void)ref;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (g_tap) CGEventTapEnable(g_tap, true);
        spaces_synthetic_clear(); // anything posted while disabled never reached us
        return ev;
    }

    uint32_t t = (uint32_t)CGEventGetIntegerValueField(ev, F_CGS_TYPE);
    if (t != CGS_EVENT_DOCK_CONTROL && t != CGS_EVENT_GESTURE) return ev;

    // macOS 27 re-delivers our own swipes with sourcePid == 0, so count them out.
    if (spaces_synthetic_consume()) return ev;
    // Real trackpad gestures come from the HID kernel (pid 0).
    if ((pid_t)CGEventGetIntegerValueField(ev, kCGEventSourceUnixProcessID) != 0) return ev;

    if (t == CGS_EVENT_GESTURE) return g_tracking ? NULL : ev;

    if ((uint32_t)CGEventGetIntegerValueField(ev, F_HID_TYPE) != HID_EVENT_DOCK_SWIPE) return ev;
    if ((uint16_t)CGEventGetIntegerValueField(ev, F_SWIPE_MOTION) != MOTION_HORIZONTAL) return ev;

    switch ((int)CGEventGetIntegerValueField(ev, F_PHASE)) {
    case PHASE_BEGAN:
        g_tracking = true;
        g_fired = false;
        return NULL;

    case PHASE_CHANGED:
        if (!g_tracking) return ev;
        if (!g_fired) {
            double p = CGEventGetDoubleValueField(ev, F_SWIPE_PROGRESS);
            if (p != 0.0) {
                g_fired = true;
                fire(p > 0.0 ? DIR_RIGHT : DIR_LEFT);
            }
        }
        return NULL;

    case PHASE_ENDED:
        if (!g_tracking) return ev;
        if (!g_fired) {
            double v = CGEventGetDoubleValueField(ev, F_SWIPE_VEL_X);
            if (v != 0.0) {
                g_fired = true;
                fire(v > 0.0 ? DIR_RIGHT : DIR_LEFT);
            }
        }
        g_tracking = g_fired = false;
        if (spaces_requires_augmentation()) {
            // macOS 27's Dock needs the real Ended event to close its gesture
            // state; zero the motion so it doesn't switch a second time.
            CGEventSetDoubleValueField(ev, F_SWIPE_PROGRESS, 0.0);
            CGEventSetDoubleValueField(ev, F_SWIPE_VEL_X, 0.0);
            CGEventSetDoubleValueField(ev, F_SWIPE_VEL_Y, 0.0);
            return ev;
        }
        return NULL;

    case PHASE_CANCELLED:
        g_tracking = g_fired = false;
        return NULL;

    default:
        return g_tracking ? NULL : ev;
    }
}

bool swipe_enable(swipe_switched_fn cb) {
    g_cb = cb;
    if (g_tap) return true;
    CGEventMask mask = (1ULL << CGS_EVENT_GESTURE) | (1ULL << CGS_EVENT_DOCK_CONTROL);
    g_tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                             mask, tap_cb, NULL);
    if (!g_tap) return false;
    g_src = CFMachPortCreateRunLoopSource(NULL, g_tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), g_src, kCFRunLoopCommonModes);
    CGEventTapEnable(g_tap, true);
    spaces_set_tap_active(true);
    return true;
}

void swipe_disable(void) {
    if (!g_tap) return;
    spaces_set_tap_active(false);
    CGEventTapEnable(g_tap, false);
    CFRunLoopRemoveSource(CFRunLoopGetMain(), g_src, kCFRunLoopCommonModes);
    CFRelease(g_src);
    CFMachPortInvalidate(g_tap);
    CFRelease(g_tap);
    g_tap = NULL;
    g_src = NULL;
    g_tracking = g_fired = false;
}

bool swipe_enabled(void) { return g_tap != NULL; }
