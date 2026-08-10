import Testing

/// Serialization boundary for every OMP test.
///
/// All four OMP suites launch a stub `omp` child process and assert against
/// short timeouts, marker files, and live pids. `.serialized` on an individual
/// suite orders only the tests *within* it, so four such suites running
/// concurrently starve each other's children and trip the very deadlines under
/// test. Nesting them under one serialized parent is the only mechanism Swift
/// Testing offers for "these suites must not overlap"; the trait is inherited by
/// every descendant, so each child suite keeps its own topic name and file.
///
/// Before the split these tests lived in one suite-wide `.serialized` monolith,
/// which is why the constraint was invisible.
@Suite("OMP", .serialized)
struct OmpSuites {}
