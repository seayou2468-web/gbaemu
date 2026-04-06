
#ifndef M_INTERNAL_DEFINES_H
#define M_INTERNAL_DEFINES_H

#define mSAVEDATA_CLEANUP_THRESHOLD 15

enum {
	mSAVEDATA_DIRT_NONE = 0,
	mSAVEDATA_DIRT_NEW = 1,
	mSAVEDATA_DIRT_SEEN = 2,
};

static inline bool mSavedataClean(int* dirty, uint32_t* dirtAge, uint32_t frameCount) {
	if (*dirty & mSAVEDATA_DIRT_NEW) {
		*dirtAge = frameCount;
		*dirty &= ~mSAVEDATA_DIRT_NEW;
		if (!(*dirty & mSAVEDATA_DIRT_SEEN)) {
			*dirty |= mSAVEDATA_DIRT_SEEN;
		}
	} else if ((*dirty & mSAVEDATA_DIRT_SEEN) && frameCount - *dirtAge > mSAVEDATA_CLEANUP_THRESHOLD) {
		*dirty = 0;
		return true;
	}
	return false;
}

#endif
