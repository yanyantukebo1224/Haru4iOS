#ifndef HARU_BRIDGE_H
#define HARU_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HaruRuntime HaruRuntime;

typedef int (*HaruFrameCallback)(
    const float *samples,
    size_t sample_count,
    const char *text,
    void *context
);

HaruRuntime *HaruRuntimeCreate(void);
void HaruRuntimeDestroy(HaruRuntime *runtime);

int HaruRuntimeLoadModel(
    HaruRuntime *runtime,
    const char *model_path,
    const char *device,
    int threads,
    char *error_buffer,
    size_t error_capacity
);

int HaruRuntimeStartDialogue(
    HaruRuntime *runtime,
    int input_sample_rate,
    const char *language,
    const char *character_name,
    const char *persona,
    const char *other_name,
    double max_seconds,
    int speak_first,
    HaruFrameCallback callback,
    void *context,
    char *error_buffer,
    size_t error_capacity
);

int HaruRuntimePushAudio(
    HaruRuntime *runtime,
    const float *samples,
    size_t sample_count,
    char *error_buffer,
    size_t error_capacity
);

int HaruRuntimeEndDialogue(
    HaruRuntime *runtime,
    char *error_buffer,
    size_t error_capacity
);

#ifdef __cplusplus
}
#endif

#endif
