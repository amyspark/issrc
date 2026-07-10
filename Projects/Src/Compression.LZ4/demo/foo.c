#include "lz4frame.h"

#include <string.h>
#include <stdio.h>
#include <inttypes.h>

int main(int argc, char*argv[])
{
    LZ4F_preferences_t prefs;
    memset(&prefs, 0, sizeof(prefs));
    prefs.autoFlush = 1;
    prefs.favorDecSpeed = 1;
    prefs.frameInfo.blockSizeID = LZ4F_max64KB;

    for (int i = 0; i <= 12; i++) {
        prefs.compressionLevel = i;
        fprintf(stdout, "For a 64KB input, this function needs:  %" PRIu64 " \n", LZ4F_compressBound(4 * 1024 * 1024, &prefs));
    }

    fprintf(stderr, "MROW! <3\n");
}
