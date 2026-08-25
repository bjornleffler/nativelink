// Minimal C++ target for verifying remote execution against NativeLink.
//
// Deliberately prints the compiler and target so the output confirms which
// toolchain actually ran. A remotely executed build reports the hermetic
// clang from the worker image, not whatever compiler is on your laptop -
// which is the whole point of checking.
#include <cstdio>

int main() {
  std::printf("hello from NativeLink remote execution\n");
#ifdef __clang_version__
  std::printf("compiled by clang %s\n", __clang_version__);
#elif defined(__GNUC__)
  std::printf("compiled by gcc %d.%d\n", __GNUC__, __GNUC_MINOR__);
#endif
  std::printf("target: %s\n",
#if defined(__x86_64__)
              "x86_64"
#elif defined(__aarch64__)
              "aarch64"
#else
              "unknown"
#endif
  );
  return 0;
}
