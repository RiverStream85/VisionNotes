#include "DeepSeekOCRBridge.h"

#include <cstdint>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>

namespace {

std::vector<uint8_t> read_file(const char * path) {
    std::ifstream input(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}

} // namespace

int main(int argc, char ** argv) {
    if (argc != 4 && argc != 5) {
        std::cerr << "usage: bridge-smoke TEXT_MODEL VISION_MODEL IMAGE [--fast]\n";
        return 64;
    }
    const bool fast = argc == 5 && std::string(argv[4]) == "--fast";
    if (argc == 5 && !fast) {
        std::cerr << "unknown option: " << argv[4] << "\n";
        return 64;
    }

    char error[8192] = {};
    DSOCRContext * context = dsocr_create(argv[1], argv[2], 4096, 4, error, sizeof(error));
    if (context == nullptr) {
        std::cerr << "load failed: " << error << "\n";
        return 1;
    }

    const std::vector<uint8_t> image = read_file(argv[3]);
    char * output = nullptr;
    DSOCRMetrics metrics = {};
    dsocr_reset_cancel(context);
    const int32_t status = dsocr_recognize_with_vision_mode(
        context,
        image.data(),
        image.size(),
        "<|grounding|>Convert the document to markdown.",
        2048,
        fast ? DSOCR_VISION_MODE_FAST : DSOCR_VISION_MODE_ACCURATE,
        &output,
        &metrics,
        error,
        sizeof(error));

    if (status != 0) {
        std::cerr << "recognition failed (" << status << "): " << error << "\n";
        dsocr_destroy(context);
        return 2;
    }

    std::cout << output << "\n\n"
              << "[mode=" << (fast ? "fast" : "accurate")
              << " load=" << metrics.model_load_seconds
              << "s encode=" << metrics.encode_seconds
              << "s generate=" << metrics.generation_seconds
              << "s input=" << metrics.input_tokens
              << " output=" << metrics.output_tokens << "]\n";

    dsocr_string_free(output);
    dsocr_destroy(context);
    return 0;
}
