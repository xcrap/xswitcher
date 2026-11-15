// Space queries and synthetic Dock-swipe switching.
// The gesture technique and the macOS 27 IOHID payload are ported from
// InstantSpaceSwitcher (MIT, (c) 2026 jurplel); see LICENSE.
#include "spaces.h"
#include "cgs.h"

#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

// ---------------------------------------------------------------- state ----

static double g_speed = 2000.0;

// While our own gestures are still animating, CGS reports intermediate
// spaces. Trust our predictions until the Dock has been quiet this long.
static const CFTimeInterval kPredictionTTL = 1.0;
static CFAbsoluteTime g_last_gesture = 0;

// Fixed table instead of a CFDictionary: no allocation per lookup.
#define MAX_DISPLAYS 8
static struct {
    char id[128];
    unsigned index;
    bool used;
} g_pred[MAX_DISPLAYS];

static bool g_tap_active = false;
static unsigned g_synthetic = 0;
static int g_natural = -1; // cached com.apple.swipescrolldirection, -1 = unread

static bool in_flight(void) {
    return CFAbsoluteTimeGetCurrent() - g_last_gesture < kPredictionTTL;
}

static void pred_clear(void) { memset(g_pred, 0, sizeof g_pred); }

static bool pred_get(const char *id, unsigned *out) {
    if (!in_flight()) {
        pred_clear();
        return false;
    }
    for (int i = 0; i < MAX_DISPLAYS; i++) {
        if (g_pred[i].used && strcmp(g_pred[i].id, id) == 0) {
            *out = g_pred[i].index;
            return true;
        }
    }
    return false;
}

static void pred_set(const char *id, unsigned index) {
    int slot = -1;
    for (int i = 0; i < MAX_DISPLAYS; i++) {
        if (g_pred[i].used && strcmp(g_pred[i].id, id) == 0) { slot = i; break; }
        if (!g_pred[i].used && slot < 0) slot = i;
    }
    if (slot < 0) slot = 0;
    strlcpy(g_pred[slot].id, id, sizeof g_pred[slot].id);
    g_pred[slot].index = index;
    g_pred[slot].used = true;
}

// ------------------------------------------------------------ prefs/init --

static void natural_changed(CFNotificationCenterRef c, void *o, CFNotificationName n,
                            const void *obj, CFDictionaryRef info) {
    (void)c; (void)o; (void)n; (void)obj; (void)info;
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
    g_natural = -1;
}

