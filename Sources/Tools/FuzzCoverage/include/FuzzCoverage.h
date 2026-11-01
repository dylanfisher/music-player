#ifndef FUZZ_COVERAGE_H
#define FUZZ_COVERAGE_H

#include <stddef.h>
#include <stdint.h>

/// The SanitizerCoverage callbacks for the fuzzer (ADR 0027), and the crash handler that keeps
/// the input being run.
///
/// Code built with `-sanitize-coverage=edge,trace-pc-guard` calls these for every edge it takes.
/// The driver clears the counts before an input, runs it, and then asks which (edge, hit-count
/// bucket) pairs it saw for the first time. Without that flag nothing calls them, and every
/// input reports no features.

/// The edges instrumented so far.
size_t FuzzCoverageEdgeCount(void);

/// Clears the hit counts left by whatever ran since the last call.
void FuzzCoverageClear(void);

/// Counts the (edge, bucket) pairs hit since the last clear that no earlier input hit, and clears
/// the counts. With `keep`, the pairs join the set seen; without it, the set is left as it was.
size_t FuzzCoverageNewFeatures(int keep);

/// Every (edge, bucket) pair seen so far.
size_t FuzzCoverageFeatureCount(void);

/// Installs the crash handler for the signals a crash, a Swift trap or a timeout raises, and as
/// ASan's death callback. A crash while an input runs writes it to `path`; a crash at any other
/// time writes nothing. Returns 0, or ENAMETOOLONG.
int FuzzCoverageInstallCrashHandler(const char *path);

/// The input about to run, which the crash handler writes. The bytes must stay alive until
/// `FuzzCoverageEndInput`.
void FuzzCoverageBeginInput(const uint8_t *bytes, size_t count);
void FuzzCoverageEndInput(void);

/// Arms a timer that raises SIGALRM after `seconds`, or disarms it with 0.
void FuzzCoverageSetTimeout(unsigned seconds);

/// Test hooks: the callbacks the compiler emits, for tests that run without the flag.
void FuzzCoverageTestInit(uint32_t *start, uint32_t *stop);
void FuzzCoverageTestHit(uint32_t *guard);

#endif
