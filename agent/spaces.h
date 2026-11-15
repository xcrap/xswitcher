#ifndef XS_SPACES_H
#define XS_SPACES_H

#include <stdbool.h>
#include <stdio.h>

typedef enum { DIR_LEFT = 0, DIR_RIGHT = 1 } Dir;

typedef struct {
    unsigned current;   // zero-based index of the active space (live CGS value)
    unsigned count;     // spaces on this display, fullscreen spaces included
    char display[128];  // display UUID, or "Main" when displays share spaces
} SpaceInfo;

// One-time setup (natural-scrolling observer). Safe to call more than once.
void spaces_init(void);
bool spaces_available(void);

// One CGS round trip (~0.1 ms). cursorDisplay=false uses the menu-bar display.
bool spaces_query(SpaceInfo *out, bool cursorDisplay);

// Current index, preferring our own prediction while a burst is in flight.
unsigned spaces_current(const SpaceInfo *info);

// Post the gestures. info may be NULL for spaces_go (blind switch).
// On success *target (if non-NULL) receives the destination index.
bool spaces_go(const SpaceInfo *info, Dir d, unsigned *target);
bool spaces_go_to(const SpaceInfo *info, unsigned index, unsigned *target);

void spaces_set_gesture_speed(double speed);

// Bookkeeping for the optional swipe tap, which must let our own
// synthetic events through.
void spaces_set_tap_active(bool active);
bool spaces_synthetic_consume(void);
void spaces_synthetic_clear(void);
bool spaces_requires_augmentation(void);

void spaces_dump(FILE *out);

#endif
