#include "DeepSeekOCRBridge.h"

#import <Metal/Metal.h>
#include <TargetConditionals.h>
#include <llama/ggml.h>
#include <llama/llama.h>
#include <llama/mtmd-helper.h>
#include <llama/mtmd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;

#if TARGET_OS_SIMULATOR
constexpr bool use_metal = false;
#else
constexpr bool use_metal = true;
#endif

bool has_apple_m_series_gpu() {
    if (!use_metal) {
        return false;
    }
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    return device != nil && [device.name hasPrefix:@"Apple M"];
}

bool use_vision_flash_attention() {
    if (!use_metal) {
        return false;
    }

    // Keep an escape hatch for profiling future Apple GPUs without shipping a
    // new binary. Normal app launches do not set this environment variable.
    if (const char * override_value = std::getenv("DSOCR_VISION_FLASH_ATTN")) {
        return std::strcmp(override_value, "0") != 0;
    }

    // The fixed 768/1024 DeepSeek vision graphs benchmark faster through the
    // regular Metal attention kernels on M-series GPUs. A-series mobile GPUs
    // need flash attention to avoid the large intermediate-buffer penalty.
    if (has_apple_m_series_gpu()) {
        return false;
    }
    return true;
}

std::once_flag backend_once;
std::mutex log_mutex;
std::string recent_log;
bool capture_log_continuation = false;

