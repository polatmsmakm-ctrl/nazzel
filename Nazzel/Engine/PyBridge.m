// Embeds CPython (BeeWare / CPython iOS XCframework) following
// https://docs.python.org/3/using/ios.html

#define PY_SSIZE_T_CLEAN
#include <Python/Python.h>

#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>
#include "PyBridge.h"

static PyObject *g_call = NULL;
static int g_ready = 0;

static char *nz_strdup(const char *s) {
    if (s == NULL) {
        s = "";
    }
    size_t n = strlen(s) + 1;
    char *p = malloc(n);
    if (p != NULL) {
        memcpy(p, s, n);
    }
    return p;
}

static char *nz_error_json(NSString *message) {
    NSDictionary *payload = @{@"ok": @NO, @"error": message ?: @"unknown error"};
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (data == nil) {
        return nz_strdup("{\"ok\":false,\"error\":\"unknown error\"}");
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return nz_strdup(text.UTF8String);
}

// Formats the current Python exception (caller holds the GIL) and clears it.
static NSString *nz_fetch_python_error(void) {
    PyObject *exc = PyErr_GetRaisedException();
    if (exc == NULL) {
        return @"unknown Python error";
    }
    NSString *result = nil;
    PyObject *tb_module = PyImport_ImportModule("traceback");
    if (tb_module != NULL) {
        PyObject *lines = PyObject_CallMethod(tb_module, "format_exception", "O", exc);
        if (lines != NULL) {
            PyObject *empty = PyUnicode_FromString("");
            PyObject *joined = empty ? PyUnicode_Join(empty, lines) : NULL;
            if (joined != NULL) {
                const char *utf8 = PyUnicode_AsUTF8(joined);
                if (utf8 != NULL) {
                    result = [NSString stringWithUTF8String:utf8];
                }
            }
            Py_XDECREF(joined);
            Py_XDECREF(empty);
            Py_DECREF(lines);
        }
        Py_DECREF(tb_module);
    }
    if (result == nil) {
        PyObject *text = PyObject_Str(exc);
        const char *utf8 = text ? PyUnicode_AsUTF8(text) : NULL;
        result = utf8 ? [NSString stringWithUTF8String:utf8] : @"unprintable Python error";
        Py_XDECREF(text);
    }
    PyErr_Clear();
    Py_DECREF(exc);
    return result;
}

static int nz_fail(char **error_out, NSString *message) {
    NSLog(@"[Nazzel] Python start failed: %@", message);
    if (error_out != NULL) {
        *error_out = nz_strdup(message.UTF8String);
    }
    return 1;
}

int nz_python_start(const char *resource_path, const char *pycache_path, char **error_out) {
    @autoreleasepool {
        if (g_ready) {
            return 0;
        }
        if (Py_IsInitialized()) {
            return nz_fail(error_out, @"Python was initialized but the engine failed to load earlier");
        }

        NSString *resources = [NSString stringWithUTF8String:resource_path];
        NSString *home = [resources stringByAppendingPathComponent:@"python"];
        NSString *appPath = [resources stringByAppendingPathComponent:@"app"];
        NSString *packagesPath = [resources stringByAppendingPathComponent:@"app_packages"];

        setenv("NO_COLOR", "1", 1);
        setenv("PYTHON_COLORS", "0", 1);

        PyStatus status;
        PyPreConfig preconfig;
        PyConfig config;

        PyPreConfig_InitIsolatedConfig(&preconfig);
        preconfig.utf8_mode = 1;
        status = Py_PreInitialize(&preconfig);
        if (PyStatus_Exception(status)) {
            return nz_fail(error_out, [NSString stringWithFormat:@"pre-initialize: %s", status.err_msg ?: "?"]);
        }

        PyConfig_InitIsolatedConfig(&config);
        config.use_system_logger = 1;
        config.buffered_stdio = 0;
        config.install_signal_handlers = 1;
        // The bundle is read-only; bytecode goes to Caches instead (faster next launch).
        config.write_bytecode = pycache_path != NULL ? 1 : 0;

        status = PyConfig_SetBytesString(&config, &config.home, home.fileSystemRepresentation);
        if (PyStatus_Exception(status)) {
            PyConfig_Clear(&config);
            return nz_fail(error_out, [NSString stringWithFormat:@"PYTHONHOME: %s", status.err_msg ?: "?"]);
        }
        if (pycache_path != NULL) {
            status = PyConfig_SetBytesString(&config, &config.pycache_prefix, pycache_path);
            if (PyStatus_Exception(status)) {
                PyConfig_Clear(&config);
                return nz_fail(error_out, [NSString stringWithFormat:@"pycache: %s", status.err_msg ?: "?"]);
            }
        }

        status = PyConfig_Read(&config);
        if (PyStatus_Exception(status)) {
            PyConfig_Clear(&config);
            return nz_fail(error_out, [NSString stringWithFormat:@"read config: %s", status.err_msg ?: "?"]);
        }

        status = Py_InitializeFromConfig(&config);
        PyConfig_Clear(&config);
        if (PyStatus_Exception(status)) {
            return nz_fail(error_out, [NSString stringWithFormat:@"initialize: %s", status.err_msg ?: "?"]);
        }

        NSString *failure = nil;

        // app_packages is a site dir (handles .pth files); app goes first on sys.path.
        PyObject *site = PyImport_ImportModule("site");
        if (site == NULL) {
            failure = nz_fetch_python_error();
        } else {
            PyObject *r = PyObject_CallMethod(site, "addsitedir", "s", packagesPath.fileSystemRepresentation);
            if (r == NULL) {
                failure = nz_fetch_python_error();
            }
            Py_XDECREF(r);
            Py_DECREF(site);
        }

        if (failure == nil) {
            PyObject *sysPath = PySys_GetObject("path");  // borrowed
            PyObject *appStr = PyUnicode_DecodeFSDefault(appPath.fileSystemRepresentation);
            if (sysPath == NULL || appStr == NULL || PyList_Insert(sysPath, 0, appStr) != 0) {
                failure = nz_fetch_python_error();
            }
            Py_XDECREF(appStr);
        }

        if (failure == nil) {
            PyObject *module = PyImport_ImportModule("nazzel_engine");
            if (module == NULL) {
                failure = nz_fetch_python_error();
            } else {
                g_call = PyObject_GetAttrString(module, "call");
                if (g_call == NULL) {
                    failure = nz_fetch_python_error();
                }
                Py_DECREF(module);
            }
        }

        // Release the GIL so any thread can call in with PyGILState_Ensure.
        PyEval_SaveThread();

        if (failure != nil) {
            return nz_fail(error_out, failure);
        }
        g_ready = 1;
        return 0;
    }
}

char *nz_python_call(const char *name, const char *json_args) {
    @autoreleasepool {
        if (!g_ready || g_call == NULL) {
            return nz_error_json(@"Python engine is not running");
        }
        PyGILState_STATE gil = PyGILState_Ensure();
        char *out = NULL;
        PyObject *result = PyObject_CallFunction(g_call, "ss", name, json_args ? json_args : "{}");
        if (result != NULL && PyUnicode_Check(result)) {
            const char *utf8 = PyUnicode_AsUTF8(result);
            if (utf8 != NULL) {
                out = nz_strdup(utf8);
            }
        }
        if (out == NULL) {
            NSString *message = PyErr_Occurred() ? nz_fetch_python_error() : @"engine returned no text";
            out = nz_error_json(message);
        }
        Py_XDECREF(result);
        PyGILState_Release(gil);
        return out;
    }
}

void nz_python_free(char *ptr) {
    free(ptr);
}
