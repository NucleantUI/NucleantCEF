//
//  main.cc
//  NucleantCEFHelper
//
//  The executable CEF launches for every sub-process (renderer, GPU, network,
//  utility) — `CefSettings.browser_subprocess_path`. It finds the framework
//  and hands over to CEF; in a renderer it also installs the page side of
//  CEF's message router, `window.cefQuery` / `window.cefQueryCancel`, whose
//  browser side each browser's client keeps (ncef.mm).
//
//  Where the framework is: CEF passes its own `--framework-dir-path` down to
//  sub-processes when the browser process was given one; the browser process
//  also exports NUCLEANT_CEF_FRAMEWORK_DIR, which every child inherits, for
//  the processes Chromium launches without that switch.
//

#include <cstdlib>
#include <string>

#include "include/cef_app.h"
#include "include/cef_render_process_handler.h"
#include "include/wrapper/cef_library_loader.h"
#include "include/wrapper/cef_message_router.h"

namespace {

/// A renderer's side of the message router: `window.cefQuery` in every
/// frame's context, with the same (default) configuration as the browser
/// side.
class HelperApp : public CefApp, public CefRenderProcessHandler {
public:
    CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }

    void OnWebKitInitialized() override {
        router_ = CefMessageRouterRendererSide::Create(CefMessageRouterConfig());
    }

    void OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                          CefRefPtr<CefV8Context> context) override {
        if (router_) router_->OnContextCreated(browser, frame, context);
    }

    void OnContextReleased(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefV8Context> context) override {
        if (router_) router_->OnContextReleased(browser, frame, context);
    }

    bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                  CefProcessId source_process,
                                  CefRefPtr<CefProcessMessage> message) override {
        return router_ && router_->OnProcessMessageReceived(browser, frame, source_process, message);
    }

private:
    CefRefPtr<CefMessageRouterRendererSide> router_;

    IMPLEMENT_REFCOUNTING(HelperApp);
};

}  // namespace

int main(int argc, char* argv[]) {
    std::string framework;
    const std::string flag = "--framework-dir-path=";
    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if (arg.compare(0, flag.size(), flag) == 0) {
            framework = arg.substr(flag.size());
        }
    }
    if (framework.empty()) {
        if (const char* env = getenv("NUCLEANT_CEF_FRAMEWORK_DIR")) framework = env;
    }
    if (framework.empty()) return 1;

    std::string binary = framework + "/Chromium Embedded Framework";
    if (!cef_load_library(binary.c_str())) return 1;

    CefMainArgs args(argc, argv);
    CefRefPtr<HelperApp> app = new HelperApp;
    int code = CefExecuteProcess(args, app, nullptr);
    cef_unload_library();
    return code;
}
