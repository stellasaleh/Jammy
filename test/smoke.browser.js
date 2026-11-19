/* CLICK EVERYTHING.
   Opens the real app in a real browser, signed in, with a fake server
   underneath, and clicks every primary control — checking that something
   actually happens. A button that renders and does nothing passes every
   unit test ever written about the function behind it. Two have now
   shipped that way. */
const { chromium } = require("playwright");
const http = require("http"), fs = require("fs"), path = require("path");

const ROOT = "/home/claude/jammy/app";
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".png": "image/png",
                ".webmanifest": "application/manifest+json" };

let pass = 0, fail = 0;
const ok = (c, m) => { c ? (pass++, console.log("  ✓ " + m)) : (fail++, console.log("  ✗ " + m)); };

const FAKE_API = `
/* stands in for api.js so the real app talks to a server we control */
const rows = {
  profile: {id:"u1",handle:"stella",display_name:"Stella Saleh",city:"Boston",
            instruments:["Trumpet"],genres:["Jazz"],looking_for:"Form a band",
            rehearsal_days:["Wed"],location:"POINT(-71 42)",bio:""},
  people: [{id:"p1",display_name:"Mina Okafor",handle:"minabass",city:"Boston",
            instruments:["Bass"],genres:["Jazz"],looking_for:"A band",bio:"",
            photo_path:null,miles:2.4,shared_genres:["Jazz"],they_need_me:["Trumpet"],
            is_remote:false,fit:82}],
  bands: [{id:"band1",name:"The Flaming Weirdos",city:"Boston",genres:["Jazz"],
           about:"",avatar_path:null,my_role:"Horns",i_am_admin:true,member_count:1,
           next_kind:null,next_at:null,next_place:null}],
  roster: [{user_id:"u1",display_name:"Stella Saleh",handle:"stella",photo_path:null,
            instruments:["Trumpet"],role_label:"Horns",is_admin:true,on_jammy:true}],
  schedule: [],
  convos: [], requests: [], messages: []
};
window.__calls = [];
const okr = (d) => Promise.resolve({ data: d, error: null });
window.JammyAPI = {
  sb: { rpc: (n,a) => { window.__calls.push("rpc:"+n); return okr([]); },
        functions: { invoke: () => okr(null) } },
  auth: { session: () => okr({ session: { access_token: "x" } }),
          signOut: () => okr({}), onChange: () => {},
          sendEmailCode: () => okr({}), verifyEmail: () => okr({}) },
  profile: { mine: () => okr(rows.profile), setLocation: () => { window.__calls.push("setLocation"); return okr({}); },
             update: (p) => { window.__calls.push("profile.update"); return okr(p); },
             create: (f) => okr(rows.profile), get: () => okr(null) },
  discover: { find: () => { window.__calls.push("discover"); return okr(rows.people); },
              swipe: (id,d) => { window.__calls.push("swipe:"+d); return okr([{matched:false}]); },
              connections: () => okr([]),
              requests: () => { window.__calls.push("requests"); return okr(rows.requests); },
              requestCount: () => okr(0) },
  chat: { list: () => okr(rows.convos), dmWith: () => okr("c1"),
          bandConversation: () => okr("cb1"), people: () => okr([]),
          conversations: () => okr([]), messages: () => okr(rows.messages),
          send: (c,b) => { window.__calls.push("send"); return okr({id:"m1"}); },
          subscribe: () => ({}), unsubscribe: () => {}, markRead: () => okr({}) },
  bands: { mine: () => { window.__calls.push("bands.mine"); return okr(rows.bands); },
           roster: () => okr(rows.roster), schedule: () => okr(rows.schedule),
           create: (f) => { window.__calls.push("bands.create:"+f.name); return okr("band2"); },
           join: () => { window.__calls.push("bands.join"); return okr(true); },
           leave: () => { window.__calls.push("bands.leave"); return okr(true); },
           addEvent: (b,e) => { window.__calls.push("bands.addEvent:"+e.kind); return okr("ev1"); },
           cancelEvent: () => okr(true), schedule_mine: () => okr([]),
           gigsNearMe: () => okr([]), media: () => okr([]) },
  feed: { posts: () => okr([]), comments: () => okr([]), comment: () => okr({}),
          deleteComment: () => okr({}), subscribeComments: () => ({}), unsubscribe: () => {},
          like: () => okr({}), likers: () => okr([]), post: () => okr({}) },
  clips: { send: () => okr({}), url: () => okr("") },
  radio: { chart: () => okr([]), logPlay: () => okr({}) },
  safety: { blocked: () => okr([]), block: (id) => { window.__calls.push("block"); return okr({}); },
            unblock: () => okr({}), report: () => { window.__calls.push("report"); return okr({}); } },
};
`;

/* only this needs to run before the page does */
const PRIME = `try { localStorage.setItem("jammy:v1", JSON.stringify({ onboarded: true, firstRun: false })); } catch (e) {}`;

