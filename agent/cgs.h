// Private CoreGraphics / SkyLight declarations shared by spaces.c and swipe.c.
// Field numbers and constants come from InstantSpaceSwitcher (MIT, (c) 2026 jurplel).
#ifndef XS_CGS_H
#define XS_CGS_H

#include <ApplicationServices/ApplicationServices.h>
#include <stdint.h>

typedef int32_t CGSConnectionID;
typedef uint64_t CGSSpaceID;

extern CFArrayRef CGSCopyManagedDisplaySpaces(CGSConnectionID cid, CFStringRef display) __attribute__((weak_import));
extern CFStringRef CGSCopyActiveMenuBarDisplayIdentifier(CGSConnectionID cid) __attribute__((weak_import));
extern CGSConnectionID CGSMainConnectionID(void) __attribute__((weak_import));
extern CGSSpaceID CGSGetActiveSpace(CGSConnectionID cid) __attribute__((weak_import));

// Undocumented CGEvent fields used by Dock swipe gestures.
#define F_CGS_TYPE       ((CGEventField)55)
#define F_HID_TYPE       ((CGEventField)110)
#define F_SWIPE_MASK     ((CGEventField)115)
#define F_SWIPE_MOTION   ((CGEventField)123)
#define F_SWIPE_PROGRESS ((CGEventField)124)
#define F_SWIPE_POS_X    ((CGEventField)125)
#define F_SWIPE_POS_Y    ((CGEventField)126)
#define F_SWIPE_VEL_X    ((CGEventField)129)
#define F_SWIPE_VEL_Y    ((CGEventField)130)
#define F_PHASE          ((CGEventField)132)
#define F_PHASE_ALIAS    ((CGEventField)134)
#define F_ZOOM_DELTA_Y   ((CGEventField)138)
#define F_FIELD_169      ((CGEventField)169)

enum {
    CGS_EVENT_GESTURE      = 29,
    CGS_EVENT_DOCK_CONTROL = 30,
};

enum {
    HID_EVENT_VELOCITY   = 9,
    HID_EVENT_DOCK_SWIPE = 23, // also IOHIDEventTypeFluidTouchGesture
};

enum {
    PHASE_BEGAN     = 1,
    PHASE_CHANGED   = 2,
    PHASE_ENDED     = 4,
    PHASE_CANCELLED = 8,
};

enum { MOTION_HORIZONTAL = 1 };

#endif
