#include <metal_stdlib>
using namespace metal;

struct FirebirdParameters {
    uint hiddenSize;
    uint step;
    uint maximumSequenceLength;
    float epsilon;
};

/// A single-token Firebird decoder kernel. This is deliberately not a wrapper
/// around MPS/GEMM: RMSNorm, the Q/K/V matrix-vector products, RoPE, KV-cache
/// update, attention softmax, and the attention-value GEMM are fused into this
/// one GPU dispatch.
kernel void firebird_fused_decode(
    device const float *input                 [[buffer(0)]],
    device const float *qkvWeight             [[buffer(1)]],
    device const float *rmsWeight             [[buffer(2)]],
    device float *keyCache                    [[buffer(3)]],
    device float *valueCache                  [[buffer(4)]],
    device float *output                      [[buffer(5)]],
    constant FirebirdParameters &parameters   [[buffer(6)]],
    uint lane                                 [[thread_index_in_threadgroup]]) {

    threadgroup float normalized[64];
    threadgroup float query[64];
    threadgroup float key[64];
    threadgroup float value[64];
    threadgroup float probabilities[256];
    threadgroup float inverseRMS;

    const uint hidden = min(parameters.hiddenSize, 64u);
    const uint step = min(parameters.step, parameters.maximumSequenceLength - 1);

    if (lane == 0) {
        float sumSquares = 0.0f;
        for (uint index = 0; index < hidden; ++index) {
            sumSquares += input[index] * input[index];
        }
        inverseRMS = rsqrt(sumSquares / float(hidden) + parameters.epsilon);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (lane < hidden) {
        normalized[lane] = input[lane] * inverseRMS * rmsWeight[lane];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (lane < hidden) {
        float q = 0.0f;
        float k = 0.0f;
        float v = 0.0f;
        const uint matrixSize = hidden * hidden;
        const uint row = lane * hidden;
        for (uint column = 0; column < hidden; ++column) {
            const float x = normalized[column];
            q += qkvWeight[row + column] * x;
            k += qkvWeight[matrixSize + row + column] * x;
            v += qkvWeight[2 * matrixSize + row + column] * x;
        }
        query[lane] = q;
        key[lane] = k;
        value[lane] = v;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (lane < hidden / 2) {
        const uint even = lane * 2;
        const uint odd = even + 1;
        const float frequency = pow(10000.0f, -float(even) / float(hidden));
        const float angle = float(step) * frequency;
        const float cosine = cos(angle);
        const float sine = sin(angle);
        const float qEven = query[even];
        const float qOdd = query[odd];
        const float kEven = key[even];
        const float kOdd = key[odd];
        query[even] = qEven * cosine - qOdd * sine;
        query[odd] = qEven * sine + qOdd * cosine;
        key[even] = kEven * cosine - kOdd * sine;
        key[odd] = kEven * sine + kOdd * cosine;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (lane < hidden) {
        keyCache[step * hidden + lane] = key[lane];
        valueCache[step * hidden + lane] = value[lane];
    }
    threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup);

    if (lane == 0) {
        float maximum = -INFINITY;
        const float scale = rsqrt(float(hidden));
        for (uint position = 0; position <= step; ++position) {
            float score = 0.0f;
            for (uint channel = 0; channel < hidden; ++channel) {
                score += query[channel] * keyCache[position * hidden + channel];
            }
            probabilities[position] = score * scale;
            maximum = max(maximum, probabilities[position]);
        }
        float denominator = 0.0f;
        for (uint position = 0; position <= step; ++position) {
            probabilities[position] = exp(probabilities[position] - maximum);
            denominator += probabilities[position];
        }
        for (uint position = 0; position <= step; ++position) {
            probabilities[position] /= max(denominator, 1.0e-8f);
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (lane < hidden) {
        float attended = 0.0f;
        for (uint position = 0; position <= step; ++position) {
            attended += probabilities[position] * valueCache[position * hidden + lane];
        }
        output[lane] = attended;
    }
}
