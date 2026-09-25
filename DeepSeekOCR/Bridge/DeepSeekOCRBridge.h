#ifndef DeepSeekOCRBridge_h
#define DeepSeekOCRBridge_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DSOCRContext DSOCRContext;

typedef struct DSOCRMetrics {
    double model_load_seconds;
    double encode_seconds;
    double generation_seconds;
    int32_t input_tokens;
    int32_t output_tokens;
    bool output_truncated;
    bool fast_vision_used;
} DSOCRMetrics;

enum {
    DSOCR_VISION_MODE_ACCURATE = 0,
    DSOCR_VISION_MODE_FAST = 1,
};

/// Returns the mode best matched to the current GPU. M-series devices use the
/// single-view fast path; A-series devices preserve the multi-crop path.
int32_t dsocr_recommended_vision_mode(void);

/// Loads the text model, text context, and vision encoder. Returns NULL on error.
DSOCRContext * dsocr_create(
    const char * model_path,
    const char * mmproj_path,
    int32_t context_size,
    int32_t thread_count,
    char * error_buffer,
    size_t error_buffer_size
);

/// Runs one isolated OCR request. Call dsocr_reset_cancel immediately before it.
/// `image_bytes` must contain PNG or JPEG data.
/// `output_text` is allocated with malloc and must be released with dsocr_string_free.
int32_t dsocr_recognize(
    DSOCRContext * context,
    const uint8_t * image_bytes,
    size_t image_length,
    const char * prompt,
    int32_t max_output_tokens,
    char ** output_text,
    DSOCRMetrics * metrics,
    char * error_buffer,
    size_t error_buffer_size
);

/// Runs OCR with an explicit vision preprocessing mode. Fast mode encodes one
/// 1024px overview; accurate mode additionally encodes the 768px detail crops.
int32_t dsocr_recognize_with_vision_mode(
    DSOCRContext * context,
    const uint8_t * image_bytes,
    size_t image_length,
    const char * prompt,
    int32_t max_output_tokens,
    int32_t vision_mode,
    char ** output_text,
    DSOCRMetrics * metrics,
    char * error_buffer,
    size_t error_buffer_size
);

void dsocr_cancel(DSOCRContext * context);
/// Clears a previous cancellation immediately before starting a new request.
void dsocr_reset_cancel(DSOCRContext * context);
/// Must be externally serialized with create/recognize/cancel operations.
void dsocr_destroy(DSOCRContext * context);
void dsocr_string_free(char * value);

#ifdef __cplusplus
}
#endif

#endif