void spaces_init(void) {
    static bool done = false;
    if (done) return;
    done = true;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), &g_natural,
                                    natural_changed, CFSTR("SwipeScrollDirectionDidChangeNotification"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

bool spaces_available(void) {
    return &CGSMainConnectionID != NULL && &CGSGetActiveSpace != NULL &&
           &CGSCopyManagedDisplaySpaces != NULL;
}

static CGSConnectionID conn(void) {
    static CGSConnectionID cid = 0;
    if (!cid) cid = CGSMainConnectionID();
    return cid;
}

bool spaces_requires_augmentation(void) {
    static int cached = -1;
    if (cached >= 0) return cached;
    const char *force = getenv("XSWITCHER_FORCE_AUGMENTATION");
    if (force) return (cached = strcmp(force, "1") == 0);
    char v[32] = {0};
    size_t sz = sizeof v;
    int major = 0;
    if (sysctlbyname("kern.osproductversion", v, &sz, NULL, 0) == 0) major = atoi(v);
    return (cached = major >= 27);
}

// --------------------------------------------------------------- queries --

static CFStringRef copy_cursor_display(void) {
    CGEventRef e = CGEventCreate(NULL);
    if (!e) return NULL;
    CGPoint p = CGEventGetLocation(e);
    CFRelease(e);
    CGDirectDisplayID d = 0;
    uint32_t n = 0;
    if (CGGetDisplaysWithPoint(p, 1, &d, &n) != kCGErrorSuccess || n == 0) return NULL;
    CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(d);
    if (!u) return NULL;
    CFStringRef s = CFUUIDCreateString(NULL, u);
    CFRelease(u);
    return s;
}

static bool is_type(const void *v, CFTypeID t) { return v && CFGetTypeID(v) == t; }

static CGSSpaceID dict_id64(CFDictionaryRef d) {
    CFNumberRef n = CFDictionaryGetValue(d, CFSTR("id64"));
    CGSSpaceID id = 0;
    if (is_type(n, CFNumberGetTypeID())) CFNumberGetValue(n, kCFNumberSInt64Type, &id);
    return id;
}

static bool extract(CFDictionaryRef disp, CGSSpaceID globalActive, SpaceInfo *out) {
    memset(out->display, 0, sizeof out->display);
    CFStringRef ident = CFDictionaryGetValue(disp, CFSTR("Display Identifier"));
    if (is_type(ident, CFStringGetTypeID()))
        CFStringGetCString(ident, out->display, sizeof out->display, kCFStringEncodingUTF8);

    CFArrayRef spaces = CFDictionaryGetValue(disp, CFSTR("Spaces"));
    if (!is_type(spaces, CFArrayGetTypeID())) return false;

    CGSSpaceID active = 0;
    CFDictionaryRef cur = CFDictionaryGetValue(disp, CFSTR("Current Space"));
    if (is_type(cur, CFDictionaryGetTypeID())) active = dict_id64(cur);
    if (!active) active = globalActive;

    unsigned total = 0, index = 0;
    bool found = false;
    CFIndex n = CFArrayGetCount(spaces);
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef s = CFArrayGetValueAtIndex(spaces, i);
        if (!is_type(s, CFDictionaryGetTypeID())) continue;
        CGSSpaceID id = dict_id64(s);
        if (!id) continue;
        if (!found && id == active) { index = total; found = true; }
        total++;
    }
    if (total == 0 || !found) return false;
    out->count = total;
    out->current = index;
    return true;
}

bool spaces_query(SpaceInfo *out, bool cursorDisplay) {
    memset(out, 0, sizeof *out);
    if (!spaces_available()) return false;
    CGSConnectionID cid = conn();
    if (!cid) return false;
    CGSSpaceID active = CGSGetActiveSpace(cid);
    if (!active) return false;

    CFStringRef want = NULL;
    if (cursorDisplay) want = copy_cursor_display();
    else if (&CGSCopyActiveMenuBarDisplayIdentifier != NULL) want = CGSCopyActiveMenuBarDisplayIdentifier(cid);

    CFArrayRef displays = CGSCopyManagedDisplaySpaces(cid, want);
    if (!displays && want) displays = CGSCopyManagedDisplaySpaces(cid, NULL);
    if (!displays) {
        if (want) CFRelease(want);
        return false;
    }

    CFDictionaryRef target = NULL, fallback = NULL;
    CFIndex n = CFArrayGetCount(displays);
    for (CFIndex i = 0; i < n && !target; i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(displays, i);
        if (!is_type(d, CFDictionaryGetTypeID())) continue;
        if (!fallback) fallback = d;
        CFStringRef ident = CFDictionaryGetValue(d, CFSTR("Display Identifier"));
        if (want && is_type(ident, CFStringGetTypeID()) && CFEqual(ident, want)) target = d;
    }
    if (!target) target = fallback;
    bool ok = target && extract(target, active, out);
    if (want) CFRelease(want);
    CFRelease(displays);
    return ok;
}

unsigned spaces_current(const SpaceInfo *info) {
    unsigned p;
    return pred_get(info->display, &p) ? p : info->current;
}

