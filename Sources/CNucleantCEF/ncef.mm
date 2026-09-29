//
//  ncef.mm
//  NucleantCEF
//
//  The C surface declared in ncef.h, over CEF's C++ API (libcef_dll_wrapper).
//  Objective-C++ for the one thing CEF asks of the host application on macOS:
//  an NSApplication that speaks CefAppProtocol (see `ncef_adopt_application`).
//

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include <crt_externs.h>
#include <map>
#include <string>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_display_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_render_handler.h"
#include "include/cef_request_handler.h"
#include "include/wrapper/cef_library_loader.h"
#include "include/wrapper/cef_message_router.h"

#include "ncef.h"

static_assert(NCEF_EVENTFLAG_CAPS_LOCK_ON == EVENTFLAG_CAPS_LOCK_ON);
static_assert(NCEF_EVENTFLAG_SHIFT_DOWN == EVENTFLAG_SHIFT_DOWN);
static_assert(NCEF_EVENTFLAG_CONTROL_DOWN == EVENTFLAG_CONTROL_DOWN);
static_assert(NCEF_EVENTFLAG_ALT_DOWN == EVENTFLAG_ALT_DOWN);
static_assert(NCEF_EVENTFLAG_LEFT_MOUSE_BUTTON == EVENTFLAG_LEFT_MOUSE_BUTTON);
static_assert(NCEF_EVENTFLAG_COMMAND_DOWN == EVENTFLAG_COMMAND_DOWN);
static_assert(NCEF_EVENTFLAG_PRECISION_SCROLLING_DELTA == EVENTFLAG_PRECISION_SCROLLING_DELTA);
static_assert(NCEF_MOUSE_BUTTON_LEFT == MBT_LEFT);
static_assert(NCEF_MOUSE_BUTTON_MIDDLE == MBT_MIDDLE);
static_assert(NCEF_MOUSE_BUTTON_RIGHT == MBT_RIGHT);
static_assert(NCEF_KEYEVENT_RAWKEYDOWN == KEYEVENT_RAWKEYDOWN);
static_assert(NCEF_KEYEVENT_KEYDOWN == KEYEVENT_KEYDOWN);
static_assert(NCEF_KEYEVENT_KEYUP == KEYEVENT_KEYUP);
static_assert(NCEF_KEYEVENT_CHAR == KEYEVENT_CHAR);
static_assert(NCEF_PAINT_VIEW == PET_VIEW);
static_assert(NCEF_PAINT_POPUP == PET_POPUP);

// MARK: - NSApplication as a CefAppProtocol

// Chromium's message pump asks NSApp whether it is inside -sendEvent: (the
// CrAppProtocol it checks for) and sets that state around nested loops. CEF's
// answer is "subclass NSApplication"; a NucleantUI app runs the stock
// NSApplication, which it does not own the class of. So the protocol is added
// to whatever class NSApp is, at runtime, and -sendEvent: is wrapped to keep
// the flag honest. Once per process; a class that already conforms is left
// alone.

static BOOL ncef_handling_send_event = NO;
static IMP ncef_original_send_event = nullptr;

static BOOL ncef_is_handling_send_event(id, SEL) {
    return ncef_handling_send_event;
}

static void ncef_set_handling_send_event(id, SEL, BOOL handling) {
    ncef_handling_send_event = handling;
}

static void ncef_send_event(id self, SEL command, NSEvent* event) {
    BOOL was = ncef_handling_send_event;
    ncef_handling_send_event = YES;
    ((void (*)(id, SEL, NSEvent*))ncef_original_send_event)(self, command, event);
    ncef_handling_send_event = was;
}

