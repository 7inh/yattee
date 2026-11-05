//
//  SMBBridge.c
//  Yattee
//
//  Compatibility entry points until media sources are removed in phase 3.
//  The audio-only build does not bundle an SMB library.
//

#include "SMBBridge.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>

void* smb_init_context(const char *workgroup, const char *username,
                       const char *password, SMBProtocolVersion version) {
    errno = ENOTSUP;
    return NULL;
}

void smb_free_context(void *ctx) {}

SMBFileInfo* smb_list_directory(void *ctx, const char *url, int *count, char **error) {
    if (count) *count = 0;
    if (error) *error = strdup("SMB sources are unavailable in the audio-only build");
    errno = ENOTSUP;
    return NULL;
}

void smb_free_file_list(SMBFileInfo *files, int count) {
    if (!files) return;
    for (int index = 0; index < count; index++) free(files[index].name);
    free(files);
}

int smb_test_connection(void *ctx, const char *url) {
    return -ENOTSUP;
}

int smb_download_file(void *ctx, const char *url, const char *local_path, char **error) {
    if (error) *error = strdup("SMB sources are unavailable in the audio-only build");
    return -ENOTSUP;
}
