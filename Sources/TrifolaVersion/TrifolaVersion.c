#include "TrifolaVersion.h"

#ifndef TRIFOLA_RELEASE_VERSION
#error "TRIFOLA_RELEASE_VERSION must be supplied by Package.swift"
#endif

const char *TrifolaReleaseVersion(void) {
    return TRIFOLA_RELEASE_VERSION;
}