void quiet_log_callback(enum ggml_log_level level, const char * text, void *) {
    if (text == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(log_mutex);
    const bool should_capture = level == GGML_LOG_LEVEL_CONT
        ? capture_log_continuation
        : level >= GGML_LOG_LEVEL_WARN;
    if (level != GGML_LOG_LEVEL_CONT) {
        capture_log_continuation = should_capture;
    }
    if (!should_capture) {
        return;
    }
    recent_log.append(text);
    constexpr size_t max_log_size = 8192;
    if (recent_log.size() > max_log_size) {
        recent_log.erase(0, recent_log.size() - max_log_size);
    }
}

std::string captured_log() {
    std::lock_guard<std::mutex> lock(log_mutex);
    return recent_log;
}

void clear_captured_log() {
    std::lock_guard<std::mutex> lock(log_mutex);
    recent_log.clear();
    capture_log_continuation = false;
}

void write_error(char * buffer, size_t buffer_size, const std::string & message) {
    if (buffer == nullptr || buffer_size == 0) {
        return;
    }
    const size_t count = std::min(buffer_size - 1, message.size());
    std::memcpy(buffer, message.data(), count);
    buffer[count] = '\0';
}

double elapsed_seconds(Clock::time_point start) {
    return std::chrono::duration<double>(Clock::now() - start).count();
}

std::string format_prompt(const llama_model * model, const std::string & content) {
    const llama_chat_message message = {"user", content.c_str()};
    const char * chat_template = llama_model_chat_template(model, nullptr);
    // The community DeepSeek-OCR-2 GGUF intentionally has no tokenizer chat
    // template. llama-mtmd-cli therefore feeds this model the raw marker plus
    // instruction; mirror that behavior instead of treating it as an error.
    if (chat_template == nullptr || chat_template[0] == '\0') {
        return content;
    }

    std::vector<char> buffer(std::max<size_t>(4096, content.size() * 4 + 1024));
    int32_t written = llama_chat_apply_template(
        chat_template, &message, 1, true, buffer.data(), static_cast<int32_t>(buffer.size()));

    if (written <= 0) {
        return content;
    }
    if (static_cast<size_t>(written) >= buffer.size()) {
        buffer.resize(static_cast<size_t>(written) + 1);
        written = llama_chat_apply_template(
            chat_template, &message, 1, true, buffer.data(), static_cast<int32_t>(buffer.size()));
        if (written <= 0) {
            return content;
        }
    }
    return std::string(buffer.data(), static_cast<size_t>(written));
}

std::string token_piece(const llama_vocab * vocab, llama_token token) {
    char local[256];
    int32_t count = llama_token_to_piece(vocab, token, local, sizeof(local), 0, true);
    if (count >= 0) {
        return std::string(local, static_cast<size_t>(count));
    }

    std::vector<char> dynamic(static_cast<size_t>(-count));
    count = llama_token_to_piece(
        vocab, token, dynamic.data(), static_cast<int32_t>(dynamic.size()), 0, true);
    return count > 0 ? std::string(dynamic.data(), static_cast<size_t>(count)) : std::string();
}

std::string strip_grounding_annotations(std::string text) {
    constexpr const char * ref_begin = "<|ref|>";
    constexpr const char * det_end = "<|/det|>";
    while (true) {
        const size_t begin = text.find(ref_begin);
        if (begin == std::string::npos) {
            break;
        }
        const size_t end = text.find(det_end, begin);
        if (end == std::string::npos) {
            break;
        }
        text.erase(begin, end + std::strlen(det_end) - begin);
    }
    while (!text.empty() && text.front() == '\n') {
        text.erase(text.begin());
    }
    size_t excessive_break = 0;
    while ((excessive_break = text.find("\n\n\n", excessive_break)) != std::string::npos) {
        text.erase(excessive_break, 1);
    }
    return text;
}

std::string visible_sampling_prefix(const std::string & generated) {
    constexpr const char * ref_begin = "<|ref|>";
    constexpr const char * det_end = "<|/det|>";
    if (generated.find(ref_begin) != std::string::npos
        && generated.find(det_end) == std::string::npos) {
        return {};
    }
    return strip_grounding_annotations(generated);
}

// DeepSeek-OCR-2's reference runner uses greedy decoding plus a custom
// 20-token no-repeat rule over the last 90 generated tokens. Unlike a generic
// repetition penalty, this leaves legitimate repeated math/table syntax alone.
void apply_reference_no_repeat_ngram(
    llama_context * context,
    const std::vector<llama_token> & generated_tokens
) {
    constexpr size_t ngram_size = 20;
    constexpr size_t window_size = 90;
    constexpr llama_token td_begin = 128821;
    constexpr llama_token td_end = 128822;

    if (generated_tokens.size() < ngram_size) {
        return;
    }

    const size_t current_prefix = generated_tokens.size() - (ngram_size - 1);
    const size_t search_start = generated_tokens.size() > window_size
        ? generated_tokens.size() - window_size
        : 0;
    const size_t search_end = generated_tokens.size() - ngram_size + 1;
    float * logits = nullptr;

    for (size_t start = search_start; start < search_end; ++start) {
        if (!std::equal(
                generated_tokens.begin() + static_cast<std::ptrdiff_t>(start),
                generated_tokens.begin() + static_cast<std::ptrdiff_t>(start + ngram_size - 1),
                generated_tokens.begin() + static_cast<std::ptrdiff_t>(current_prefix))) {
            continue;
        }

        const llama_token banned = generated_tokens[start + ngram_size - 1];
        if (banned == td_begin || banned == td_end || banned < 0) {
            continue;
        }
        if (logits == nullptr) {
            logits = llama_get_logits_ith(context, -1);
            if (logits == nullptr) {
                return;
            }
        }
        logits[banned] = -std::numeric_limits<float>::infinity();
    }
}

// Q4 quantization can occasionally fall into a much shorter loop before the
// reference 20-gram rule has enough history to react. Break only 1-4 token
// cycles that have already repeated four times; the threshold deliberately
// permits normal braces, delimiters, matrix cells, and prose repetition.
void apply_quantized_short_cycle_guard(
    llama_context * context,
    const std::vector<llama_token> & generated_tokens
) {
    constexpr size_t repeat_count = 4;
    constexpr size_t max_period = 4;
    constexpr llama_token td_begin = 128821;
    constexpr llama_token td_end = 128822;

    for (size_t period = 1; period <= max_period; ++period) {
        const size_t span = period * repeat_count;
        if (generated_tokens.size() < span) {
            continue;
        }

        const size_t begin = generated_tokens.size() - span;
        bool repeats = true;
        for (size_t index = begin + period; index < generated_tokens.size(); ++index) {
            if (generated_tokens[index] != generated_tokens[index - period]) {
                repeats = false;
                break;
            }
        }
        if (!repeats) {
            continue;
        }

        const llama_token banned = generated_tokens[generated_tokens.size() - period];
        if (banned == td_begin || banned == td_end || banned < 0) {
            return;
        }
        if (float * logits = llama_get_logits_ith(context, -1)) {
            logits[banned] = -std::numeric_limits<float>::infinity();
        }
        return;
    }
}

struct VisionEvaluationPlan {
    std::vector<const mtmd_input_chunk *> chunks;
    size_t input_tokens = 0;
    bool use_fast_path = false;
};

VisionEvaluationPlan make_vision_evaluation_plan(
    const mtmd_input_chunks * chunks,
    int32_t requested_mode
) {
    VisionEvaluationPlan plan;
    if (requested_mode != DSOCR_VISION_MODE_FAST) {
        return plan;
    }

    // DeepSeek-OCR-2 emits one 257-token 1024px overview and zero or more
    // 144-token 768px detail crops. Select the overview through b10236's
    // public chunk API. If a future model changes that invariant, fall back to
    // the complete accurate path instead of silently dropping image content.
    size_t overview_count = 0;
    bool recognized_layout = true;
    const size_t count = mtmd_input_chunks_size(chunks);
    plan.chunks.reserve(count);

    for (size_t index = 0; index < count; ++index) {
        const mtmd_input_chunk * chunk = mtmd_input_chunks_get(chunks, index);
        if (chunk == nullptr) {
            recognized_layout = false;
            break;
        }

        const mtmd_input_chunk_type type = mtmd_input_chunk_get_type(chunk);
        const size_t token_count = mtmd_input_chunk_get_n_tokens(chunk);
        if (type == MTMD_INPUT_CHUNK_TYPE_IMAGE) {
            if (token_count == 257) {
                ++overview_count;
                plan.chunks.push_back(chunk);
                plan.input_tokens += token_count;
            } else if (token_count != 144) {
                recognized_layout = false;
                break;
            }
        } else if (type == MTMD_INPUT_CHUNK_TYPE_TEXT) {
            plan.chunks.push_back(chunk);
            plan.input_tokens += token_count;
        } else {
            recognized_layout = false;
            break;
        }
    }

    plan.use_fast_path = recognized_layout
        && overview_count == 1
        && !plan.chunks.empty();
    if (!plan.use_fast_path) {
        plan.chunks.clear();
        plan.input_tokens = 0;
    }
    return plan;
}

} // namespace

