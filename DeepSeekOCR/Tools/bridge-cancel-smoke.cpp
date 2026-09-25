#include "DeepSeekOCRBridge.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <iterator>
#include <thread>
#include <vector>

namespace {

std::vector<uint8_t> read_file(const char * path) {
    std::ifstream input(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}

} // namespace

int main(int argc, char ** argv) {
    if (argc != 4) {
        std::cerr << "usage: bridge-cancel-smoke TEXT_MODEL VISION_MODEL IMAGE\n";
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
    std::atomic<int32_t> status{-1};
    dsocr_reset_cancel(context);

    std::thread worker([&] {
        status.store(dsocr_recognize(
            context,
            image.data(),
            image.size(),
            "<|grounding|>Convert the document to markdown.",
            2048,
            &output,
            &metrics,
            error,
            sizeof(error)));
    });

    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    dsocr_cancel(context);
    worker.join();

    if (output != nullptr) {
        dsocr_string_free(output);
        std::cerr << "cancelled request unexpectedly allocated output\n";
        dsocr_destroy(context);
        return 2;
    }
    if (status.load() != 8) {
        std::cerr << "expected cancellation status 8, got " << status.load()
                  << ": " << error << "\n";
        dsocr_destroy(context);
        return 3;
    }

    std::cout << "Native cancellation smoke test passed.\n";
    dsocr_destroy(context);
    return 0;
}