void spaces_dump(FILE *out) {
    if (!spaces_available()) { fprintf(out, "CGS space APIs unavailable\n"); return; }
    CGSConnectionID cid = conn();
    CGSSpaceID active = CGSGetActiveSpace(cid);
    CFArrayRef displays = CGSCopyManagedDisplaySpaces(cid, NULL);
    if (!displays) { fprintf(out, "no managed displays\n"); return; }
    CFIndex n = CFArrayGetCount(displays);
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(displays, i);
        if (!is_type(d, CFDictionaryGetTypeID())) continue;
        SpaceInfo info;
        if (extract(d, active, &info))
            fprintf(out, "  display %-36s  space %u of %u\n", info.display, info.current + 1, info.count);
        else
            fprintf(out, "  display %-36s  (no usable spaces)\n", info.display);
    }
    CFRelease(displays);
}

// -------------------------------------------------------------- posting --

void spaces_set_gesture_speed(double s) { if (s > 0) g_speed = s; }
void spaces_set_tap_active(bool a) { g_tap_active = a; if (!a) g_synthetic = 0; }
void spaces_synthetic_clear(void) { g_synthetic = 0; }

bool spaces_synthetic_consume(void) {
    // Our events come back within milliseconds; a count left over after the
    // burst would let real trackpad swipes slip past the override.
    if (g_synthetic > 0 && !in_flight()) g_synthetic = 0;
    if (g_synthetic == 0) return false;
    g_synthetic--;
    return true;
}

static void post_one(CGEventRef ev) {
    if (g_tap_active) g_synthetic++;
    CGEventPost(kCGSessionEventTap, ev);
}

// Pre-macOS 27: public-field gesture with a tiny progress and high velocity.
static bool post_legacy(int phase, Dir d, double velocity) {
    const double sign = d == DIR_RIGHT ? 1.0 : -1.0;
    CGEventRef ev = CGEventCreate(NULL);
    if (!ev) return false;
    CGEventSetIntegerValueField(ev, F_CGS_TYPE, CGS_EVENT_DOCK_CONTROL);
    CGEventSetIntegerValueField(ev, F_HID_TYPE, HID_EVENT_DOCK_SWIPE);
    CGEventSetIntegerValueField(ev, F_PHASE, phase);
    CGEventSetDoubleValueField(ev, F_SWIPE_PROGRESS, sign * 0.000016);
    CGEventSetIntegerValueField(ev, F_SWIPE_MOTION, MOTION_HORIZONTAL);
    CGEventSetDoubleValueField(ev, F_SWIPE_VEL_X, sign * velocity);
    CGEventSetDoubleValueField(ev, F_SWIPE_VEL_Y, sign * velocity);
    CGEventPost(kCGSessionEventTap, ev); // not counted: the old path never re-entered the tap with pid 0
    CFRelease(ev);
    return true;
}

// ---- macOS 27: append a raw IOHID payload (field 4205) to the event -------

#pragma pack(push, 1)
typedef struct { uint32_t size, type, options; uint8_t depth, reserved[3]; } HIDBase;
typedef struct {
    HIDBase base;
    int32_t pos_x, pos_y, pos_z;
    uint32_t swipe_mask;
    uint16_t motion, flavor;
    int32_t progress;
} HIDFluid;
typedef struct { HIDBase base; int32_t vx, vy, vz; } HIDVelocity;
typedef struct { uint64_t timestamp, sender; uint32_t options, attr_len, count; } HIDHeader;
#pragma pack(pop)
_Static_assert(sizeof(HIDBase) == 16, "HIDBase");
_Static_assert(sizeof(HIDFluid) == 40, "HIDFluid");
_Static_assert(sizeof(HIDVelocity) == 28, "HIDVelocity");
_Static_assert(sizeof(HIDHeader) == 28, "HIDHeader");

static int32_t fx1616(double v) {
    int32_t f = (int32_t)(v * 65536.0);
    if (f == 0 && v != 0.0) return v > 0.0 ? 1 : -1;
    return f;
}

