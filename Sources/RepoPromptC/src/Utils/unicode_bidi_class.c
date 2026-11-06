#include "unicode_bidi_class.h"

#include <unicode/uchar.h>

RPCEBidiFirstStrongClass rpce_bidi_first_strong_class(uint32_t scalar) {
    switch (u_charDirection((UChar32)scalar)) {
    case U_LEFT_TO_RIGHT:
        return RPCEBidiFirstStrongClassLeftToRight;
    case U_RIGHT_TO_LEFT:
    case U_RIGHT_TO_LEFT_ARABIC:
        return RPCEBidiFirstStrongClassRightToLeft;
    case U_LEFT_TO_RIGHT_ISOLATE:
    case U_RIGHT_TO_LEFT_ISOLATE:
    case U_FIRST_STRONG_ISOLATE:
        return RPCEBidiFirstStrongClassIsolateInitiator;
    case U_POP_DIRECTIONAL_ISOLATE:
        return RPCEBidiFirstStrongClassPopDirectionalIsolate;
    case U_BLOCK_SEPARATOR:
        return RPCEBidiFirstStrongClassParagraphSeparator;
    default:
        return RPCEBidiFirstStrongClassOther;
    }
}