static void ncef_adopt_application(void) {
    NSApplication* app = [NSApplication sharedApplication];
    if ([app conformsToProtocol:@protocol(CefAppProtocol)]) {
        return;
    }
    Class cls = [app class];
    class_addMethod(cls, @selector(isHandlingSendEvent), (IMP)ncef_is_handling_send_event, "c@:");
    class_addMethod(cls, @selector(setHandlingSendEvent:), (IMP)ncef_set_handling_send_event, "v@:c");

    // An override on `cls` itself, so a superclass's -sendEvent: is never
    // rewritten underneath other subclasses.
    SEL sendEvent = @selector(sendEvent:);
    Method inherited = class_getInstanceMethod(cls, sendEvent);
    ncef_original_send_event = method_getImplementation(inherited);
    if (!class_addMethod(cls, sendEvent, (IMP)ncef_send_event, method_getTypeEncoding(inherited))) {
        method_setImplementation(class_getInstanceMethod(cls, sendEvent), (IMP)ncef_send_event);
    }
    class_addProtocol(cls, @protocol(CefAppProtocol));
}

// MARK: - Process

namespace {

void (*g_schedule_pump)(int64_t) = nullptr;

class NCefApp : public CefApp, public CefBrowserProcessHandler {
public:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

    void OnBeforeCommandLineProcessing(const CefString& process_type,
                                       CefRefPtr<CefCommandLine> command_line) override {
        if (!process_type.empty()) return;
        // Chromium otherwise keeps its cookie encryption key in the login
        // keychain, and a bare executable (no signed bundle) gets a keychain
        // prompt on every launch.
        command_line->AppendSwitch("use-mock-keychain");
    }

    void OnScheduleMessagePumpWork(int64_t delay_ms) override {
        if (g_schedule_pump) g_schedule_pump(delay_ms);
    }

private:
    IMPLEMENT_REFCOUNTING(NCefApp);
};

}  // namespace

extern "C" int ncef_load_library(const char* framework_dir) {
    std::string binary = std::string(framework_dir) + "/Chromium Embedded Framework";
    return cef_load_library(binary.c_str()) ? 1 : 0;
}

extern "C" int ncef_initialize(const ncef_settings* settings) {
    ncef_adopt_application();
    g_schedule_pump = settings->schedule_message_pump_work;

    CefMainArgs args(*_NSGetArgc(), *_NSGetArgv());
    CefSettings s;
    s.no_sandbox = 1;
    s.windowless_rendering_enabled = 1;
    s.external_message_pump = 1;
    CefString(&s.framework_dir_path) = settings->framework_dir;
    CefString(&s.browser_subprocess_path) = settings->helper_path;
    CefString(&s.main_bundle_path) = settings->main_bundle_path;
    CefString(&s.root_cache_path) = settings->root_cache_path;
    if (settings->cache_path) CefString(&s.cache_path) = settings->cache_path;
    if (settings->log_file) CefString(&s.log_file) = settings->log_file;
    s.log_severity = (cef_log_severity_t)settings->log_severity;
    s.remote_debugging_port = settings->remote_debugging_port;

    CefRefPtr<NCefApp> app = new NCefApp;
    return CefInitialize(args, s, app, nullptr) ? 1 : 0;
}

extern "C" int ncef_exit_code(void) {
    return CefGetExitCode();
}

extern "C" void ncef_do_message_loop_work(void) {
    CefDoMessageLoopWork();
}

extern "C" void ncef_shutdown(void) {
    CefShutdown();
    g_schedule_pump = nullptr;
}

// MARK: - Browsers

namespace {

/// One browser's handlers. Every entry point checks `detached_` first: once
/// the Swift owner has let go (`ncef_browser_release`) its userdata is gone,
/// and CEF may still be delivering to this object while the browser closes.
///
/// Each client has its own browser side of CEF's message router — the page's
/// `window.cefQuery`, whose renderer side the helper installs (see
/// NucleantCEFHelper/main.cc; both use the default configuration). The
/// client is the router's only handler, and keeps the callbacks of the
/// queries it has taken until they are answered or canceled.
class NCefClient : public CefClient,
                   public CefRenderHandler,
                   public CefDisplayHandler,
                   public CefLoadHandler,
                   public CefLifeSpanHandler,
                   public CefRequestHandler,
                   public CefMessageRouterBrowserSide::Handler {
public:
    explicit NCefClient(const ncef_client_callbacks& callbacks)
        : cb_(callbacks), router_(CefMessageRouterBrowserSide::Create(CefMessageRouterConfig())) {
        router_->AddHandler(this, false);
    }

    ~NCefClient() override {
        if (!handler_removed_) router_->RemoveHandler(this);
    }

    CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

    bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                  CefProcessId source_process, CefRefPtr<CefProcessMessage> message) override {
        return router_->OnProcessMessageReceived(browser, frame, source_process, message);
    }

