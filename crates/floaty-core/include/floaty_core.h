#ifndef FLOATY_CORE_H
#define FLOATY_CORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FloatyCore FloatyCore;

typedef struct FloatyByteBuffer {
    uint8_t *data;
    size_t len;
} FloatyByteBuffer;

// Creates a local-first Floaty core handle seeded with a mocked dashboard
// snapshot. Returns NULL if initialization fails.
FloatyCore *floaty_core_new(void);

// Releases a Floaty core handle. Passing NULL is a no-op.
void floaty_core_free(FloatyCore *core);

// Returns the current immutable snapshot version, or 0 for NULL.
uint64_t floaty_core_snapshot_version(const FloatyCore *core);

// Refreshes local core state and returns the new snapshot version, or 0 for NULL.
uint64_t floaty_core_refresh(FloatyCore *core);

// Pulls the latest DashboardSnapshot as UTF-8 JSON bytes. The returned buffer is
// not null-terminated. Release it with floaty_core_buffer_free exactly once.
FloatyByteBuffer floaty_core_snapshot_json(const FloatyCore *core);

// Releases a buffer returned by floaty_core_snapshot_json. Passing an empty
// buffer is a no-op.
void floaty_core_buffer_free(FloatyByteBuffer buffer);

#ifdef __cplusplus
}
#endif

#endif // FLOATY_CORE_H
