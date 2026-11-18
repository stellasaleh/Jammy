/* ============================================================
   JAMMY — config.js

   THIS IS THE ONLY FILE YOU EVER NEED TO EDIT.

   These two values connect the app to your Supabase project.
   They are filled in and working. You should not need to touch
   this file again unless you move to a different project.

   Both of these are meant to be public — they ship inside every
   copy of the app. The database is protected by its own security
   rules, not by hiding these.

   NEVER paste the key labelled "service_role" or "Secret key"
   here. That one
   bypasses every security rule in your database.
   ============================================================ */

window.JAMMY_CONFIG = {

  url: "https://hzkwfmudbefiktiptazo.supabase.co",

  anonKey: "sb_publishable_T6Lo5S69d_KKYnTtEDj4BQ_cmMTFpeS",

};

/* ------------------------------------------------------------
   Until those two lines are filled in, Jammy runs in DEMO mode:
   the sixteen fictional Boston musicians, scripted replies,
   everything saved only on this device.

   Once they're filled in, Jammy runs in LIVE mode: real accounts,
   real people, real messages. You'll see "LIVE" in the top bar
   so you always know which one you're looking at.
   ------------------------------------------------------------ */
window.JAMMY_LIVE = (function () {
  var c = window.JAMMY_CONFIG || {};
  return !!(c.url && c.anonKey &&
    c.url.indexOf("PASTE_") !== 0 &&
    c.anonKey.indexOf("PASTE_") !== 0 &&
    c.url.indexOf("supabase.co") > -1);
})();
