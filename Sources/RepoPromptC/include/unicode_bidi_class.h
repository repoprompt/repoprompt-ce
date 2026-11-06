#ifndef REPOPROMPT_UNICODE_BIDI_CLASS_H
#define REPOPROMPT_UNICODE_BIDI_CLASS_H

#include <stdint.h>

// What a Unicode scalar contributes to first-strong direction detection (UAX #9 rules P2/P3),
// derived from its Bidi_Class through the system ICU. Keeps ICU types and enum values out of
// Swift: callers only see this repo-owned classification.
typedef enum __attribute__((enum_extensibility(closed))) RPCEBidiFirstStrongClass {
    // Weak, neutral, explicit embedding/override (LRE, RLE, LRO, RLO, PDF) or unassigned:
    // skipped by P2.
    RPCEBidiFirstStrongClassOther = 0,
    // Bidi_Class L (letters of left-to-right scripts, LRM, ...).
    RPCEBidiFirstStrongClassLeftToRight = 1,
    // Bidi_Class R or AL (Hebrew, Arabic, RLM, ALM, ...).
    RPCEBidiFirstStrongClassRightToLeft = 2,
    // Bidi_Class LRI, RLI or FSI: P2 skips everything up to the matching PDI.
    RPCEBidiFirstStrongClassIsolateInitiator = 3,
    // Bidi_Class PDI.
    RPCEBidiFirstStrongClassPopDirectionalIsolate = 4,
    // Bidi_Class B: ends the paragraph, so P2 starts over.
    RPCEBidiFirstStrongClassParagraphSeparator = 5
} RPCEBidiFirstStrongClass;

RPCEBidiFirstStrongClass rpce_bidi_first_strong_class(uint32_t scalar);

#endif
