#ifndef XS_SWIPE_H
#define XS_SWIPE_H

#include <stdbool.h>
#include "spaces.h"

typedef void (*swipe_switched_fn)(const SpaceInfo *before, unsigned target);

// Installs a gesture-only event tap on the main run loop. Needs Accessibility.
bool swipe_enable(swipe_switched_fn cb);
void swipe_disable(void);
bool swipe_enabled(void);

#endif
