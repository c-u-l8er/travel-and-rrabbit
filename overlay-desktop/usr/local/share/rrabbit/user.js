// Firefox prefs for the RRABBIT kiosk.
//
// THE WHOLE SESSION TURNS ON WEBGL. T&R's guests run Xorg on `scfb` over a
// bochs `std` VGA adapter with NO DRM kernel module -- there is no GPU for
// Firefox to find, and its default response to that is to DISABLE WebGL, which
// would present as a black road rather than as an error.
//
// These prefs force the software path. They are the T&R deployment gate in
// eight lines, and they are UNVERIFIED on the target -- no image has been built
// and booted with this session. See RRABBIT spec section 17.
user_pref("webgl.force-enabled", true);
user_pref("webgl.disabled", false);
user_pref("webgl.disable-angle", true);
user_pref("gfx.webrender.software", true);
user_pref("layers.acceleration.disabled", true);

// A kiosk should come up, not ask questions.
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
// The shell owns the whole window; nothing should overlay it.
user_pref("full-screen-api.warning.timeout", 0);
user_pref("browser.tabs.warnOnClose", false);
