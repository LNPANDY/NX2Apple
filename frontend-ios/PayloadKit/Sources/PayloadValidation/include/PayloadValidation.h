#pragma once
#include <stddef.h>

// Ask the kernel to attach the file's own signature and enforce this process's
// library validation policy. This never disables or patches code signing.
int nx_payload_validate(const char *path, char *error, size_t capacity);
