#include "../gba_core.h"
#include <stdint.h>
#include <stdbool.h>
#include <limits.h>

/* ===== Imported from int.zip/int/timing.c (2026-04-02) ===== */

#ifndef UNUSED
#define UNUSED(x) (void) (x)
#endif

#ifndef UNLIKELY
#define UNLIKELY(x) (x)
#endif

int32_t mTimingCurrentTime(const struct mTiming* timing);
int32_t mTimingNextEvent(const struct mTiming* timing);

void mTimingInit(struct mTiming* timing, int32_t* relativeCycles, int32_t* nextEvent) {
	timing->root = NULL;
	timing->reroot = NULL;
	timing->globalCycles = 0;
	timing->masterCycles = 0;
	timing->relativeCycles = relativeCycles;
	timing->nextEvent = nextEvent;
}

void mTimingDeinit(struct mTiming* timing) {
	UNUSED(timing);
}

void mTimingClear(struct mTiming* timing) {
	timing->root = NULL;
	timing->reroot = NULL;
	timing->globalCycles = 0;
	timing->masterCycles = 0;
}

void mTimingInterrupt(struct mTiming* timing) {
	if (!timing->root) {
		return;
	}
	timing->reroot = timing->root;
	timing->root = NULL;
}

void mTimingSchedule(struct mTiming* timing, struct mTimingEvent* event, int32_t when) {
	int32_t nextEvent = when + *timing->relativeCycles;
	event->when = nextEvent + timing->masterCycles;
	if (nextEvent < *timing->nextEvent) {
		*timing->nextEvent = nextEvent;
	}
	struct mTimingEvent** previous;
	struct mTimingEvent* next;
	if (timing->reroot) {
		previous = &timing->reroot;
		next = timing->reroot;
	} else {
		previous = &timing->root;
		next = timing->root;
	}

	unsigned priority = event->priority;
	while (next) {
		int32_t nextWhen = next->when - timing->masterCycles;
		if (nextWhen > nextEvent || (nextWhen == nextEvent && next->priority > priority)) {
			break;
		}
		previous = &next->next;
		next = next->next;
	}
	event->next = next;
	*previous = event;
}

void mTimingScheduleAbsolute(struct mTiming* timing, struct mTimingEvent* event, int32_t when) {
	mTimingSchedule(timing, event, when - mTimingCurrentTime(timing));
}

void mTimingDeschedule(struct mTiming* timing, struct mTimingEvent* event) {
	struct mTimingEvent** previous;
	struct mTimingEvent* next;
	if (timing->reroot) {
		previous = &timing->reroot;
		next = timing->reroot;
	} else {
		previous = &timing->root;
		next = timing->root;
	}

	while (next) {
		if (next == event) {
			*previous = next->next;
			return;
		}
		previous = &next->next;
		next = next->next;
	}
}

bool mTimingIsScheduled(const struct mTiming* timing, const struct mTimingEvent* event) {
	const struct mTimingEvent* next = timing->root;
	if (!next) {
		next = timing->reroot;
	}
	while (next) {
		if (next == event) {
			return true;
		}
		next = next->next;
	}
	return false;
}

int32_t mTimingTick(struct mTiming* timing, int32_t cycles) {
	timing->masterCycles += cycles;
	uint32_t masterCycles = timing->masterCycles;
	while (timing->root) {
		struct mTimingEvent* next = timing->root;
		int32_t nextWhen = next->when - masterCycles;
		if (nextWhen > 0) {
			return nextWhen;
		}
		timing->root = next->next;
		next->callback(timing, next->context, -nextWhen);
	}
	if (UNLIKELY(timing->reroot)) {
		timing->root = timing->reroot;
		timing->reroot = NULL;
		*timing->nextEvent = mTimingNextEvent(timing);
	}
	return *timing->nextEvent;
}

int32_t mTimingCurrentTime(const struct mTiming* timing) {
	return timing->masterCycles - *timing->relativeCycles;
}

int32_t mTimingNextEvent(const struct mTiming* timing) {
	if (!timing->root) {
		return INT_MAX;
	}
	return timing->root->when - mTimingCurrentTime(timing);
}

