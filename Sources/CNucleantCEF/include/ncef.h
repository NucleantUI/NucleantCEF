//
//  ncef.h
//  NucleantCEF
//
//  A small C surface over CEF's C++ API, for Swift. CEF's own C API would do
//  in principle, but every handler there is a hand-refcounted struct of
//  function pointers; the C++ wrapper does that bookkeeping, and this layer
//  flattens what NucleantCEF uses of it into plain functions and one table of
//  callbacks per browser.
//
//  Every callback carries the `userdata` pointer the browser was created with
//  — on the Swift side an unretained `Unmanaged` pointer to the model that
//  owns the browser. All callbacks arrive on the main thread, from inside
//  `ncef_do_message_loop_work` (the external message pump).
//

#ifndef NCEF_H
#define NCEF_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Process

typedef struct ncef_settings {
    /// Absolute path of "Chromium Embedded Framework.framework".
    const char* framework_dir;
    /// Absolute path of the helper executable every sub-process runs.
    const char* helper_path;
    /// Absolute path of the main bundle — the app bundle, or for a bare
    /// executable the directory it sits in.
    const char* main_bundle_path;
    /// Absolute path for installation-wide data; must be unique per app.
    const char* root_cache_path;
    /// Profile data, a child of `root_cache_path` — NULL for an in-memory
    /// ("incognito") profile.
    const char* cache_path;
    /// `cef_log_severity_t`; 0 is CEF's default.
    int log_severity;
    /// NULL for CEF's default log file.
    const char* log_file;
    /// 0 disables remote debugging.
    int remote_debugging_port;
    /// `CefBrowserProcessHandler::OnScheduleMessagePumpWork`: call
    /// `ncef_do_message_loop_work` in `delay_ms` (0 or less: as soon as
    /// possible). Called from any thread.
    void (*schedule_message_pump_work)(int64_t delay_ms);
} ncef_settings;

/// Load the CEF framework from `framework_dir`. Must precede every other call.
/// Returns 1 on success.
int ncef_load_library(const char* framework_dir);

/// Initialize CEF's browser process with windowless rendering and the external
/// message pump. Returns 1 on success, 0 otherwise — `ncef_exit_code` says why.
int ncef_initialize(const ncef_settings* settings);
int ncef_exit_code(void);

/// One turn of CEF's message loop; call when `schedule_message_pump_work`
/// asks, and on a slow timer besides.
void ncef_do_message_loop_work(void);

/// Shut CEF down. Every browser must have closed (`before_close`) first.
void ncef_shutdown(void);

// MARK: - Browsers

typedef struct ncef_browser ncef_browser;

/// `cef_paint_element_type_t`.
enum { NCEF_PAINT_VIEW = 0, NCEF_PAINT_POPUP = 1 };

typedef struct ncef_client_callbacks {
    void* userdata;

    // Rendering (CefRenderHandler).

    /// The view's size in DIPs (points).
    void (*view_size)(void* userdata, int* width, int* height);
    /// Pixels per DIP.
    double (*scale_factor)(void* userdata);
    /// A frame in a shared texture: `io_surface` is an IOSurfaceRef, valid
    /// only until this returns; `format` is `cef_color_type_t`.
    void (*accelerated_paint)(void* userdata, int element, void* io_surface, int format);
    /// A frame in CPU memory, BGRA, `width * 4` bytes per row; valid only
    /// until this returns.
    void (*paint)(void* userdata, int element, const void* buffer, int width, int height);
    void (*popup_show)(void* userdata, int show);
    /// The popup's rect, in DIPs relative to the view.
    void (*popup_size)(void* userdata, int x, int y, int width, int height);

    // Display (CefDisplayHandler).

    void (*address_change)(void* userdata, const char* url);
    void (*title_change)(void* userdata, const char* title);
    void (*loading_progress)(void* userdata, double progress);
    /// `cursor` is the platform cursor (NSCursor*); `type` is
    /// `cef_cursor_type_t`.
    void (*cursor_change)(void* userdata, void* cursor, int type);
    void (*console_message)(void* userdata, int level, const char* message, const char* source, int line);

    // Loading (CefLoadHandler).

    void (*loading_state_change)(void* userdata, int is_loading, int can_go_back, int can_go_forward);
    void (*load_error)(void* userdata, int error_code, const char* error_text, const char* failed_url);

    // Life span (CefLifeSpanHandler).

    void (*after_created)(void* userdata);
    void (*before_close)(void* userdata);
    /// A page asked for a new window. The window is never opened — a
    /// windowless browser has nowhere to put it — so this is the model's
    /// chance to do something else with `target_url`, e.g. load it here.
    void (*before_popup)(void* userdata, const char* target_url);

    // Queries from the page (CefMessageRouter).

    /// A page called `window.cefQuery({ request, persistent, onSuccess,
    /// onFailure })` with a string `request`. Return 1 to take it — then
    /// answer with `ncef_browser_query_succeed` / `_fail`, now or later: once
    /// for a one-off query, any number of times for a persistent one until
    /// it fails or is canceled. Return 0 to leave it, and the page's
    /// onFailure gets -1.
    int (*query)(void* userdata, int64_t query_id, const char* request, const char* frame_url,
                 int is_main_frame, int persistent);
    /// A query taken and not finished has gone: the page canceled it
    /// (`window.cefQueryCancel`), navigated, or its renderer ended. Answers
    /// to it are ignored from now on.
    void (*query_canceled)(void* userdata, int64_t query_id);
} ncef_client_callbacks;