struct DSOCRContext {
    llama_model * model = nullptr;
    llama_context * text_context = nullptr;
    const llama_vocab * vocab = nullptr;
    mtmd_context * vision_context = nullptr;
    llama_sampler * sampler = nullptr;
    llama_sampler * startup_sampler = nullptr;
    int32_t batch_size = 512;
    double load_seconds = 0;
    std::atomic<bool> cancelled = false;
    std::mutex inference_mutex;
};

namespace {

void free_context_resources(DSOCRContext * context) {
    if (context == nullptr) return;
    if (context->vision_context != nullptr) mtmd_free(context->vision_context);
    if (context->startup_sampler != nullptr) llama_sampler_free(context->startup_sampler);
    if (context->sampler != nullptr) llama_sampler_free(context->sampler);
    if (context->text_context != nullptr) llama_free(context->text_context);
    if (context->model != nullptr) llama_model_free(context->model);
}

void destroy_context_unlocked(DSOCRContext * context) {
    free_context_resources(context);
    delete context;
}

DSOCRContext * dsocr_create_impl(
    const char * model_path,
    const char * mmproj_path,
    int32_t context_size,
    int32_t thread_count,
    char * error_buffer,
    size_t error_buffer_size
) {

    clear_captured_log();
    if (model_path == nullptr || mmproj_path == nullptr) {
        write_error(error_buffer, error_buffer_size, "Model paths are missing.");
        return nullptr;
    }

    std::call_once(backend_once, [] {
        llama_backend_init();
        llama_log_set(quiet_log_callback, nullptr);
        mtmd_helper_log_set(quiet_log_callback, nullptr);
    });

    std::unique_ptr<DSOCRContext, decltype(&destroy_context_unlocked)> result(
        new DSOCRContext(), destroy_context_unlocked);
    const auto load_start = Clock::now();
    const int threads = thread_count > 0
        ? thread_count
        : std::max(2u, std::thread::hardware_concurrency() / 2);

    llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = use_metal ? -1 : 0;
    model_params.load_mode = LLAMA_LOAD_MODE_MMAP;
    // Runtime CPU repacking duplicates about 1.5 GiB of weights and can exceed
    // the simulator process limit. Real devices use Metal and do not need this
    // fallback; keep the simulator path memory-mapped and unrepacked.
    model_params.use_extra_bufts = use_metal;
    result->model = llama_model_load_from_file(model_path, model_params);
    if (result->model == nullptr) {
        write_error(error_buffer, error_buffer_size, "Unable to load DeepSeek text model.\n" + captured_log());
        return nullptr;
    }

    llama_context_params context_params = llama_context_default_params();
    context_params.n_ctx = static_cast<uint32_t>(std::max(2048, context_size));
    context_params.n_batch = static_cast<uint32_t>(result->batch_size);
    context_params.n_ubatch = 256;
    context_params.n_threads = threads;
    context_params.n_threads_batch = threads;
    context_params.flash_attn_type = use_metal
        ? LLAMA_FLASH_ATTN_TYPE_ENABLED
        : LLAMA_FLASH_ATTN_TYPE_DISABLED;
    context_params.offload_kqv = use_metal;
    context_params.type_k = GGML_TYPE_Q8_0;
    context_params.type_v = GGML_TYPE_Q8_0;
    result->text_context = llama_init_from_model(result->model, context_params);
    if (result->text_context == nullptr) {
        write_error(error_buffer, error_buffer_size, "Unable to create the text inference context.\n" + captured_log());
        return nullptr;
    }

    result->vocab = llama_model_get_vocab(result->model);
    result->sampler = llama_sampler_init_greedy();
    if (result->sampler == nullptr) {
        write_error(error_buffer, error_buffer_size, "Unable to create the OCR sampler.");
        return nullptr;
    }
    // The mobile Q4 model can loop in the title before the official 20-gram
    // rule activates. A conservative sampler is available only for a bounded
    // opening prefix; generation switches to the exact reference path as soon
    // as math or table markup begins.
    result->startup_sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (result->startup_sampler == nullptr) {
        write_error(error_buffer, error_buffer_size, "Unable to create the OCR startup sampler.");
        return nullptr;
    }
    llama_sampler_chain_add(
        result->startup_sampler,
        llama_sampler_init_penalties(90, 1.05f, 0.0f, 0.0f));
    llama_sampler_chain_add(
        result->startup_sampler,
        llama_sampler_init_dry(
            result->vocab,
            llama_model_n_ctx_train(result->model),
            0.8f,
            1.75f,
            5,
            90,
            nullptr,
            0));
    llama_sampler_chain_add(result->startup_sampler, llama_sampler_init_greedy());

    mtmd_context_params vision_params = mtmd_context_params_default();
    vision_params.use_gpu = use_metal;
    vision_params.print_timings = false;
    vision_params.n_threads = threads;
    vision_params.flash_attn_type = use_vision_flash_attention()
        ? LLAMA_FLASH_ATTN_TYPE_ENABLED
        : LLAMA_FLASH_ATTN_TYPE_DISABLED;
    vision_params.warmup = false;
    vision_params.batch_max_tokens = 1024;
    result->vision_context = mtmd_init_from_file(mmproj_path, result->model, vision_params);
    if (result->vision_context == nullptr || !mtmd_support_vision(result->vision_context)) {
        write_error(error_buffer, error_buffer_size, "Unable to load the DeepSeek vision encoder.\n" + captured_log());
        return nullptr;
    }

    result->load_seconds = elapsed_seconds(load_start);
    write_error(error_buffer, error_buffer_size, "");
    return result.release();
}

int32_t dsocr_recognize_impl(

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
) {
    if (context == nullptr || image_bytes == nullptr || image_length == 0 || output_text == nullptr) {
        write_error(error_buffer, error_buffer_size, "Invalid OCR request.");
        return 1;
    }

    std::lock_guard<std::mutex> inference_lock(context->inference_mutex);
    clear_captured_log();
    *output_text = nullptr;
    if (metrics != nullptr) {
        *metrics = DSOCRMetrics{context->load_seconds, 0, 0, 0, 0, false, false};
    }
    if (context->cancelled.load()) {
        write_error(error_buffer, error_buffer_size, "OCR was cancelled.");
        return 8;
    }

    llama_memory_clear(llama_get_memory(context->text_context), true);
    llama_sampler_reset(context->sampler);
    llama_sampler_reset(context->startup_sampler);

    const std::string instruction = prompt != nullptr
        ? prompt
        : "<|grounding|>Convert the document to markdown.";
    const std::string user_content = std::string(mtmd_default_marker()) + "\n" + instruction;
    const std::string formatted = format_prompt(context->model, user_content);
    if (formatted.empty()) {
        write_error(error_buffer, error_buffer_size, "Unable to format the DeepSeek OCR prompt.");
        return 3;
    }

    mtmd_helper_bitmap_wrapper wrapper = mtmd_helper_bitmap_init_from_buf(
        context->vision_context, image_bytes, image_length, false);
    if (wrapper.bitmap == nullptr) {
        write_error(error_buffer, error_buffer_size, "The selected image could not be decoded. Use PNG or JPEG.\n" + captured_log());
        return 2;
    }

    std::unique_ptr<mtmd_input_chunks, decltype(&mtmd_input_chunks_free)> chunks(
        mtmd_input_chunks_init(), mtmd_input_chunks_free);
    if (chunks == nullptr) {
        mtmd_bitmap_free(wrapper.bitmap);
        if (wrapper.video_ctx != nullptr) mtmd_helper_video_free(wrapper.video_ctx);
        write_error(error_buffer, error_buffer_size, "Unable to allocate image preprocessing state.");
        return 4;
    }
    const mtmd_bitmap * bitmaps[] = {wrapper.bitmap};
    const mtmd_input_text text = {
        formatted.data(), formatted.size(), true, true
    };

    int32_t status = mtmd_tokenize(context->vision_context, chunks.get(), &text, bitmaps, 1);
    if (status != 0) {
        mtmd_bitmap_free(wrapper.bitmap);
        if (wrapper.video_ctx != nullptr) mtmd_helper_video_free(wrapper.video_ctx);
        write_error(error_buffer, error_buffer_size, "Unable to preprocess the image (mtmd status " + std::to_string(status) + ").\n" + captured_log());
        return 4;
    }

    // Tokenization owns the preprocessed image chunks. The decoded source
    // bitmap is no longer needed during the much longer vision evaluation.
    mtmd_bitmap_free(wrapper.bitmap);
    if (wrapper.video_ctx != nullptr) mtmd_helper_video_free(wrapper.video_ctx);

    const auto encode_start = Clock::now();
    llama_pos new_past = 0;
    const VisionEvaluationPlan vision_plan = make_vision_evaluation_plan(
        chunks.get(), vision_mode);
    if (vision_plan.use_fast_path) {
        llama_pos n_past = 0;
        for (size_t index = 0; index < vision_plan.chunks.size(); ++index) {
            status = mtmd_helper_eval_chunk_single(
                context->vision_context,
                context->text_context,
                vision_plan.chunks[index],
                n_past,
                0,
                context->batch_size,
                index + 1 == vision_plan.chunks.size(),
                &new_past);
            if (status != 0) {
                break;
            }
            n_past = new_past;
        }
    } else {
        status = mtmd_helper_eval_chunks(
            context->vision_context,
            context->text_context,
            chunks.get(),
            0,
            0,
            context->batch_size,
            true,
            &new_past);
    }
    if (status == 0) {
        llama_synchronize(context->text_context);
    }
    const double encode_seconds = elapsed_seconds(encode_start);

    if (metrics != nullptr) {
        metrics->encode_seconds = encode_seconds;
        const size_t input_tokens = vision_plan.use_fast_path
            ? vision_plan.input_tokens
            : mtmd_helper_get_n_tokens(chunks.get());
        metrics->input_tokens = static_cast<int32_t>(input_tokens);
        metrics->fast_vision_used = vision_plan.use_fast_path;
    }

    chunks.reset();

    if (status != 0) {
        write_error(error_buffer, error_buffer_size, "Image encoding failed (status " + std::to_string(status) + ").\n" + captured_log());
        return 5;
    }

    const auto generation_start = Clock::now();
    std::string generated;
    std::vector<llama_token> token_history;
    token_history.reserve(static_cast<size_t>(std::max(1, max_output_tokens)));
    bool reached_eog = false;
    const int64_t context_remaining_wide =
        static_cast<int64_t>(llama_n_ctx(context->text_context))
        - static_cast<int64_t>(new_past)
        - 4;
    if (context_remaining_wide <= 0) {
        if (metrics != nullptr) {
            metrics->output_truncated = true;
        }
        write_error(error_buffer, error_buffer_size, "The image prompt exhausted the model context window.");
        return 9;
    }
    const int32_t context_remaining = static_cast<int32_t>(std::min<int64_t>(
        context_remaining_wide,
        std::numeric_limits<int32_t>::max()));
    const int32_t token_limit = std::min(
        std::max(1, max_output_tokens),
        context_remaining);

    for (int32_t index = 0; index < token_limit && !context->cancelled.load(); ++index) {
        apply_reference_no_repeat_ngram(context->text_context, token_history);
        const std::string visible_prefix = visible_sampling_prefix(generated);
        const bool startup_phase = visible_prefix.size() < 96
            && visible_prefix.find('\\') == std::string::npos
            && visible_prefix.find('$') == std::string::npos
            && visible_prefix.find("<table") == std::string::npos
            && visible_prefix.find("<td") == std::string::npos;
        if (startup_phase) {
            apply_quantized_short_cycle_guard(context->text_context, token_history);
        }
        llama_sampler * active_sampler = startup_phase
            ? context->startup_sampler
            : context->sampler;
        const llama_token token = llama_sampler_sample(active_sampler, context->text_context, -1);
        if (llama_vocab_is_eog(context->vocab, token)) {
            reached_eog = true;
            break;
        }

        generated += token_piece(context->vocab, token);
        token_history.push_back(token);

        // The final capped token has no successor to sample, so avoid decoding
        // it only to throw its logits away.
        if (index + 1 >= token_limit) {
            continue;
        }

        llama_token next = token;
        const llama_batch batch = llama_batch_get_one(&next, 1);
        status = llama_decode(context->text_context, batch);
        if (status != 0) {
            write_error(error_buffer, error_buffer_size, "Text generation failed (status " + std::to_string(status) + ").\n" + captured_log());
            return 6;
        }
    }

    if (metrics != nullptr) {
        metrics->generation_seconds = elapsed_seconds(generation_start);
        metrics->output_tokens = static_cast<int32_t>(token_history.size());
        metrics->output_truncated = !context->cancelled.load()
            && !reached_eog
            && static_cast<int32_t>(token_history.size()) >= token_limit;
    }

    if (context->cancelled.load()) {
        write_error(error_buffer, error_buffer_size, "OCR was cancelled.");
        return 8;
    }

    generated = strip_grounding_annotations(std::move(generated));

    char * result = static_cast<char *>(std::malloc(generated.size() + 1));
    if (result == nullptr) {
        write_error(error_buffer, error_buffer_size, "Unable to allocate OCR output.");
        return 7;
    }
    std::memcpy(result, generated.data(), generated.size());
    result[generated.size()] = '\0';
    *output_text = result;
    write_error(error_buffer, error_buffer_size, "");
    return 0;
}

} // namespace

