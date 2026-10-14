import Foundation

/// CPU time spent by `body` on the calling thread, in seconds.
///
/// For tests that guard an algorithm's cost ("this does not go quadratic"). Wall-clock time also
/// counts every moment the scheduler gave the core to someone else, so on a loaded machine it
/// measures the load, not the code. Thread CPU time stops while the thread is descheduled.
/// It does not follow work handed to another thread; for that use `processCPUSeconds`.
@discardableResult
func threadCPUSeconds(_ body: () throws -> Void) rethrows -> Double {
    let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    try body()
    return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9
}

/// CPU time spent by the whole process while `body` runs, in seconds. Includes any other
/// thread's work, so only use it where nothing unrelated runs concurrently in the process.
func processCPUSeconds(_ body: () async throws -> Void) async rethrows -> Double {
    let start = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
    try await body()
    return Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - start) / 1e9
}