    // Owner side.

    CefRefPtr<CefBrowser> browser() const { return browser_; }

    void Detach() { detached_ = true; }

    void LoadURL(const std::string& url) {
        if (browser_) {
            browser_->GetMainFrame()->LoadURL(url);
        } else {
            pending_url_ = url;
        }
    }

    void Close(bool force) {
        if (closed_) return;
        if (browser_) {
            browser_->GetHost()->CloseBrowser(force);
        } else {
            // Still being created: close as soon as it exists.
            close_pending_ = true;
            close_force_ = close_force_ || force;
        }
    }

    void SetFocus(bool focus) {
        if (browser_) {
            browser_->GetHost()->SetFocus(focus);
        } else {
            pending_focus_ = focus ? 1 : 0;
        }
    }

    void QuerySucceed(int64_t query_id, const std::string& response) {
        auto it = queries_.find(query_id);
        if (it == queries_.end()) return;
        CefRefPtr<Callback> callback = it->second.callback;
        if (!it->second.persistent) queries_.erase(it);
        callback->Success(response);
    }

    void QueryFail(int64_t query_id, int error_code, const std::string& message) {
        auto it = queries_.find(query_id);
        if (it == queries_.end()) return;
        CefRefPtr<Callback> callback = it->second.callback;
        queries_.erase(it);
        callback->Failure(error_code, message);
    }

    // CefMessageRouterBrowserSide::Handler.

    bool OnQuery(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, int64_t query_id,
                 const CefString& request, bool persistent, CefRefPtr<Callback> callback) override {
        if (detached_ || !cb_.query) return false;
        // Kept before Swift sees it, so an answer given from inside the
        // callback finds it.
        queries_[query_id] = PendingQuery{callback, persistent};
        int taken = cb_.query(cb_.userdata, query_id, request.ToString().c_str(),
                              frame->GetURL().ToString().c_str(), frame->IsMain() ? 1 : 0,
                              persistent ? 1 : 0);
        auto it = queries_.find(query_id);
        if (it == queries_.end()) return true;  // already answered for good
        if (!taken) {
            queries_.erase(it);
            return false;
        }
        return true;
    }

    void OnQueryCanceled(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int64_t query_id) override {
        if (queries_.erase(query_id) && !detached_ && cb_.query_canceled) {
            cb_.query_canceled(cb_.userdata, query_id);
        }
    }

    // CefRequestHandler — what the router needs to hear about.

    bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest>,
                        bool, bool) override {
        router_->OnBeforeBrowse(browser, frame);
        return false;
    }

    void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser, TerminationStatus, int,
                                   const CefString&) override {
        router_->OnRenderProcessTerminated(browser);
    }

    // CefRenderHandler.

    void GetViewRect(CefRefPtr<CefBrowser>, CefRect& rect) override {
        int width = 1, height = 1;
        if (!detached_ && cb_.view_size) cb_.view_size(cb_.userdata, &width, &height);
        rect = CefRect(0, 0, width > 0 ? width : 1, height > 0 ? height : 1);
    }

    bool GetScreenInfo(CefRefPtr<CefBrowser> browser, CefScreenInfo& info) override {
        double scale = 1;
        if (!detached_ && cb_.scale_factor) scale = cb_.scale_factor(cb_.userdata);
        CefRect view;
        GetViewRect(browser, view);
        info.device_scale_factor = (float)(scale > 0 ? scale : 1);
        info.rect = view;
        info.available_rect = view;
        return true;
    }

    void OnPopupShow(CefRefPtr<CefBrowser>, bool show) override {
        if (!detached_ && cb_.popup_show) cb_.popup_show(cb_.userdata, show ? 1 : 0);
    }

    void OnPopupSize(CefRefPtr<CefBrowser>, const CefRect& rect) override {
        if (!detached_ && cb_.popup_size) cb_.popup_size(cb_.userdata, rect.x, rect.y, rect.width, rect.height);
    }

    void OnPaint(CefRefPtr<CefBrowser>, PaintElementType type, const RectList&,
                 const void* buffer, int width, int height) override {
        if (!detached_ && cb_.paint) cb_.paint(cb_.userdata, (int)type, buffer, width, height);
    }

    void OnAcceleratedPaint(CefRefPtr<CefBrowser>, PaintElementType type, const RectList&,
                            const CefAcceleratedPaintInfo& info) override {
        if (!detached_ && cb_.accelerated_paint) {
            cb_.accelerated_paint(cb_.userdata, (int)type, info.shared_texture_io_surface, (int)info.format);
        }
    }

    // CefDisplayHandler.

    void OnAddressChange(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, const CefString& url) override {
        if (!detached_ && cb_.address_change && frame->IsMain()) {
            cb_.address_change(cb_.userdata, url.ToString().c_str());
        }
    }

    void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
        if (!detached_ && cb_.title_change) cb_.title_change(cb_.userdata, title.ToString().c_str());
    }

    void OnLoadingProgressChange(CefRefPtr<CefBrowser>, double progress) override {
        if (!detached_ && cb_.loading_progress) cb_.loading_progress(cb_.userdata, progress);
    }

    bool OnCursorChange(CefRefPtr<CefBrowser>, CefCursorHandle cursor, cef_cursor_type_t type,
                        const CefCursorInfo&) override {
        if (detached_ || !cb_.cursor_change) return false;
        cb_.cursor_change(cb_.userdata, (void*)cursor, (int)type);
        return true;
    }

    bool OnConsoleMessage(CefRefPtr<CefBrowser>, cef_log_severity_t level, const CefString& message,
                          const CefString& source, int line) override {
        if (!detached_ && cb_.console_message) {
            cb_.console_message(cb_.userdata, (int)level, message.ToString().c_str(),
                                source.ToString().c_str(), line);
        }
        return false;
    }

    // CefLoadHandler.

    void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool is_loading, bool can_go_back,
                              bool can_go_forward) override {
        if (!detached_ && cb_.loading_state_change) {
            cb_.loading_state_change(cb_.userdata, is_loading, can_go_back, can_go_forward);
        }
    }

    void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, ErrorCode error_code,
                     const CefString& error_text, const CefString& failed_url) override {
        if (!detached_ && cb_.load_error && frame->IsMain()) {
            cb_.load_error(cb_.userdata, (int)error_code, error_text.ToString().c_str(),
                           failed_url.ToString().c_str());
        }
    }

    // CefLifeSpanHandler.

    bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int, const CefString& target_url,
                       const CefString&, WindowOpenDisposition, bool, const CefPopupFeatures&,
                       CefWindowInfo&, CefRefPtr<CefClient>&, CefBrowserSettings&,
                       CefRefPtr<CefDictionaryValue>&, bool*) override {
        if (!detached_ && cb_.before_popup) cb_.before_popup(cb_.userdata, target_url.ToString().c_str());
        return true;  // cancelled: a windowless browser has nowhere to open one
    }

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        browser_ = browser;
        if (close_pending_ || detached_) {
            browser_->GetHost()->CloseBrowser(close_force_ || detached_);
            return;
        }
        if (!pending_url_.empty()) {
            browser_->GetMainFrame()->LoadURL(pending_url_);
            pending_url_.clear();
        }
        if (pending_focus_ >= 0) {
            browser_->GetHost()->SetFocus(pending_focus_ == 1);
            pending_focus_ = -1;
        }
        if (cb_.after_created) cb_.after_created(cb_.userdata);
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        router_->OnBeforeClose(browser);
        router_->RemoveHandler(this);
        handler_removed_ = true;
        browser_ = nullptr;
        closed_ = true;
        if (!detached_ && cb_.before_close) cb_.before_close(cb_.userdata);
    }

