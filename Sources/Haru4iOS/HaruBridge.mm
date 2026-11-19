#import "HaruBridge.h"

#include <SpeechCpp/speech.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <new>

struct HaruRuntime {
    speech_model *model = nullptr;
    speech_dialogue *dialogue = nullptr;
};

static int write_result(speech_status status, char *buffer, size_t capacity) {
    if (status >= SPEECH_OK) {
        if (buffer && capacity) buffer[0] = '\0';
        return static_cast<int>(status);
    }

    const char *message = speech_last_error();
    if (!message || !*message) message = speech_status_name(status);
    if (buffer && capacity) {
        std::snprintf(buffer, capacity, "%s", message ? message : "Unknown speech.cpp error");
    }
    return static_cast<int>(status);
}

extern "C" HaruRuntime *HaruRuntimeCreate(void) {
    return new (std::nothrow) HaruRuntime();
}

extern "C" void HaruRuntimeDestroy(HaruRuntime *runtime) {
    if (!runtime) return;
    if (runtime->dialogue) {
        speech_dialogue_free(runtime->dialogue);
        runtime->dialogue = nullptr;
    }
    if (runtime->model) {
        speech_model_free(runtime->model);
        runtime->model = nullptr;
    }
    delete runtime;
}

extern "C" int HaruRuntimeLoadModel(
    HaruRuntime *runtime,
    const char *model_path,
    const char *device,
    int threads,
    char *error_buffer,
    size_t error_capacity
) {
    if (!runtime || !model_path || !*model_path) {
        if (error_buffer && error_capacity) std::snprintf(error_buffer, error_capacity, "Invalid runtime or model path");
        return SPEECH_ERROR_INVALID_ARGUMENT;
    }
    if (runtime->model) {
        if (error_buffer && error_capacity) std::snprintf(error_buffer, error_capacity, "A model is already loaded");
        return SPEECH_ERROR_INVALID_ARGUMENT;
    }

    speech_load_params *params = nullptr;
    speech_status status = speech_load_params_new(&params);
    if (status == SPEECH_OK && device && *device) {
        status = speech_load_params_set_device(params, device);
    }
    if (status == SPEECH_OK && threads > 0) {
        status = speech_load_params_set_threads(params, threads);
    }
    if (status == SPEECH_OK) {
        status = speech_load_params_set_warmup(params, 0);
    }
    if (status == SPEECH_OK) {
        status = speech_model_load(model_path, params, &runtime->model);
    }

    const int result = write_result(status, error_buffer, error_capacity);
    speech_load_params_free(params);
    return result;
}

extern "C" int HaruRuntimeStartDialogue(
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
) {
    if (!runtime || !runtime->model || runtime->dialogue || input_sample_rate <= 0 || !callback) {
        if (error_buffer && error_capacity) std::snprintf(error_buffer, error_capacity, "Runtime must have a loaded model and no active dialogue");
        return SPEECH_ERROR_INVALID_ARGUMENT;
    }

    speech_request *request = nullptr;
    speech_status status = speech_request_new(runtime->model, &request);
    if (status == SPEECH_OK && language && *language) {
        status = speech_request_set_string(request, SPEECH_OPT_LANGUAGE, language);
    }
    if (status == SPEECH_OK && character_name && *character_name) {
        status = speech_request_set_string(request, SPEECH_OPT_NAME, character_name);
    }
    if (status == SPEECH_OK && persona && *persona) {
        status = speech_request_set_string(request, SPEECH_OPT_PERSONA, persona);
    }
    if (status == SPEECH_OK && other_name && *other_name) {
        status = speech_request_set_string(request, SPEECH_OPT_OTHER_NAME, other_name);
    }
    if (status == SPEECH_OK && max_seconds > 0.0) {
        status = speech_request_set_float(request, SPEECH_OPT_MAX_SECONDS, max_seconds);
    }
    if (status == SPEECH_OK) {
        status = speech_request_set_bool(request, SPEECH_OPT_SPEAK_FIRST, speak_first ? 1 : 0);
    }
    if (status == SPEECH_OK) {
        status = speech_dialogue_start(request, input_sample_rate, callback, context, &runtime->dialogue);
    }

    const int result = write_result(status, error_buffer, error_capacity);
    speech_request_free(request);
    return result;
}

extern "C" int HaruRuntimePushAudio(
    HaruRuntime *runtime,
    const float *samples,
    size_t sample_count,
    char *error_buffer,
    size_t error_capacity
) {
    if (!runtime || !runtime->dialogue || !samples || sample_count == 0) {
        if (error_buffer && error_capacity) std::snprintf(error_buffer, error_capacity, "No active dialogue or audio samples");
        return SPEECH_ERROR_INVALID_ARGUMENT;
    }
    return write_result(speech_dialogue_push(runtime->dialogue, samples, sample_count), error_buffer, error_capacity);
}

extern "C" int HaruRuntimeEndDialogue(
    HaruRuntime *runtime,
    char *error_buffer,
    size_t error_capacity
) {
    if (!runtime || !runtime->dialogue) {
        if (error_buffer && error_capacity) std::snprintf(error_buffer, error_capacity, "No active dialogue");
        return SPEECH_ERROR_INVALID_ARGUMENT;
    }
    speech_status status = speech_dialogue_end(runtime->dialogue);
    const int result = write_result(status, error_buffer, error_capacity);
    speech_dialogue_free(runtime->dialogue);
    runtime->dialogue = nullptr;
    return result;
}