int32_t dsocr_recommended_vision_mode(void) {
    return has_apple_m_series_gpu()
        ? DSOCR_VISION_MODE_FAST
        : DSOCR_VISION_MODE_ACCURATE;
}

DSOCRContext * dsocr_create(
    const char * model_path,
    const char * mmproj_path,
    int32_t context_size,
    int32_t thread_count,
    char * error_buffer,
    size_t error_buffer_size
) {
    try {
        return dsocr_create_impl(
            model_path,
            mmproj_path,
            context_size,
            thread_count,
            error_buffer,
            error_buffer_size);
    } catch (const std::exception & exception) {
        try { write_error(error_buffer, error_buffer_size, exception.what()); } catch (...) {}
        return nullptr;
    } catch (...) {
        try { write_error(error_buffer, error_buffer_size, "Unexpected native error while loading DeepSeek OCR."); } catch (...) {}
        return nullptr;
    }
}

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
) {
    return dsocr_recognize_with_vision_mode(
        context,
        image_bytes,
        image_length,
        prompt,
        max_output_tokens,
        DSOCR_VISION_MODE_ACCURATE,
        output_text,
        metrics,
        error_buffer,
        error_buffer_size);
}

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
) {
    try {
        return dsocr_recognize_impl(
            context,
            image_bytes,
            image_length,
            prompt,
            max_output_tokens,
            vision_mode,
            output_text,
            metrics,
            error_buffer,
            error_buffer_size);
    } catch (const std::exception & exception) {
        if (output_text != nullptr) *output_text = nullptr;
        try { write_error(error_buffer, error_buffer_size, exception.what()); } catch (...) {}
        return 10;
    } catch (...) {
        if (output_text != nullptr) *output_text = nullptr;
        try { write_error(error_buffer, error_buffer_size, "Unexpected native error during OCR."); } catch (...) {}
        return 10;
    }
}

void dsocr_cancel(DSOCRContext * context) {
    if (context != nullptr) {
        context->cancelled.store(true);
    }
}

void dsocr_reset_cancel(DSOCRContext * context) {
    if (context != nullptr) {
        context->cancelled.store(false);
    }
}

void dsocr_destroy(DSOCRContext * context) {
    if (context == nullptr) return;
    context->cancelled.store(true);
    {
        std::lock_guard<std::mutex> inference_lock(context->inference_mutex);
        free_context_resources(context);
    }
    delete context;
}

void dsocr_string_free(char * value) {
    std::free(value);
}