private:
    struct PendingQuery {
        CefRefPtr<Callback> callback;
        bool persistent;
    };

    ncef_client_callbacks cb_;
    CefRefPtr<CefMessageRouterBrowserSide> router_;
    bool handler_removed_ = false;
    std::map<int64_t, PendingQuery> queries_;
    CefRefPtr<CefBrowser> browser_;
    bool detached_ = false;
    bool closed_ = false;
    bool close_pending_ = false;
    bool close_force_ = false;
    int pending_focus_ = -1;
    std::string pending_url_;

    IMPLEMENT_REFCOUNTING(NCefClient);
};

}  // namespace

struct ncef_browser {
    CefRefPtr<NCefClient> client;
};

static CefRefPtr<CefBrowserHost> ncef_host(ncef_browser* browser) {
    CefRefPtr<CefBrowser> b = browser ? browser->client->browser() : nullptr;
    return b ? b->GetHost() : nullptr;
}

extern "C" ncef_browser* ncef_browser_create(const char* url,
                                             const ncef_client_callbacks* callbacks,
                                             const ncef_browser_options* options) {
    CefWindowInfo window;
    window.SetAsWindowless(nullptr);
    window.shared_texture_enabled = options->shared_texture ? 1 : 0;

    CefBrowserSettings settings;
    settings.windowless_frame_rate = options->frame_rate > 0 ? options->frame_rate : 60;
    settings.background_color = options->background_color;

    auto* browser = new ncef_browser{new NCefClient(*callbacks)};
    if (!CefBrowserHost::CreateBrowser(window, browser->client, url ? url : "", settings, nullptr, nullptr)) {
        delete browser;
        return nullptr;
    }
    return browser;
}

extern "C" void ncef_browser_close(ncef_browser* browser, int force) {
    if (browser) browser->client->Close(force != 0);
}

extern "C" void ncef_browser_release(ncef_browser* browser) {
    if (!browser) return;
    browser->client->Detach();
    browser->client->Close(true);
    delete browser;
}

extern "C" void ncef_browser_load_url(ncef_browser* browser, const char* url) {
    if (browser && url) browser->client->LoadURL(url);
}

extern "C" void ncef_browser_go_back(ncef_browser* browser) {
    if (CefRefPtr<CefBrowser> b = browser ? browser->client->browser() : nullptr) b->GoBack();
}

extern "C" void ncef_browser_go_forward(ncef_browser* browser) {
    if (CefRefPtr<CefBrowser> b = browser ? browser->client->browser() : nullptr) b->GoForward();
}

extern "C" void ncef_browser_reload(ncef_browser* browser, int ignore_cache) {
    if (CefRefPtr<CefBrowser> b = browser ? browser->client->browser() : nullptr) {
        if (ignore_cache) b->ReloadIgnoreCache(); else b->Reload();
    }
}

extern "C" void ncef_browser_stop_load(ncef_browser* browser) {
    if (CefRefPtr<CefBrowser> b = browser ? browser->client->browser() : nullptr) b->StopLoad();
}

extern "C" void ncef_browser_execute_javascript(ncef_browser* browser, const char* code, const char* script_url) {
    if (CefRefPtr<CefBrowser> b = browser ? browser->client->browser() : nullptr) {
        b->GetMainFrame()->ExecuteJavaScript(code ? code : "", script_url ? script_url : "", 0);
    }
}