(async () => {
  const srv = http.createServer((req, res) => {
    const u = req.url.split("?")[0];
    if (u === "/api.js") {               // serve the fake in place of the real one
      res.writeHead(200, { "Content-Type": "text/javascript" });
      res.end(FAKE_API);
      return;
    }
    const f = path.join(ROOT, u === "/" ? "index.html" : u);
    fs.readFile(f, (e, d) => {
      if (e) { res.writeHead(404); res.end("no"); return; }
      res.writeHead(200, { "Content-Type": TYPES[path.extname(f)] || "text/plain" });
      res.end(d);
    });
  });
  await new Promise((r) => srv.listen(8111, r));

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 420, height: 900 } });
  await ctx.addInitScript(PRIME);
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => { if (!/TUNNEL|fonts\.g/.test(e.message)) errors.push(e.message); });
  page.on("console", (m) => { if (m.type() === "error" && !/TUNNEL|fonts\.g/.test(m.text())) errors.push(m.text()); });

  await page.goto("http://localhost:8111/index.html");
  await page.waitForTimeout(1200);

  const calls = () => page.evaluate(() => window.__calls.slice());
  const clear = () => page.evaluate(() => { window.__calls.length = 0; });
  /* A control that cannot be clicked is the failure we are hunting, so it
     must read as one line of output, not an exception that ends the walk. */
  const clickIt = async (sel, what) => {
    try {
      await page.click(sel, { timeout: 2500 });
      return true;
    } catch (e) {
      fail++;
      const why = /intercepts pointer events/.test(e.message)
        ? (e.message.match(/<[^>]*>/) || ["something"])[0] + " is on top of it"
        : "could not be clicked";
      console.log(`  ✗ ${what} — ${why}`);
      return false;
    }
  };

  const visible = (sel) => page.evaluate((s) => {
    const e = document.querySelector(s);
    if (!e) return false;
    const r = e.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && getComputedStyle(e).visibility !== "hidden";
  }, sel);

  console.log("\n-- the app opens --");
  ok(errors.length === 0, "no errors on load" + (errors.length ? " — " + errors[0] : ""));
  ok(await page.evaluate(() => window.JAMMY_LIVE === true), "running in live mode");
  ok((await calls()).includes("discover"), "it asks the server for people");

  console.log("\n-- the profile is the person's own, not a demo --");
  /* read what is drawn, not the app's own source */
  const shown = await page.evaluate(() => {
    let t = "";
    document.querySelectorAll("body *").forEach((e) => {
      if (e.tagName === "SCRIPT" || e.tagName === "STYLE") return;
      if (e.children.length === 0) t += " " + (e.textContent || "");
    });
    return t;
  });
  ok(!/Kitchen Demo/.test(shown), "no invented recording on the profile");
  ok(!/412/.test(shown), "no invented play count");
  ok((await page.evaluate(() => (window.S && S.me && S.me.tracks || []).length)) === 0,
     "a new account starts with no recordings at all");

  console.log("\n-- every tab opens --");
  for (const [tab, marker] of [["disc", "#deck"], ["feed", "#feed"], ["chats", "#chats"], ["radio", "#radio"], ["you", "#you"]]) {
    await page.evaluate((t) => go(t), tab).catch(() => {});
    await page.waitForTimeout(250);
    ok(await visible(marker), `${tab} opens`);
  }

  console.log("\n-- bands --");
  await page.evaluate(() => { go("you"); }); await page.waitForTimeout(300);
  await page.evaluate(() => openBandList()); await page.waitForTimeout(400);
  ok(await visible("#bandlist"), "the band list opens");

  clear();
  ok(!!(await page.$("#bl-add")), "there is an Add band button in the header");
  if (await clickIt("#bl-add", "the Add band button can be pressed")) {
    pass++; console.log("  ✓ the Add band button can be pressed");
    await page.waitForTimeout(400);
    ok(await visible("#sheet"), "it opens the Add band sheet");
    ok(!!(await page.$("#nb-name")), "with a name field");
  }

  if (await page.$("#nb-name")) {
    await page.fill("#nb-name", "The Buttheads");
    await page.fill("#nb-city", "Allston");
    clear();
    if (await clickIt("#nb-go", "the Add band button inside the sheet can be pressed")) {
      pass++; console.log("  ✓ the Add band button inside the sheet can be pressed");
      await page.waitForTimeout(600);
      ok((await calls()).some((x) => x.startsWith("bands.create")), "and it creates the band");
    }
  }

  console.log("\n-- discover --");
  await page.evaluate(() => go("disc")); await page.waitForTimeout(400);
  ok((await page.$$(".dcard")).length > 0, "there are cards to swipe");
  clear();
  if (await clickIt("#d-yes", "the yes button can be pressed")) {
    pass++; console.log("  ✓ the yes button can be pressed");
    await page.waitForTimeout(500);
    ok((await calls()).some((x) => x.startsWith("swipe:")), "and it records a swipe");
  }

  console.log("\n-- anything that renders but does nothing --");
  /* Click it and watch. A button wired by a shared handler has no onclick of
     its own, so the only honest test is whether pressing it changes anything. */
  const dead = await page.evaluate(async () => {
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    const label = (b) => (b.textContent || "").trim().slice(0, 28) || b.className || "button";
    const out = [];
    const seen = new Set();
    for (let i = 0; i < 40; i++) {
      const b = [...document.querySelectorAll("button:not([disabled])")].find((x) => {
        const r = x.getBoundingClientRect();
        return r.width > 4 && r.height > 4 && getComputedStyle(x).visibility !== "hidden" &&
               !seen.has(x) && !/sign out|delete|block|report|leave/i.test(label(x));
      });
      if (!b) break;
      seen.add(b);
      let changed = false;
      const obs = new MutationObserver(() => { changed = true; });
      obs.observe(document.body, { childList: true, subtree: true, attributes: true, characterData: true });
      const before = window.__calls.length;
      try { b.click(); } catch (e) { changed = true; }
      await sleep(90);
      obs.disconnect();
      if (!changed && window.__calls.length === before) out.push(label(b));
    }
    return out;
  });
  ok(dead.length === 0, dead.length ? `pressing these changed nothing: ${dead.join(" | ")}` : "every button does something when pressed");


  console.log("\n-- a wider walk: open every screen and press what is on it --");
  /* Each entry: a name, how to get there, and what should be visible when
     you arrive. Then every button on that screen gets pressed. */
  const screens = [
    ["your profile",        () => go("you"),                      "#you"],
    ["edit profile",        () => editProfile && editProfile(),    "#sheet"],
    ["the composer",        () => openComposer(),                  "#sheet"],
    ["filters",             () => { go("disc"); openFilters(); },  "#sheet"],
    ["a person's profile",  () => openProfile("p1"),               "#sheet"],
    ["the band list",       () => openBandList(),                  "#bandlist"],
    ["a band page",         () => openBand("band1"),               "#bandview"],
    ["add a date",          () => openAddEvent("band1"),           "#sheet"],
    ["settings",            () => openSettings && openSettings(),  "#sheet"],
    ["notifications",       () => openAlerts && openAlerts(),      "#sheet"],
  ];

  for (const [name, open, marker] of screens) {
    await page.evaluate(() => {
      ["#sheet", "#chat", "#call", "#bandview", "#bandlist"].forEach((s) => {
        const e = document.querySelector(s); if (e) e.classList.remove("on");
      });
    });
    let threw = null;
    try { await page.evaluate(open); } catch (e) { threw = e.message; }
    await page.waitForTimeout(350);
    if (threw && /is not (a function|defined)/.test(threw)) continue;   // screen not in this build
    ok(!threw, `${name} opens without throwing` + (threw ? " — " + threw.slice(0, 70) : ""));
    ok(await visible(marker), `${name} is actually on screen`);

    const dud = await page.evaluate(async (sel) => {
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      const root = document.querySelector(sel);
      if (!root) return [];
      const label = (b) => (b.textContent || "").trim().slice(0, 24) || b.className || "button";
      const out = [];
      /* Re-read the page every time. Pressing one control often re-renders
         the screen, and every button captured beforehand is then a stale
         node that is no longer in the document — clicking it does nothing,
         which looks exactly like a dead button and is not one. */
      const seen = new Set();
      for (let i = 0; i < 25; i++) {
        const live = document.querySelector(sel);
        if (!live || !live.classList.contains("on")) break;   // the screen closed
        const b = [...live.querySelectorAll("button:not([disabled])")].find((x) => {
          const r = x.getBoundingClientRect();
          return r.width > 4 && r.height > 4 && !seen.has(x) &&
                 !/sign out|delete|block|report|leave|unmatch|back|close/i.test(label(x));
        });
        if (!b) break;
        seen.add(b);
        let changed = false;
        const obs = new MutationObserver(() => { changed = true; });
        obs.observe(document.body, { childList: true, subtree: true, attributes: true, characterData: true });
        const before = window.__calls.length;
        try { b.click(); } catch (e) { changed = true; }
        await sleep(70);
        obs.disconnect();
        if (!changed && window.__calls.length === before) out.push(label(b));
      }
      return out;
    }, marker);
    ok(dud.length === 0, dud.length ? `${name}: nothing happens on — ${dud.join(" | ")}` : `${name}: every button responds`);
  }

  ok(errors.length === 0, "no errors during the whole walk" + (errors.length ? " — " + errors.slice(0, 2).join(" / ") : ""));

  console.log(`\n${pass} passed, ${fail} failed`);
  await browser.close();
  srv.close();
  process.exit(fail ? 1 : 0);
})();