// Writes into buf (caller provides >= sizeof header+fluid+velocity). No malloc.
static size_t build_payload(CGEventRef ev, uint8_t *buf) {
    int64_t phase = CGEventGetIntegerValueField(ev, F_PHASE);
    double vx = CGEventGetDoubleValueField(ev, F_SWIPE_VEL_X);
    double vy = CGEventGetDoubleValueField(ev, F_SWIPE_VEL_Y);
    bool with_vel = vx != 0.0 || vy != 0.0 || phase == PHASE_ENDED;
    size_t len = sizeof(HIDHeader) + sizeof(HIDFluid) + (with_vel ? sizeof(HIDVelocity) : 0);
    memset(buf, 0, len);

    HIDHeader *h = (HIDHeader *)buf;
    uint64_t ts = CGEventGetTimestamp(ev);
    h->timestamp = ts ? ts : mach_absolute_time();
    h->count = with_vel ? 2 : 1;

    HIDFluid *f = (HIDFluid *)(buf + sizeof(HIDHeader));
    f->base.size = sizeof(HIDFluid);
    f->base.type = HID_EVENT_DOCK_SWIPE;
    f->base.options = (uint32_t)((phase & 0xFF) << 24);
    f->pos_x = fx1616(CGEventGetDoubleValueField(ev, F_SWIPE_POS_X));
    f->pos_y = fx1616(CGEventGetDoubleValueField(ev, F_SWIPE_POS_Y));
    f->swipe_mask = (uint32_t)CGEventGetIntegerValueField(ev, F_SWIPE_MASK);
    f->motion = (uint16_t)CGEventGetIntegerValueField(ev, F_SWIPE_MOTION);
    f->flavor = 3; // dock primary
    f->progress = fx1616(CGEventGetDoubleValueField(ev, F_SWIPE_PROGRESS));

    if (with_vel) {
        HIDVelocity *v = (HIDVelocity *)(buf + sizeof(HIDHeader) + sizeof(HIDFluid));
        v->base.size = sizeof(HIDVelocity);
        v->base.type = HID_EVENT_VELOCITY;
        v->base.depth = 1;
        v->vx = fx1616(vx);
        v->vy = fx1616(vy);
    }
    return len;
}

static CGEventRef augment(CGEventRef ev) {
    CFDataRef data = CGEventCreateData(kCFAllocatorDefault, ev);
    if (!data) return NULL;
    const uint8_t *bytes = CFDataGetBytePtr(data);
    CFIndex len = CFDataGetLength(data);
    if (len < 4 || bytes[0] || bytes[1] || bytes[2] || bytes[3] != 2) { // format v2 only
        CFRelease(data);
        return NULL;
    }

    uint8_t payload[sizeof(HIDHeader) + sizeof(HIDFluid) + sizeof(HIDVelocity)];
    size_t plen = build_payload(ev, payload);
    size_t total = (size_t)len + 4 + plen;

    uint8_t stackbuf[4096];
    uint8_t *buf = total <= sizeof stackbuf ? stackbuf : malloc(total);
    if (!buf) { CFRelease(data); return NULL; }
    memcpy(buf, bytes, (size_t)len);
    buf[len + 0] = (uint8_t)((plen >> 8) & 0xFF);  // size, big-endian
    buf[len + 1] = (uint8_t)(plen & 0xFF);
    buf[len + 2] = (uint8_t)((4205 >> 8) & 0xFF);  // field id 4205
    buf[len + 3] = (uint8_t)(4205 & 0xFF);
    memcpy(buf + len + 4, payload, plen);
    CFRelease(data);

    CFDataRef nd = CFDataCreate(kCFAllocatorDefault, buf, (CFIndex)total);
    if (buf != stackbuf) free(buf);
    if (!nd) return NULL;
    CGEventRef out = CGEventCreateFromData(kCFAllocatorDefault, nd);
    CFRelease(nd);
    return out;
}