typedef struct ncef_browser_options {
    /// 1 for `OnAcceleratedPaint` IOSurfaces, 0 for `OnPaint` CPU buffers.
    int shared_texture;
    /// Frames per second, 1…60 (CEF's cap without external begin frames).
    int frame_rate;
    /// Page background, ARGB. Opaque disables transparent painting.
    uint32_t background_color;
} ncef_browser_options;

/// Start creating a windowless browser loading `url`. Creation completes
/// asynchronously (`after_created`); calls made before then are kept and
/// applied once it has — only the latest `load_url` of them.
ncef_browser* ncef_browser_create(const char* url,
                                  const ncef_client_callbacks* callbacks,
                                  const ncef_browser_options* options);

/// Ask the browser to close; `before_close` follows. `force` skips the page's
/// unload handlers.
void ncef_browser_close(ncef_browser* browser, int force);

/// Drop the handle. The callbacks' `userdata` is never used again after this
/// — call it once `before_close` has arrived, or to abandon a browser whose
/// owner is going away (it is then closed, forcibly, first).
void ncef_browser_release(ncef_browser* browser);

void ncef_browser_load_url(ncef_browser* browser, const char* url);
void ncef_browser_go_back(ncef_browser* browser);
void ncef_browser_go_forward(ncef_browser* browser);
void ncef_browser_reload(ncef_browser* browser, int ignore_cache);
void ncef_browser_stop_load(ncef_browser* browser);
void ncef_browser_execute_javascript(ncef_browser* browser, const char* code, const char* script_url);

/// Editing commands on the focused frame — what a windowed browser gets from
/// the Edit menu, which a windowless one has to be sent explicitly.
typedef enum {
    NCEF_EDIT_UNDO = 0,
    NCEF_EDIT_REDO,
    NCEF_EDIT_CUT,
    NCEF_EDIT_COPY,
    NCEF_EDIT_PASTE,
    NCEF_EDIT_SELECT_ALL,
} ncef_edit_command;

void ncef_browser_edit(ncef_browser* browser, ncef_edit_command command);

/// Answer a query taken in `query`: the page's onSuccess gets `response`.
/// Finishes a one-off query; a persistent one stays open. Ignored for a
/// query that is finished, canceled or unknown.
void ncef_browser_query_succeed(ncef_browser* browser, int64_t query_id, const char* response);

/// Fail a query taken in `query`: the page's onFailure gets `error_code` and
/// `message`. Finishes the query, persistent or not.
void ncef_browser_query_fail(ncef_browser* browser, int64_t query_id, int error_code, const char* message);

void ncef_browser_set_zoom_level(ncef_browser* browser, double level);
double ncef_browser_zoom_level(ncef_browser* browser);

/// The view's size (`view_size`) or scale (`scale_factor`) changed.
void ncef_browser_was_resized(ncef_browser* browser);
void ncef_browser_notify_screen_info_changed(ncef_browser* browser);
void ncef_browser_was_hidden(ncef_browser* browser, int hidden);
void ncef_browser_set_focus(ncef_browser* browser, int focus);
/// Ask for a full repaint of the view.
void ncef_browser_invalidate(ncef_browser* browser);

// MARK: - Input (coordinates in DIPs, relative to the view)

/// The values of CEF's `cef_event_flags_t`, `cef_mouse_button_type_t` and
/// `cef_key_event_type_t` this surface uses — repeated here so Swift needs no
/// CEF header; ncef.mm checks each against CEF's own at compile time.
enum {
    NCEF_EVENTFLAG_CAPS_LOCK_ON = 1 << 0,
    NCEF_EVENTFLAG_SHIFT_DOWN = 1 << 1,
    NCEF_EVENTFLAG_CONTROL_DOWN = 1 << 2,
    NCEF_EVENTFLAG_ALT_DOWN = 1 << 3,
    NCEF_EVENTFLAG_LEFT_MOUSE_BUTTON = 1 << 4,
    NCEF_EVENTFLAG_COMMAND_DOWN = 1 << 7,
    NCEF_EVENTFLAG_PRECISION_SCROLLING_DELTA = 1 << 14,
};

enum {
    NCEF_MOUSE_BUTTON_LEFT = 0,
    NCEF_MOUSE_BUTTON_MIDDLE = 1,
    NCEF_MOUSE_BUTTON_RIGHT = 2,
};

enum {
    NCEF_KEYEVENT_RAWKEYDOWN = 0,
    NCEF_KEYEVENT_KEYDOWN = 1,
    NCEF_KEYEVENT_KEYUP = 2,
    NCEF_KEYEVENT_CHAR = 3,
};

/// `modifiers` are `cef_event_flags_t`.
void ncef_browser_send_mouse_move(ncef_browser* browser, int x, int y, uint32_t modifiers, int mouse_leave);
/// `button` is `cef_mouse_button_type_t`.
void ncef_browser_send_mouse_click(ncef_browser* browser, int x, int y, uint32_t modifiers,
                                   int button, int mouse_up, int click_count);
void ncef_browser_send_mouse_wheel(ncef_browser* browser, int x, int y, uint32_t modifiers,
                                   int delta_x, int delta_y);
/// `type` is `cef_key_event_type_t`.
void ncef_browser_send_key_event(ncef_browser* browser, int type, uint32_t modifiers,
                                 int windows_key_code, int native_key_code, int is_system_key,
                                 uint16_t character, uint16_t unmodified_character);

#ifdef __cplusplus
}
#endif

#endif  // NCEF_H
