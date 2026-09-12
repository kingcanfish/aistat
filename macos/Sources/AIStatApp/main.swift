import AIStatUI

// One line, so everything above it lives in a library target that the test
// target can import. Executable targets cannot be imported.
MainActor.assumeIsolated { AIStatRunner.main() }
