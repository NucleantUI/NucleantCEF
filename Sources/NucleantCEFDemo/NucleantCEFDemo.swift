//
//  NucleantCEFDemo.swift
//  NucleantCEFDemo
//
//  A tabbed web browser on NucleantUI + CEF: a tab strip, a navigation bar
//  with an editable address field, and the page. The first tab opens the
//  built-in test page; every tab is a full browser.
//
//  Build everything first — the helper executable is a separate product:
//
//      swift build && .build/debug/NucleantCEFDemo
//
//  NUCLEANT_CEF_DEMO_URL opens a page of your own in the first tab instead of
//  the test page; NUCLEANT_CEF_DEMO_SOFTWARE=1 takes CEF's CPU frames instead
//  of IOSurfaces. NUCLEANT_CEF_DEMO_VERIFY=<file.png> runs the self-check in
//  `Verifier` against the test page, saving frames beside that file, then
//  quits.
//

import NucleantUI

/// A page with known colors and something moving, so a readback can tell a
/// live, correctly-ordered frame from a stale or swizzled one: magenta-pink
/// ground (BGRA 128, 0, 255, 255), a lime square sliding along the top.
let testPage = """
data:text/html,<html><head><title>NucleantCEF test page</title></head>\
<body style='margin:0;background:rgb(255,0,128);font:18px -apple-system;color:white'>\
<div id=box style='position:absolute;top:20px;left:0;width:60px;height:60px;background:lime'></div>\
<div style='position:absolute;top:110px;left:20px'>\
<h1 style='margin:0 0 12px'>Hello from CEF</h1>\
<input id=field placeholder='type here' style='font-size:18px;padding:6px;width:300px' \
oninput="document.title='typed:'+this.value">\
<p><select><option>One</option><option>Two</option><option>Three</option></select>\
<a href='https://example.com' style='color:white;margin-left:16px'>example.com</a>\
<a href='https://example.com' target=_blank style='color:white;margin-left:16px'>example.com in a new tab</a></p>\
</div>\
<script>let x=0;setInterval(()=>{x=x>400?0:x+2;box.style.left=x+'px'},16)</script>\
</body></html>
"""

@main
struct NucleantCEFDemo: NucleantApp {
    var body: some Scene {
        WindowGroup("NucleantCEF Browser", width: 1100, height: 760) {
            BrowserScreen()
        }
    }
}