// On macOS 27 right is negative, and the Dock reads the posted sign through
// the natural-scrolling preference, so it flips again when that is off.
static double modern_sign(Dir d) {
    if (g_natural < 0) {
        Boolean valid = false;
        Boolean nat = CFPreferencesGetAppBooleanValue(CFSTR("com.apple.swipescrolldirection"),
                                                      kCFPreferencesAnyApplication, &valid);
        g_natural = (!valid || nat) ? 1 : 0;
    }
    double s = d == DIR_RIGHT ? -1.0 : 1.0;
    return g_natural ? s : -s;
}

static bool post_modern(int phase, Dir d) {
    const double sign = modern_sign(d);
    CGEventRef ev = CGEventCreate(NULL);
    if (!ev) return false;
    CGEventSetIntegerValueField(ev, F_CGS_TYPE, CGS_EVENT_DOCK_CONTROL);
    CGEventSetIntegerValueField(ev, F_HID_TYPE, HID_EVENT_DOCK_SWIPE);
    CGEventSetIntegerValueField(ev, F_PHASE, phase);
    CGEventSetIntegerValueField(ev, F_SWIPE_MOTION, MOTION_HORIZONTAL);
    CGEventSetDoubleValueField(ev, F_SWIPE_PROGRESS, sign * 0.000016); // smallest 16.16 step
    CGEventSetIntegerValueField(ev, F_PHASE_ALIAS, phase);
    CGEventSetDoubleValueField(ev, F_ZOOM_DELTA_Y, 3.0);
    CGEventSetDoubleValueField(ev, F_FIELD_169, (double)mach_absolute_time());
    CGEventSetDoubleValueField(ev, F_SWIPE_POS_X, 0.1);
    if (phase == PHASE_ENDED) // the fling commits the switch; 16.16 caps it near 32767
        CGEventSetDoubleValueField(ev, F_SWIPE_VEL_X, sign * 9999.0);

    CGEventRef aug = augment(ev);
    CFRelease(ev);
    if (!aug) return false;

    // The Dock ignores a DockControl event without a companion gesture event.
    CGEventRef companion = CGEventCreate(NULL);
    if (!companion) { CFRelease(aug); return false; }
    CGEventSetIntegerValueField(companion, F_CGS_TYPE, CGS_EVENT_GESTURE);

    post_one(aug);
    post_one(companion);
    CFRelease(aug);
    CFRelease(companion);
    return true;
}

static bool post_phase(int phase, Dir d, double velocity) {
    return spaces_requires_augmentation() ? post_modern(phase, d) : post_legacy(phase, d, velocity);
}

// Began + Changed + Ended. With only two, Mission Control misbehaves.
static bool gesture(Dir d, double velocity) {
    g_last_gesture = CFAbsoluteTimeGetCurrent();
    return post_phase(PHASE_BEGAN, d, velocity) &&
           post_phase(PHASE_CHANGED, d, velocity) &&
           post_phase(PHASE_ENDED, d, velocity);
}

// -------------------------------------------------------------- actions --

bool spaces_go(const SpaceInfo *info, Dir d, unsigned *target) {
    if (!info) return gesture(d, g_speed); // no topology: switch blind
    if (info->count == 0) return false;
    unsigned cur = spaces_current(info);
    if (d == DIR_LEFT ? cur == 0 : cur + 1 >= info->count) return false;
    unsigned t = d == DIR_LEFT ? cur - 1 : cur + 1;
    if (!gesture(d, g_speed)) return false;
    pred_set(info->display, t);
    if (target) *target = t;
    return true;
}

bool spaces_go_to(const SpaceInfo *info, unsigned index, unsigned *target) {
    if (!info || info->count == 0) return false;
    bool oob = index >= info->count;
    if (oob) index = info->count - 1;
    unsigned cur = spaces_current(info);
    if (target) *target = index;
    if (cur == index) return !oob;
    Dir d = cur < index ? DIR_RIGHT : DIR_LEFT;
    unsigned steps = d == DIR_RIGHT ? index - cur : cur - index;
    double vel = g_speed * steps;
    for (unsigned i = 0; i < steps; i++)
        if (!gesture(d, vel)) return false;
    pred_set(info->display, index);
    return !oob;
}
