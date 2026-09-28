#ifndef NAZZEL_PYBRIDGE_H
#define NAZZEL_PYBRIDGE_H

// Plain C interface to the embedded Python interpreter.
// Swift never sees Python types; it passes JSON text in and gets JSON text back.

#ifdef __cplusplus
extern "C" {
#endif

/// Starts Python and imports `nazzel_engine`. Safe to call once, off the main thread.
/// Returns 0 on success. On failure `error_out` receives a malloc'd message (free with nz_python_free).
int nz_python_start(const char *resource_path, const char *pycache_path, char **error_out);

/// Calls nazzel_engine.call(name, json_args). Thread-safe (takes the GIL).
/// Always returns a malloc'd JSON string; free it with nz_python_free.
char *nz_python_call(const char *name, const char *json_args);

void nz_python_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif
