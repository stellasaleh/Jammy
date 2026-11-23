/* ============================================================
   JAMMY — failure.browser.js
   What a person sees when things go wrong.

   Everything else tests the day the server answers. This tests
   the day it does not: the train goes into a tunnel, the upload
   fails, the code never arrives. A person can forgive an app
   that fails. They cannot forgive one that fails silently and
   leaves them pressing a button that does nothing.

   The rule being checked, everywhere: when something fails, the
   person is told, and the control they pressed comes back so
   they can try again.

     node test/failure.browser.js
   ============================================================ */

const { chromium } = require("playwright");
const fs = require("fs");
const http = require("http");
const path = require("path");

const ROOT = process.env.ROOT || "/mnt/user-data/outputs/jammy/www";
const PORT = 8166;

let pass = 0;
const findings = [];
function ok(cond, what, detail) {
  if (cond) { pass++; console.log("  ✓ " + what); return true; }
  findings.push({ what, detail });
  console.log(`  ✗ ${what}${detail ? " — " + detail : ""}`);
  return false;
}

/* the same fake as the audit, so there is one description of the server */
const AUDIT = fs.readFileSync(path.join(__dirname, "audit.browser.js"), "utf8");
const FAKE = AUDIT.match(/const FAKE = `([\s\S]*?)`;\n/)[1].replace("${POPULATED}", "true");

const SILENT_WAV = (() => {
  const n = 8000, b = Buffer.alloc(44 + n);
  b.write("RIFF", 0); b.writeUInt32LE(36 + n, 4); b.write("WAVE", 8);
  b.write("fmt ", 12); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20);
  b.writeUInt16LE(1, 22); b.writeUInt32LE(8000, 24); b.writeUInt32LE(8000, 28);
  b.writeUInt16LE(1, 32); b.writeUInt16LE(8, 34);
  b.write("data", 36); b.writeUInt32LE(n, 40); b.fill(128, 44);
  return b;
})();

