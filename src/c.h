/* The C surface Ronny uses, translated once by the build system.
 *
 * Zig 0.16 deprecates @cImport in favour of `b.addTranslateC`, which runs the
 * translation as a proper cacheable build step. This header is its input; the
 * result is imported from Zig as `@import("c")`.
 */

#include <libetpan/libetpan.h>
#include <libetpan/mailmime_decode.h>
