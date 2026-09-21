#include <cuda_runtime.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    const cudaError_t status = (call);                                           \
    if (status != cudaSuccess) {                                                 \
      std::fprintf(stderr, "%s failed: %s\n", #call, cudaGetErrorString(status)); \
      return 1;                                                                 \
    }                                                                           \
  } while (0)

__global__ void add_vectors(const float *left, const float *right, float *out,
                            int count) {
  const int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index < count) {
    out[index] = left[index] + right[index];
  }
}

int main() {
  constexpr int count = 4096;
  constexpr std::size_t bytes = count * sizeof(float);

  int runtime_version = 0;
  int driver_version = 0;
  CUDA_CHECK(cudaRuntimeGetVersion(&runtime_version));
  CUDA_CHECK(cudaDriverGetVersion(&driver_version));

  cudaDeviceProp properties{};
  CUDA_CHECK(cudaGetDeviceProperties(&properties, 0));
  if (properties.major != 12 || properties.minor != 1) {
    std::fprintf(stderr, "expected compute capability 12.1, found %d.%d\n",
                 properties.major, properties.minor);
    return 1;
  }

  std::vector<float> left(count);
  std::vector<float> right(count);
  std::vector<float> output(count);
  for (int index = 0; index < count; ++index) {
    left[index] = static_cast<float>(index) * 0.25F;
    right[index] = static_cast<float>(count - index) * 0.5F;
  }

  float *device_left = nullptr;
  float *device_right = nullptr;
  float *device_output = nullptr;
  CUDA_CHECK(cudaMalloc(&device_left, bytes));
  CUDA_CHECK(cudaMalloc(&device_right, bytes));
  CUDA_CHECK(cudaMalloc(&device_output, bytes));
  CUDA_CHECK(cudaMemcpy(device_left, left.data(), bytes, cudaMemcpyHostToDevice));
  CUDA_CHECK(cudaMemcpy(device_right, right.data(), bytes, cudaMemcpyHostToDevice));

  add_vectors<<<(count + 255) / 256, 256>>>(device_left, device_right,
                                             device_output, count);
  CUDA_CHECK(cudaGetLastError());
  CUDA_CHECK(cudaDeviceSynchronize());
  CUDA_CHECK(cudaMemcpy(output.data(), device_output, bytes, cudaMemcpyDeviceToHost));

  double checksum = 0.0;
  double maximum_error = 0.0;
  for (int index = 0; index < count; ++index) {
    const double expected = static_cast<double>(left[index] + right[index]);
    maximum_error = std::max(maximum_error, std::abs(output[index] - expected));
    checksum += output[index];
  }

  CUDA_CHECK(cudaFree(device_left));
  CUDA_CHECK(cudaFree(device_right));
  CUDA_CHECK(cudaFree(device_output));
  if (maximum_error != 0.0) {
    std::fprintf(stderr, "vector result mismatch: %.9g\n", maximum_error);
    return 1;
  }

  std::printf(
      "{\"status\":\"pass\",\"device\":{\"name\":\"%s\","
      "\"compute_capability\":\"%d.%d\"},\"cuda\":{\"driver_version\":%d,"
      "\"runtime_version\":%d},\"workload\":{\"elements\":%d,"
      "\"checksum\":%.9g,\"maximum_error\":%.9g}}\n",
      properties.name, properties.major, properties.minor, driver_version,
      runtime_version, count, checksum, maximum_error);
  return 0;
}
