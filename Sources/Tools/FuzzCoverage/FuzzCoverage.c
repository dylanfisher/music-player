#include "FuzzCoverage.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

// One count per edge, by guard number. Guards past the table share slots, which only blurs
// coverage; the instrumented modules have far fewer edges.
#define MAXIMUM_EDGES (1u << 21)

static uint8_t counts[MAXIMUM_EDGES];
// A bit per hit-count bucket, per edge.
static uint8_t seen[MAXIMUM_EDGES];
static uint32_t nextGuard = 1;
static size_t featureCount;

static char crashPath[1024];
static volatile sig_atomic_t running;
static const uint8_t *volatile inputBytes;
static volatile size_t inputCount;

void __sanitizer_cov_trace_pc_guard_init(uint32_t *start, uint32_t *stop) {
    if (start == stop || *start != 0) return;
    for (uint32_t *guard = start; guard < stop; guard++) {
        *guard = nextGuard;
        if (nextGuard < MAXIMUM_EDGES - 1) nextGuard++;
    }
}

void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
    uint8_t *count = &counts[*guard];
    if (*count != UINT8_MAX) (*count)++;
}

void FuzzCoverageTestInit(uint32_t *start, uint32_t *stop) {
    __sanitizer_cov_trace_pc_guard_init(start, stop);
}

void FuzzCoverageTestHit(uint32_t *guard) { __sanitizer_cov_trace_pc_guard(guard); }

size_t FuzzCoverageEdgeCount(void) { return nextGuard - 1; }

void FuzzCoverageClear(void) { memset(counts, 0, nextGuard); }

// libFuzzer's buckets: 1, 2, 3, 4-7, 8-15, 16-31, 32-127, 128 and more.
static uint8_t bucket(uint8_t count) {
    if (count <= 3) return (uint8_t)(1u << (count - 1));
    if (count <= 7) return 1u << 3;
    if (count <= 15) return 1u << 4;
    if (count <= 31) return 1u << 5;
    if (count <= 127) return 1u << 6;
    return 1u << 7;
}

size_t FuzzCoverageNewFeatures(int keep) {
    size_t found = 0;
    for (uint32_t edge = 1; edge < nextGuard; edge++) {
        if (counts[edge] == 0) continue;
        uint8_t bit = bucket(counts[edge]);
        counts[edge] = 0;
        if (seen[edge] & bit) continue;
        found++;
        if (keep) seen[edge] |= bit;
    }
    featureCount += keep ? found : 0;
    return found;
}

size_t FuzzCoverageFeatureCount(void) { return featureCount; }

void FuzzCoverageBeginInput(const uint8_t *bytes, size_t count) {
    inputBytes = bytes;
    inputCount = count;
    running = 1;
}

void FuzzCoverageEndInput(void) { running = 0; }

void FuzzCoverageSetTimeout(unsigned seconds) {
    struct itimerval timer = {.it_value = {.tv_sec = seconds}};
    setitimer(ITIMER_REAL, &timer, NULL);
}

// Only async-signal-safe calls: the process is going down and may hold any lock.
static void writeInput(void) {
    if (!running || crashPath[0] == 0) return;
    running = 0;
    int crashFile = open(crashPath, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0644);
    if (crashFile < 0) return;
    const uint8_t *bytes = inputBytes;
    size_t left = inputCount;
    while (left > 0) {
        ssize_t written = write(crashFile, bytes, left);
        if (written <= 0) break;
        bytes += written;
        left -= (size_t)written;
    }
    fsync(crashFile);
    close(crashFile);
}

static void crashed(int signal) {
    writeInput();
    struct sigaction fallback = {.sa_handler = SIG_DFL};
    sigaction(signal, &fallback, NULL);
    raise(signal);
}

// Looked up at run time, so the tool also links in a build without ASan, where it's missing.
typedef void (*SetDeathCallback)(void (*callback)(void));

int FuzzCoverageInstallCrashHandler(const char *path) {
    if (strlcpy(crashPath, path, sizeof crashPath) >= sizeof crashPath) {
        crashPath[0] = 0;
        return ENAMETOOLONG;
    }
    // SIGSEGV and SIGBUS are left to ASan, which reports them and then calls the death callback;
    // without ASan they come here too.
    SetDeathCallback setDeathCallback =
        (SetDeathCallback)dlsym(RTLD_DEFAULT, "__sanitizer_set_death_callback");
    int signals[] = {SIGABRT, SIGTRAP, SIGILL, SIGFPE, SIGALRM, SIGSEGV, SIGBUS};
    for (size_t i = 0; i < sizeof signals / sizeof signals[0]; i++) {
        if (setDeathCallback != NULL && (signals[i] == SIGSEGV || signals[i] == SIGBUS)) continue;
        struct sigaction action = {.sa_handler = crashed};
        sigaction(signals[i], &action, NULL);
    }
    if (setDeathCallback != NULL) setDeathCallback(writeInput);
    return 0;
}