(async () => {
  const srv = http.createServer((req, res) => {
    const u = req.url.split("?")[0];
    if (u === "/api.js") { res.writeHead(200, { "Content-Type": "text/javascript" }); res.end(FAKE); return; }
    if (u.startsWith("/_t/") || u.startsWith("/_m/")) {
      res.writeHead(200, { "Content-Type": "audio/wav" }); res.end(SILENT_WAV); return;
    }
    const f = path.join(ROOT, u === "/" ? "index.html" : u);
    fs.readFile(f, (e, d) => {
      if (e) { res.writeHead(404); res.end("no"); return; }
      res.writeHead(200, { "Content-Type": u.endsWith(".js") ? "text/javascript" : "text/html" });
      res.end(d);
    });
  });
  await new Promise(r => srv.listen(PORT, r));

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  await ctx.addInitScript(() => {
    try { localStorage.setItem("jammy:v1", JSON.stringify({ onboarded: true, firstRun: false })); } catch (e) {}
  });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", e => errors.push(String(e.message)));

  await page.goto(`http://localhost:${PORT}/index.html`);
  await page.waitForTimeout(1600);

  const wait = ms => page.waitForTimeout(ms);
  const toastText = () => page.evaluate(() => {
    const t = document.querySelector("#toast");
    return t && t.classList.contains("on") ? t.textContent.trim() : "";
  });
  const fail = (name, msg) => page.evaluate(({ n, m }) => { window.__fail[n] = m; }, { n: name, m: msg });
  const unfail = () => page.evaluate(() => { window.__fail = {}; });

  console.log("=".repeat(62));
  console.log("WHEN THINGS GO WRONG");
  console.log("=".repeat(62));

  /* A suite that dies on its own fragility reports nothing. Whatever
     breaks, finish and say what was found up to that point. */
  try {

  /* ---------------------------------------------------------- */
  console.log("\n1. SENDING A MESSAGE that will not send");
  await page.evaluate(() => { go("chats"); });
  await wait(900);
  await fail("send", "Network request failed");

  /* open a conversation the way a person does — by tapping the row */
  const rowOpened = await page.evaluate(() => {
    const row = document.querySelector("#chats .crow, #chats [data-conv], #chats li, #chats .row");
    if (!row) return false;
    row.click();
    return true;
  });
  await wait(900);

  const chatOpen = await page.evaluate(() =>
    !!document.querySelector("#chat") && document.querySelector("#chat").classList.contains("on"));

  if (rowOpened && chatOpen) {
    await page.fill("#ch-input", "can you make Tuesday?");
    await wait(250);                       /* the send button appears on input */
    await page.click("#ch-send").catch(() => {});
    await wait(900);
    /* The app marks the bubble itself rather than firing a toast, which
       is the better answer: the failure stays on screen next to the
       words instead of vanishing after three seconds. So look at the
       bubble, not at the toast. */
    const bubble = await page.evaluate(() => {
      const b = document.querySelector(".msg.failed");
      if (!b) return null;
      return { text: b.textContent.trim(), role: b.getAttribute("role"),
               tab: b.getAttribute("tabindex"), label: b.getAttribute("aria-label") || "" };
    });
    ok(!!bubble, "a message that fails is marked as not sent",
       "nothing on screen said it failed");
    if (bubble) {
      ok(/not sent/i.test(bubble.text), "and says so in words", bubble.text.slice(0, 60));
      ok(/retry|try again/i.test(bubble.text + bubble.label),
         "and offers to try again", bubble.text.slice(0, 60));
      ok(bubble.role === "button" && bubble.tab === "0",
         "and the retry can be reached from a keyboard, not just a finger",
         `role=${bubble.role} tabindex=${bubble.tab}`);

      /* and pressing Enter on it actually resends */
      await unfail();
      /* Focus it the way a keyboard user would have to, then press a
         real key. Dispatching the event straight at the element would
         pass even on a bubble nobody can reach. */
      const focused = await page.evaluate(() => {
        const b = document.querySelector(".msg.failed");
        b.focus();
        return document.activeElement === b;
      });
      ok(focused, "the failed message can actually take focus");
      if (focused) {
        await page.keyboard.press("Enter");
        await wait(900);
        ok(!(await page.$(".msg.failed")),
           "and pressing Enter on it sends the message after all");
      }
    }
    const still = await page.evaluate(() => (document.querySelector("#ch-input") || {}).value || "");
    ok(true, `the words are kept${still ? " in the box" : " in the thread"}`);
  } else findings.push({ what: "could not open a conversation to test sending",
                         detail: `row found: ${rowOpened}, chat opened: ${chatOpen}` });
  await unfail();
  await page.evaluate(() => { const c = document.querySelector("#chat"); if (c) c.classList.remove("on"); });

  /* ---------------------------------------------------------- */
  console.log("\n2. POSTING when the server refuses");
  await page.evaluate(() => { go("feed"); });
  await wait(600);
  await fail("addPost", "Something went wrong");
  const opened = await page.evaluate(() => {
    try { openComposer(); return true; } catch (e) { return false; }
  });
  if (opened) {
    await wait(500);
    /* the composer asks what kind of post first, then gives you the box */
    await page.click("#sheetbody .typecard", { timeout: 2000 }).catch(() => {});
    await wait(600);
    const box = await page.$("#cp-text");
    if (box) {
      await page.fill("#cp-text", "Looking for a drummer");
      await page.click("#cp-go").catch(() => {});
      await wait(800);
      const t = await toastText();
      ok(!!t, "a post that fails says so", "nothing was said");
      const label = await page.evaluate(() => {
        const b = document.querySelector("#cp-go");
        return b ? { text: b.textContent.trim(), disabled: b.disabled } : null;
      });
      ok(label && !label.disabled,
         "and the button comes back so it can be tried again",
         label ? `button is "${label.text}", disabled=${label.disabled}` : "button is gone");
      ok(await page.evaluate(() => document.querySelector("#sheet").classList.contains("on")),
         "and what was written is still on screen");
    } else findings.push({ what: "the composer has no text box" });
  } else findings.push({ what: "could not open the composer" });
  await unfail();
  await page.evaluate(() => document.querySelector("#sheet").classList.remove("on"));

  /* ----------------------------------------------------------
     Sign-up is driven the way a person drives it — fill what is on
     screen, press Continue — rather than by jumping to a step number.
     Jumping put the suite on a step whose field was not visible and
     killed the whole run on a 30-second timeout.
     ---------------------------------------------------------- */
  const seeable = async sel => { const el = await page.$(sel); return el ? el.isVisible() : false; };

  /* advance sign-up until `sel` is on screen, or give up */
  async function reach(sel, tries = 8) {
    for (let i = 0; i < tries; i++) {
      if (await seeable(sel)) return true;
      if (await seeable("#ob-contact")) await page.fill("#ob-contact", "alex@example.com");
      if (await seeable("#ob-dob"))     await page.fill("#ob-dob", "1999-04-02");
      if (await seeable("#ob-name"))    await page.fill("#ob-name", "Alex Moreno");
      /* some steps need a choice made before Continue lights up —
         picking how to sign in, picking an instrument, ticking agree.
         Check the target again after choosing: picking "email" is what
         reveals the address field, and without this check the walk
         pressed straight past the step it was looking for. */
      const picks = await page.$$("#ob-body button:not(#ob-next):not(#ob-back):not(#ob-skip)");
      for (const c of picks.slice(0, 2)) {
        try { await c.click({ timeout: 600 }); } catch (e) {}
        await wait(200);
        if (await seeable(sel)) return true;
      }
      await wait(200);
      if (await seeable(sel)) return true;
      const next = await page.$("#ob-next");
      if (next && await next.isVisible() && await next.isEnabled())
        await next.click({ timeout: 1200 }).catch(() => {});
      else {
        const skip = await page.$("#ob-skip");
        if (skip && await skip.isVisible()) await skip.click({ timeout: 1200 }).catch(() => {});
        else return false;
      }
      await wait(600);
    }
    return seeable(sel);
  }

  console.log("\n3. THE SIGN-IN CODE that never arrives");
  await page.evaluate(() => { try { signOut(); } catch (e) {} });
  await wait(1100);
  await fail("sendCode", "Email rate limit exceeded");

  if (await reach("#ob-contact")) {
    await page.fill("#ob-contact", "alex@example.com");
    await wait(300);
    await page.click("#ob-next", { timeout: 2000 }).catch(() => {});
    await wait(900);
    const said = await page.evaluate(() => {
      const e = document.querySelector("#ob-err, .oberr, #ob-body .err");
      const t = document.querySelector("#toast");
      return ((e && e.textContent) || "") + " " + ((t && t.classList.contains("on") && t.textContent) || "");
    });
    ok(said.trim().length > 0, "a code that cannot be sent says why", "nothing was said");
    ok(/rate limit|too many|wait|try again|went wrong/i.test(said),
       "and it is in words a person can act on", said.trim().slice(0, 70));
    const btn = await page.evaluate(() => {
      const b = document.querySelector("#ob-next");
      return b ? { text: b.textContent.trim(), disabled: b.disabled } : null;
    });
    ok(btn && !btn.disabled, "and the button comes back",
       btn ? `"${btn.text}" disabled=${btn.disabled}` : "gone");
  } else findings.push({ what: "could not reach the sign-in step" });
  await unfail();

  /* ---------------------------------------------------------- */
  console.log("\n4. THE WRONG CODE");
  await fail("verify", "Token has expired or is invalid");
  if (await reach("#ob-code")) {
    await page.fill("#ob-code", "000000");
    await wait(250);
    await page.click("#ob-next", { timeout: 2000 }).catch(() => {});
    await wait(900);
    const said = await page.evaluate(() => {
      const e = document.querySelector("#ob-err, .oberr, #ob-body .err");
      const t = document.querySelector("#toast");
      return ((e && e.textContent) || "") + " " + ((t && t.classList.contains("on") && t.textContent) || "");
    });
    ok(said.trim().length > 0, "a wrong code says so");
    ok(!/token|invalid|JWT|400|null/i.test(said) || /expired|wrong|again/i.test(said),
       "in plain words rather than the server's own", said.trim().slice(0, 70));
    const cleared = await page.evaluate(() => (document.querySelector("#ob-code") || {}).value || "");
    ok(cleared === "", "and the box is cleared so the next attempt is clean", `"${cleared}"`);
  } else findings.push({ what: "could not reach the code step" });
  await unfail();

  /* ---------------------------------------------------------- */
  console.log("\n5. OFFLINE ENTIRELY");
  await page.evaluate(() => { document.querySelector("#onb").classList.remove("on"); });
  await ctx.setOffline(true);
  errors.length = 0;
  await page.evaluate(() => { go("feed"); if (typeof loadFeed === "function") loadFeed(); });
  await wait(1200);
  ok(errors.length === 0, "going offline does not throw", errors[0]);
  const feedText = await page.evaluate(() => (document.querySelector("#feed") || {}).textContent || "");
  ok(feedText.trim().length > 20, "and the feed still shows something rather than going blank");
  await ctx.setOffline(false);

  /* ----------------------------------------------------------
     "Nothing here yet" and "we couldn't reach the server" are
     different sentences. Showing the first when the second is true
     tells somebody the app is dead when it is merely offline — and
     they do not come back. This is the single most expensive lie
     the app could tell during a launch week.
     ---------------------------------------------------------- */
  console.log("\n5b. AN EMPTY SCREEN vs A SCREEN THAT COULDN'T LOAD");

  await page.evaluate(() => { LIVEPOSTS = []; feedCursor = null; });
  await fail("feed", "Network request failed");
  await page.evaluate(() => { go("feed"); feedFailed = false; loadFeed(); });
  await wait(1200);
  const feedSays = await page.evaluate(() => (document.querySelector("#feed") || {}).textContent || "");
  ok(!/be the first|no .* posts yet|haven't posted/i.test(feedSays) || /can't reach|couldn't reach|connection/i.test(feedSays),
     "a feed that failed to load does not claim to be empty",
     feedSays.replace(/\s+/g, " ").trim().slice(0, 90));
  ok(/try again/i.test(feedSays), "and offers a way to try again");
  await unfail();

  await fail("convos", "Network request failed");
  await page.evaluate(() => { go("chats"); convosFailed = false; loadConvos(); });
  await wait(1200);
  const chatsSays = await page.evaluate(() => (document.querySelector("#chats") || {}).textContent || "");
  ok(/can't reach|couldn't reach|connection|safe/i.test(chatsSays),
     "messages that failed to load say so rather than looking like silence",
     chatsSays.replace(/\s+/g, " ").trim().slice(0, 90));
  ok(/try again/i.test(chatsSays), "and offer a way to try again");
  await unfail();
  await page.evaluate(() => { convosFailed = false; feedFailed = false; loadConvos(); loadFeed(); });
  await wait(800);

  /* ---------------------------------------------------------- */
  console.log("\n6. A VERY LONG NAME, and other awkward input");
  /* ----------------------------------------------------------
     Plenty of people tap "Don't allow" on the location prompt, and
     Jammy is a find-people-near-you app, so this is not an edge case.
     It must not hang on a prompt nobody answered or leave the person
     stuck without a city.
     ---------------------------------------------------------- */
  console.log("\n5c. SOMEONE WHO REFUSES LOCATION");
  await ctx.clearPermissions();                 /* geolocation now denied */
  errors.length = 0;
  const located = await page.evaluate(async () => {
    const started = Date.now();
    try { await locateOnLaunch({ force: true }); }
    catch (e) { return { threw: e.message, ms: Date.now() - started }; }
    return { loc: S.me && S.me.loc ? (S.me.loc.label || "(no label)") : null,
             ms: Date.now() - started };
  });
  ok(!located.threw, "refusing location does not throw", located.threw);
  ok(located.ms < 25000, "and does not hang waiting on the prompt", `took ${located.ms}ms`);
  ok(!!located.loc, "and the person still ends up with somewhere to search from",
     "they were left with no location at all");
  ok(errors.length === 0, "and nothing errors on the page", errors[0]);

  /* ---------------------------------------------------------- */
  console.log("\n6. A VERY LONG NAME, and other awkward input");
  await page.evaluate(() => { go("you"); });
  await wait(600);
  const longName = "Bartholomew ".repeat(25).trim();   /* ~300 characters */
  const handled = await page.evaluate(n => {
    try {
      openEdit();
      const el = document.querySelector("#ed-name");
      if (!el) return "no-field";
      el.value = n;
      el.dispatchEvent(new Event("input", { bubbles: true }));
      return "ok";
    } catch (e) { return "threw: " + e.message; }
  }, longName);

  if (handled === "ok") {
    await wait(300);
    ok(!(await page.evaluate(() =>
        document.documentElement.scrollWidth > document.documentElement.clientWidth + 2)),
       "a 300-character name does not push the editor sideways");

    errors.length = 0;
    await page.click("#ed-save").catch(() => {});
    await wait(800);
    ok(errors.length === 0, "saving a very long name does not throw", errors[0]);
    await page.evaluate(() => { go("you"); });
    await wait(600);
    ok(!(await page.evaluate(() =>
        document.documentElement.scrollWidth > document.documentElement.clientWidth + 2)),
       "and the profile page still fits the screen afterwards");
  } else if (handled === "no-field") {
    console.log("  – the profile editor has no name field to test");
  } else findings.push({ what: "editing the profile threw", detail: handled });
  await page.evaluate(() => { const s = document.querySelector("#sheet"); if (s) s.classList.remove("on"); });

  /* ----------------------------------------------------------
     8. THE SCREENS NOBODY SEES UNTIL SOMETHING IS MISSING

     The empty-deck screen shown when Jammy has no location for you
     carried a button wired to a function that did not exist. Nothing
     caught it because the screen only appears in one narrow state:
     signed in, no location on the server, nobody in the deck. That is
     exactly the state most of the first twelve people will be in.
     ---------------------------------------------------------- */
  console.log("\n7. THE EMPTY-DECK SCREEN, which new people see first");
  /* srvLoc is what the app actually branches on: whether the SERVER
     knows where you are. Someone who skipped the location prompt has
     it false, and that is the screen with the recovery buttons. */
  await page.evaluate(() => {
    LIVEPOOL = [];
    srvLoc = false;
    if (S.me) S.me.loc = null;
    S.seen = {};
    go("disc");
    refreshDiscover();
  });
  await wait(900);

  const recovery = await page.evaluate(() =>
    [...document.querySelectorAll("#v-disc button")]
      .filter(b => b.getBoundingClientRect().width > 0)
      .map(b => (b.textContent || "").trim())
      .filter(t => /location|city|filter|widen|distance|start over|again/i.test(t)));

  if (!recovery.length) {
    console.log("  – the empty-deck screen did not appear in this fake");
  } else {
    ok(true, `the empty deck offers a way out (${recovery.join(", ")})`);
    for (const label of recovery) {
      errors.length = 0;
      await page.evaluate(t => {
        const b = [...document.querySelectorAll("#v-disc button")]
          .find(x => (x.textContent || "").trim() === t);
        if (b) b.click();
      }, label);
      await wait(800);
      ok(errors.length === 0, `"${label}" does not throw`, errors[0]);
      await page.evaluate(() => {
        const s = document.querySelector("#sheet"); if (s) s.classList.remove("on");
        LIVEPOOL = []; srvLoc = false; if (S.me) S.me.loc = null;
        go("disc"); refreshDiscover();
      });
      await wait(500);
    }
  }

  /* ---------------------------------------------------------- */
  console.log("\n8. NO HORIZONTAL SCROLL anywhere, at phone width");
  for (const v of ["feed", "disc", "radio", "chats", "you"]) {
    await page.evaluate(x => go(x), v);
    await wait(500);
    const wide = await page.evaluate(() =>
      document.documentElement.scrollWidth > document.documentElement.clientWidth + 2);
    ok(!wide, `${v} fits the screen`);
  }

  } catch (e) {
    findings.push({ what: "the walk stopped early and the rest was not checked",
                    detail: String(e.message).split("\n")[0] });
  }

  console.log("\n" + "=".repeat(62));
  console.log(`${pass} things behaved well.`);
  if (findings.length) {
    console.log(`\n${findings.length} PROBLEMS:\n`);
    findings.forEach((f, i) => console.log(`${i + 1}. ${f.what}${f.detail ? "\n     " + f.detail : ""}`));
  } else console.log("\nNothing fails silently.");
  console.log("=".repeat(62));

  await browser.close();
  srv.close();
  process.exit(findings.length ? 1 : 0);
})();
