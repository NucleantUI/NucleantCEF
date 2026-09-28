//
//  main.cc
//  NucleantCEFHelper
//
//  The executable CEF launches for every sub-process (renderer, GPU, network,
//  utility) — `CefSettings.browser_subprocess_path`. It only has to find the
//  framework and hand over to CEF.
//
//  Where the framework is: CEF passes its own `--framework-dir-path` down to
//  sub-processes when the browser process was given one; the browser process
//  also exports NUCLEANT_CEF_FRAMEWORK_DIR, which every child inherits, for
//  the processes Chromium launches without that switch.
//

#include <cstdlib>
#include <string>

#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"

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
    int code = CefExecuteProcess(args, nullptr, nullptr);
    cef_unload_library();
    return code;
}