extern "C" void ncef_browser_edit(ncef_browser* browser, ncef_edit_command command) {
    CefRefPtr<CefBrowser> b = browser ? browser->client->browser() : nullptr;
    CefRefPtr<CefFrame> frame = b ? b->GetFocusedFrame() : nullptr;
    if (!frame) return;
    switch (command) {
        case NCEF_EDIT_UNDO: frame->Undo(); break;
        case NCEF_EDIT_REDO: frame->Redo(); break;
        case NCEF_EDIT_CUT: frame->Cut(); break;
        case NCEF_EDIT_COPY: frame->Copy(); break;
        case NCEF_EDIT_PASTE: frame->Paste(); break;
        case NCEF_EDIT_SELECT_ALL: frame->SelectAll(); break;
    }
}

extern "C" void ncef_browser_query_succeed(ncef_browser* browser, int64_t query_id, const char* response) {
    if (browser) browser->client->QuerySucceed(query_id, response ? response : "");
}

extern "C" void ncef_browser_query_fail(ncef_browser* browser, int64_t query_id, int error_code,
                                        const char* message) {
    if (browser) browser->client->QueryFail(query_id, error_code, message ? message : "");
}

extern "C" void ncef_browser_set_zoom_level(ncef_browser* browser, double level) {
    if (auto host = ncef_host(browser)) host->SetZoomLevel(level);
}

extern "C" double ncef_browser_zoom_level(ncef_browser* browser) {
    auto host = ncef_host(browser);
    return host ? host->GetZoomLevel() : 0;
}

extern "C" void ncef_browser_was_resized(ncef_browser* browser) {
    if (auto host = ncef_host(browser)) host->WasResized();
}

extern "C" void ncef_browser_notify_screen_info_changed(ncef_browser* browser) {
    if (auto host = ncef_host(browser)) host->NotifyScreenInfoChanged();
}

extern "C" void ncef_browser_was_hidden(ncef_browser* browser, int hidden) {
    if (auto host = ncef_host(browser)) host->WasHidden(hidden != 0);
}

extern "C" void ncef_browser_set_focus(ncef_browser* browser, int focus) {
    if (browser) browser->client->SetFocus(focus != 0);
}

extern "C" void ncef_browser_invalidate(ncef_browser* browser) {
    if (auto host = ncef_host(browser)) host->Invalidate(PET_VIEW);
}

extern "C" void ncef_browser_send_mouse_move(ncef_browser* browser, int x, int y, uint32_t modifiers,
                                             int mouse_leave) {
    if (auto host = ncef_host(browser)) {
        CefMouseEvent event;
        event.x = x;
        event.y = y;
        event.modifiers = modifiers;
        host->SendMouseMoveEvent(event, mouse_leave != 0);
    }
}

extern "C" void ncef_browser_send_mouse_click(ncef_browser* browser, int x, int y, uint32_t modifiers,
                                              int button, int mouse_up, int click_count) {
    if (auto host = ncef_host(browser)) {
        CefMouseEvent event;
        event.x = x;
        event.y = y;
        event.modifiers = modifiers;
        host->SendMouseClickEvent(event, (CefBrowserHost::MouseButtonType)button, mouse_up != 0, click_count);
    }
}

extern "C" void ncef_browser_send_mouse_wheel(ncef_browser* browser, int x, int y, uint32_t modifiers,
                                              int delta_x, int delta_y) {
    if (auto host = ncef_host(browser)) {
        CefMouseEvent event;
        event.x = x;
        event.y = y;
        event.modifiers = modifiers;
        host->SendMouseWheelEvent(event, delta_x, delta_y);
    }
}

extern "C" void ncef_browser_send_key_event(ncef_browser* browser, int type, uint32_t modifiers,
                                            int windows_key_code, int native_key_code, int is_system_key,
                                            uint16_t character, uint16_t unmodified_character) {
    if (auto host = ncef_host(browser)) {
        CefKeyEvent event;
        event.type = (cef_key_event_type_t)type;
        event.modifiers = modifiers;
        event.windows_key_code = windows_key_code;
        event.native_key_code = native_key_code;
        event.is_system_key = is_system_key;
        event.character = character;
        event.unmodified_character = unmodified_character;
        host->SendKeyEvent(event);
    }
}
