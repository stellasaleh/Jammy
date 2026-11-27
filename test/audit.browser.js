/* ============================================================
   JAMMY — audit.browser.js
   Being a user, in a real browser, and writing down everything
   that gets in the way.

   This is not the smoke test. The smoke test asks "does each
   control do something". This asks "can a person actually get
   through", and it starts where the first twelve people start:
   a brand-new account on a Jammy where nobody else is yet.

   An empty app is the hardest version of a social app to get
   right and the easiest one to never look at, because every
   screenshot anybody takes has data in it.

     node test/audit.browser.js
     node test/audit.browser.js --populated
   ============================================================ */

const { chromium } = require("playwright");
const fs = require("fs");
const http = require("http");
const path = require("path");

const ROOT = process.env.ROOT || "/mnt/user-data/outputs/jammy/www";
const POPULATED = process.argv.includes("--populated");
const PORT = 8160 + (POPULATED ? 1 : 0);

/* ---------- findings ---------- */
const findings = [];
let checks = 0;
function note(where, what, detail) {
  findings.push({ where, what, detail });
  console.log(`  ✗ ${where}: ${what}${detail ? " — " + detail : ""}`);
}
function good(what) { checks++; console.log(`  ✓ ${what}`); }
function expect(cond, where, what, detail) {
  checks++;
  if (!cond) { checks--; note(where, what, detail); return false; }
  console.log(`  ✓ ${what}`);
  return true;
}

/* ---------- the fake server, deliberately EMPTY by default ----------
   A new Jammy has no people, no posts, no bands, no chart and no
   conversations. That is the state every invited person arrives in,
   and the one nothing has been tested against. */
const FAKE = `
window.__calls = [];
window.__fail = {};            // set a key to make that call fail
const log = n => window.__calls.push(n);
const ok  = d => Promise.resolve({ data: d, error: null });
const bad = m => Promise.resolve({ data: null, error: { message: m } });
const maybe = (name, d) => window.__fail[name] ? bad(window.__fail[name]) : ok(d);

const POP = ${POPULATED};

const me = { id:"u1", display_name:"Alex Moreno", handle:"alexmoreno", city:"Boston",
  bio:"", instruments:["Guitar"], genres:["Indie"], looking_for:"Form a band",
  looking_for_instruments:["Drums"], rehearsal_days:["Wed"], photo_path:null,
  /* The real server stopped returning birth_date to anybody in
     23_columns.sql, so the fake must stop too — otherwise the app is
     being tested against a server that no longer exists. */
  has_location:true, terms_agreed_at:new Date().toISOString(),
  remote_ok:false, is_banned:false };

const people = POP ? [
  { id:"u5", display_name:"Rue Delacroix", handle:"rue", city:"Boston",
    instruments:["Drums"], genres:["Indie"], looking_for:"Join a band",
    looking_for_instruments:["Guitar"], bio:"Drums, mostly loud.",
    photo_path:null, miles:2.1, shared_genres:["Indie"], they_need_me:["Guitar"],
    is_remote:false, fit:88 }
] : [];

window.__api = {
  sb: { rpc: (n,a) => { log("rpc:"+n);
          if (n === "weekly_chart")  return maybe("chart", POP ? chart : []);
          if (n === "listening_now") return ok(POP ? 2 : 0);
          if (n === "rising_track")  return ok(POP ? rising : []);
          if (n === "tracks_by")     return ok(POP ? mytracks : []);
          if (n === "my_posts" || n === "posts_by") return ok([]);
          if (n === "add_post")      return maybe("addPost", "newpost");
          if (n === "band_page")     return ok([]);
          if (n === "rising_track")  return ok([]);
          return ok([]); },
        functions: { invoke: () => ok(null) } },
  auth: { session: () => ok({ session: { access_token: "x" } }),
          signOut: () => { log("signOut"); return ok({}); }, onChange: () => {},
          sendEmailCode: (e) => { log("sendCode:"+e); return maybe("sendCode", {}); },
          sendPhoneCode: (e) => { log("sendCode:"+e); return maybe("sendCode", {}); },
          verifyEmail: (e,c) => { log("verify:"+c); return maybe("verify", { user:{ id:"u1" } }); },
          verifyPhone: (e,c) => { log("verify:"+c); return maybe("verify", { user:{ id:"u1" } }); } },
  profile: { mine: () => maybe("profile", POP ? me : null),
             create: (p) => { log("profile.create"); return maybe("profileCreate", p); },
             update: (p) => { log("profile.update"); return maybe("profileUpdate", p); },
             setLocation: () => { log("setLocation"); return ok({}); },
             byId: (id) => ok(people.find(p=>p.id===id) || null),
             uploadPhoto: () => ok("u1/p.jpg"), photoUrl: p => p ? "/_m/"+p : null },
  discover: { find: () => { log("discover"); return maybe("discover", people); },
              swipe: (to,d) => { log("swipe:"+to+":"+d); return maybe("swipe", [{matched:true, conversation_id:"c1"}]); },
              connections: () => ok(POP ? [{id:"u5",display_name:"Rue Delacroix",handle:"rue",photo_path:null,city:"Boston"}] : []),
              requests: () => maybe("requests", POP ? [{swipe_id:"s1",from_id:"u5",display_name:"Rue Delacroix",handle:"rue",photo_path:null,city:"Boston",instruments:["Drums"],genres:["Indie"],miles:2.1,created_at:new Date().toISOString()}] : []),
              requestCount: () => ok(POP ? 1 : 0),
              answerRequest: (id,yes) => { log("answerRequest:"+id+":"+yes); return maybe("answer", [{matched:yes, conversation_id:"c1"}]); } },
  chat: { list: () => maybe("convos", POP ? convos : []),
          messages: () => ok([]),
          send: (c,b) => { log("send:"+b); return maybe("send", { id:"m1" }); },
          dmWith: () => ok("c1"), bandConversation: () => ok("c2"),
          subscribe: () => ({}), unsubscribe: () => {}, watchPosts: () => ({}), markRead: () => ok({}),
          people: () => ok([]) },
  feed: { posts: () => maybe("feed", POP ? feed : []),
          comments: () => ok([]), comment: () => ok({}), deleteComment: () => ok({}),
          subscribeComments: () => ({}), unsubscribe: () => {},
          like: () => ok([{like_count:1}]), likers: () => ok([]), post: () => ok({}),
          upload: () => { log("feed.upload"); return maybe("mediaUpload","u1/x.jpg"); },
          mediaUrl: p => p ? "/_m/"+p : null,
          remove: (id) => { log("feed.remove:"+id); return ok(null); } },
  bands: { mine: () => maybe("bands", POP ? bands : []),
           roster: () => ok(POP ? roster : []), schedule: () => ok([]),
           create: (f) => { log("band.create:"+f.name);
             if (window.__fail.bandCreate) return bad(window.__fail.bandCreate);
             bands.push({id:"b9",name:f.name,city:f.city||"",genres:f.genres||[],about:"",
               avatar_path:null,my_role:"Guitar",i_am_admin:true,member_count:1,
               next_kind:null,next_at:null,next_place:null});
             return ok("b9"); },
           join: () => ok(false), leave: () => ok(true),
           addEvent: (b,e) => { log("addEvent:"+e.kind); return maybe("addEvent","e1"); },
           cancelEvent: () => ok(true), schedule_mine: () => ok([]),
           gigsNearMe: () => { log("gigsNearMe"); return maybe("gigs", POP ? gigs : []); },
           page: () => ok([]), askToJoin: () => ok("sent"),
           requests: () => ok([]), requestCount: () => ok(0),
           answerRequest: () => ok(true), removeMember: () => ok(true),
           media: () => ok([]) },
  clips: { send: (c,b,m) => { log("sendClip"); return maybe("clip", { id:"m1" }); },
           url: p => ok({ signedUrl: "/_t/"+p }) },
  radio: { chart: () => ok(POP ? chart : []), logPlay: () => ok(null),
           upload: (b,m) => { log("uploadTrack"); return maybe("uploadTrack", { id:"t9" }); },
           url: p => p ? "/_t/"+p : null,
           mine: () => ok(POP ? mytracks : []),
           removeTrack: () => ok(true) },
  account: { export: () => ok({ profile: me, posts: [] }),
             remove: () => { log("deleteAccount"); return ok({ deleted:true }); } },
  safety: { block: () => ok({}), unblock: () => ok({}), report: () => ok({}), disconnect: () => ok({}),
            blocked: () => ok([]) },
};

const convos = [{ id:"c1", kind:"dm", other_id:"u5", other_name:"Rue Delacroix",
  other_handle:"rue", other_photo:null, last_body:"hello", unread:0,
  last_at:new Date().toISOString(), messages:[] }];
const feed = [{ id:"f1", author_id:"u5", body:"Looking for a guitarist.", tag:"looking",
  track_id:null, media_path:null, fields:{instrument:"Guitar"},
  created_at:new Date().toISOString(), like_count:0, comment_count:0,
  author_name:"Rue Delacroix", author_handle:"rue", author_city:"Boston",
  author_photo:null, liked_by_me:false, mine:false }];
const bands = [{ id:"b1", name:"The Fog Signals", city:"Boston", genres:["Indie"],
  about:"", avatar_path:null, my_role:"Guitar", i_am_admin:true, member_count:1,
  next_kind:null, next_at:null, next_place:null }];
const roster = [{ user_id:"u1", display_name:"Alex Moreno", handle:"alexmoreno",
  photo_path:null, instruments:["Guitar"], role_label:"Guitar", is_admin:true, on_jammy:true }];
const chart = [{ track_id:"t1", title:"First Take", key:"Am", bpm:100,
  audio_path:"u5/t1.mp3", owner_id:"u5", artist_name:"Rue Delacroix",
  artist_handle:"rue", artist_photo:null, plays:4, listeners:2,
  last_week_rank:null, rank:1, is_new:true, move:0, mine:false }];
const rising = [{ track_id:"t1", title:"First Take", key:"Am", bpm:100,
  audio_path:"u5/t1.mp3", duration_ms:60000, plays:0, artist_id:"u5",
  artist_name:"Rue Delacroix", artist_handle:"rue", artist_photo:null,
  artist_city:"Boston", artist_bio:"Drums.", artist_instruments:["Drums"],
  artist_genres:["Indie"], shared_genres:["Indie"], miles:2.1, uploaded_days_ago:0 }];
const mytracks = [{ id:"t2", title:"My Demo", key:"C", bpm:92,
  audio_path:"u1/tracks/mine.mp3", is_public:true,
  created_at:new Date().toISOString(), plays:0 }];
const gigs = [{ event_id:"e1", band_id:"b1", band_name:"The Fog Signals",
  band_genres:["Indie"], band_avatar:null,
  starts_at:new Date(Date.now()+6*864e5).toISOString(),
  place:"The Middle East", city:"Boston", miles:2.0, i_am_member:false }];

window.JammyAPI = window.__api;
window.JAMMY_LIVE = true;
`;

/* a real, silent sound file for any audio the app opens */
const SILENT_WAV = (() => {
  const n = 8000, b = Buffer.alloc(44 + n);
  b.write("RIFF", 0); b.writeUInt32LE(36 + n, 4); b.write("WAVE", 8);
  b.write("fmt ", 12); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20);
  b.writeUInt16LE(1, 22); b.writeUInt32LE(8000, 24); b.writeUInt32LE(8000, 28);
  b.writeUInt16LE(1, 32); b.writeUInt16LE(8, 34);
  b.write("data", 36); b.writeUInt32LE(n, 40); b.fill(128, 44);
  return b;
})();

const TYPES = { ".html":"text/html", ".js":"text/javascript", ".png":"image/png",
                ".webmanifest":"application/manifest+json", ".css":"text/css" };

(async () => {
  const srv = http.createServer((req, res) => {
    const u = req.url.split("?")[0];
    if (u === "/api.js") {
      res.writeHead(200, { "Content-Type": "text/javascript" }); res.end(FAKE); return;
    }
    if (u.startsWith("/_t/") || u.startsWith("/_m/")) {
      res.writeHead(200, { "Content-Type": "audio/wav" }); res.end(SILENT_WAV); return;
    }
    const f = path.join(ROOT, u === "/" ? "index.html" : u);
    fs.readFile(f, (e, d) => {
      if (e) { res.writeHead(404); res.end("no"); return; }
      res.writeHead(200, { "Content-Type": TYPES[path.extname(f)] || "text/plain" });
      res.end(d);
    });
  });
  await new Promise(r => srv.listen(PORT, r));

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await ctx.newPage();

  const errors = [];
  page.on("pageerror", e => errors.push(String(e.message)));
  page.on("console", m => {
    if (m.type() !== "error") return;
    const t = m.text();
    /* This machine's proxy blocks the font host. The page has a real
       fallback stack, so it is this container's limit and not a bug. */
    if (/ERR_TUNNEL_CONNECTION_FAILED|fonts\.(googleapis|gstatic)/.test(t)) return;
    errors.push("console: " + t);
  });

  const $ = s => page.$(s);
  const txt = async s => { try { return (await page.textContent(s)) || ""; } catch (e) { return ""; } };
  const vis = async s => { const el = await page.$(s); return el ? el.isVisible() : false; };
  const calls = () => page.evaluate(() => window.__calls.slice());
  const clearCalls = () => page.evaluate(() => { window.__calls = []; });
  const wait = ms => page.waitForTimeout(ms);

  /* a real click that reports WHY it could not happen */
  async function tap(sel, timeout = 2500) {
    try { await page.click(sel, { timeout }); return null; }
    catch (e) {
      const m = String(e.message);
      if (/intercepts pointer events/.test(m))
        return "something is on top of it: " + (m.match(/<[^>]+>/) || [""])[0];
      if (/not visible|outside of the viewport/.test(m)) return "it is not on screen";
      if (/Timeout/.test(m)) return "it never became clickable";
      return m.split("\n")[0];
    }
  }

  console.log("=".repeat(62));
  console.log(POPULATED ? "BEING A USER — with other people around"
                        : "BEING A USER — brand new, on an empty Jammy");
  console.log("=".repeat(62));

  /* ---------------------------------------------------------- */
  /* The fake's coverage is checked in the page, against the real object,
     after it loads. A gap in the fake looks exactly like a bug in the app
     — that is how the missing method turned up, as the Chats tab throwing
     — so it is worth knowing up front. */
  const APICALLS = (() => {
    const src = fs.readFileSync(path.join(ROOT, "index.html"), "utf8");
    const out = new Set();
    for (const m of src.matchAll(/JammyAPI\.(\w+)\.(\w+)\s*\(/g)) out.add(m[1] + "." + m[2]);
    return [...out];
  })();

  console.log("\n1. ARRIVING for the first time");
  await page.goto(`http://localhost:${PORT}/index.html`);
  await wait(1200);

  {
    const missing = await page.evaluate(keys => keys.filter(k => {
      const [g, fn] = k.split(".");
      return !(window.JammyAPI && window.JammyAPI[g] && typeof window.JammyAPI[g][fn] === "function");
    }), APICALLS);
    expect(missing.length === 0, "harness",
           `the fake answers all ${APICALLS.length} calls the app makes`,
           "missing: " + missing.join(", "));
  }

  /* Two different people arrive here. Someone with no profile should be
     asked to sign up. Someone who already has one should be let straight
     in — being asked to sign up all over again is its own bug. */
  const onbShown = await vis("#onb");
  if (POPULATED)
    expect(!onbShown, "arrival", "someone who already has a profile is let straight in",
           "they were shown sign-up again");
  else
    expect(onbShown, "arrival", "a first-time visitor is shown onboarding");
  expect(errors.length === 0, "arrival", "the page loads without an error", errors[0]);

  /* ----------------------------------------------------------
     Drive whatever step the app is actually on, rather than
     assuming it starts at the beginning. A person who has
     verified their email but has no profile yet lands partway
     through, and that is a real arrival too.
     ---------------------------------------------------------- */
  console.log("\n2. SIGNING UP, step by step");

  const stepNow = () => page.evaluate(() =>
    (typeof STEPS !== "undefined" && typeof obStep !== "undefined") ? STEPS[obStep].id : null);

  const seen = [];
  /* Nothing to walk if sign-up is not on screen. Judging an invisible
     step for having no heading is how the last run produced two findings
     about a screen nobody was looking at. */
  for (let guard = 0; onbShown && guard < 16; guard++) {
    const id = await stepNow();
    if (!id) break;
    if (seen.filter(x => x === id).length >= 3) {
      note("onboarding", `the "${id}" step repeats and never moves on`);
      break;
    }
    seen.push(id);
    errors.length = 0;

    const heading = (await txt("#ob-body h1, #ob-body h2, #ob-body [role=heading]")).trim();
    if (!heading) note(id, "the step has no heading, so it is not clear what is being asked");

    if (id === "done") {
      good("sign-up reaches the end");
      const why = await tap("#ob-next", 2500);
      if (why) note("done", "the last button cannot be pressed", why);
      await wait(900);
      break;
    }

    /* fill in whatever this step asks for */
    if (await $("#ob-contact")) await page.fill("#ob-contact", "alex@example.com");
    if (await $("#ob-code"))    await page.fill("#ob-code", "12345678");
    if (await $("#ob-dob"))     await page.fill("#ob-dob", "1999-04-02");
    if (await $("#ob-name"))    await page.fill("#ob-name", "Alex Moreno");
    if (await $("#ob-handle"))  await page.fill("#ob-handle", "alexmoreno");
    if (await $("#ob-city"))    await page.fill("#ob-city", "Boston");
    await wait(260);

    /* and tick whatever it offers to choose */
    const picks = await page.$$("#ob-body button:not(#ob-next):not(#ob-back):not(#ob-skip)");
    for (const c of picks.slice(0, 2)) { try { await c.click({ timeout: 700 }); } catch (e) {} }
    await wait(240);

    const next = await page.$("#ob-next");
    const enabled = next ? await next.isEnabled() : false;
    const skip = await page.$("#ob-skip");
    const canSkip = skip ? await skip.isVisible() : false;

    if (!next && !canSkip) { note(id, "there is no way forward from this step"); break; }

    if (enabled) {
      const why = await tap("#ob-next", 2000);
      if (why) { note(id, "the Continue button cannot be pressed", why); break; }
    } else if (canSkip) {
      await tap("#ob-skip", 2000);
    } else {
      const label = next ? (await next.textContent()).trim() : "";
      note(id, `"${label || "Continue"}" stays greyed out after filling the step in`,
           "nothing on screen says what is missing");
      break;
    }

    await wait(650);
    if (errors.length) note(id, "moving on from this step threw an error", errors[0]);
  }

  const finished = await page.evaluate(() => {
    try { return !document.querySelector("#onb").classList.contains("on"); } catch (e) { return true; }
  });
  if (!onbShown) console.log("  – already signed in, so there was no sign-up to walk");
  else if (!finished) {
    note("onboarding", "a new person cannot get all the way through sign-up",
         "stuck at: " + (await stepNow()));
    await page.evaluate(() => { try { document.querySelector("#onb").classList.remove("on"); } catch (e) {} });
  } else good("a new person can get all the way through sign-up");
  await wait(900);

  /* ---------------------------------------------------------- */
  console.log("\n4. THE FIVE TABS — what is actually on them");
  const TABS = [
    ["feed",  "#feed",   "Feed"],
    ["disc",  "#v-disc", "Discover"],
    ["radio", "#radio",  "Radio"],
    ["chats", "#chats",  "Chats"],
    ["you",   "#you",    "Your profile"],
  ];

  for (const [key, sel, label] of TABS) {
    errors.length = 0;
    await page.evaluate(k => go(k), key);
    await wait(900);

    const body = (await txt(sel)).replace(/\s+/g, " ").trim();
    expect(errors.length === 0, label, `opening ${label} does not throw`, errors[0]);

    /* A screen with nothing on it is the thing to catch. An empty screen
       is fine; an empty screen that says nothing is a dead end. */
    if (body.length < 25) {
      note(label, "the screen is blank, with nothing to explain why");
    } else if (!POPULATED) {
      /* on an empty Jammy every screen has to say what to do next */
      const explains = /no |none|nothing|yet|be the first|invite|start|upload|add |looking/i.test(body);
      expect(explains, label, `${label} explains itself when empty`,
             body.slice(0, 80));
    } else good(`${label} has something on it`);
  }

  /* ---------------------------------------------------------- */
  console.log("\n5. PRESSING EVERYTHING ON EVERY TAB");
  /* ----------------------------------------------------------
     Press every control, and say which one by NAME.

     The first version of this walked buttons by position and
     reported "button 3". Two things were wrong with that. A
     number tells nobody which control is broken. Worse, the
     first control on Discover switches the whole tab between
     People and Gigs, so pressing it changed what the later
     positions pointed at, and the walk reported seven controls
     "not on screen" that were working perfectly — they were
     simply on the other mode. So: name each control before
     pressing it, and put any mode switch back the way it was
     found between presses.
     ---------------------------------------------------------- */

  /* what this tab looked like on arrival: the toggles that were lit */
  const snapshotModes = sel => page.evaluate(s =>
    [...document.querySelectorAll(s + " button")]
      .filter(b => b.classList.contains("on"))
      .map(b => (b.getAttribute("aria-label") || b.textContent || "").trim())
      .filter(Boolean), sel);

  /* put them back, so each press starts from the same screen */
  const restoreModes = (sel, lit) => page.evaluate(({ s, lit }) => {
    for (const name of lit) {
      const b = [...document.querySelectorAll(s + " button")].find(x =>
        (x.getAttribute("aria-label") || x.textContent || "").trim() === name);
      if (b && !b.classList.contains("on")) b.click();
    }
  }, { s: sel, lit });

  /* Only what a person could actually press. The markup holds controls
     belonging to the tab's other mode — Discover keeps the Gigs panel in
     the document while People is showing — and those are invisible on
     purpose. Counting them produced a finding against "Look anywhere",
     a button that works fine on the screen it belongs to. */
  const onScreen = s => page.evaluate(sel =>
    [...document.querySelectorAll(sel + " button")].filter(b => {
      const r = b.getBoundingClientRect();
      return r.width > 0 && r.height > 0 && b.offsetParent !== null;
    }).length, s);

  const nameOf = (sel, i) => page.evaluate(({ s, i }) => {
    const b = [...document.querySelectorAll(s + " button")].filter(x => {
      const r = x.getBoundingClientRect();
      return r.width > 0 && r.height > 0 && x.offsetParent !== null;
    })[i];
    if (!b) return null;
    b.setAttribute("data-audit", "a" + i);
    const t = (b.getAttribute("aria-label") || b.textContent || "").trim().replace(/\s+/g, " ");
    return { id: "a" + i, name: t ? `"${t.slice(0, 32)}"` : (b.id ? "#" + b.id : "an unlabelled button") };
  }, { s: sel, i });

  for (const [key, sel, label] of TABS) {
    await page.evaluate(k => go(k), key);
    await wait(700);
    const lit = await snapshotModes(sel);

    const n = await onScreen(sel);
    let pressed = 0; const stuck = [];
    for (let i = 0; i < Math.min(n, 14); i++) {
      /* re-read each time: a press re-renders and old handles go stale */
      const b = await nameOf(sel, i);
      if (!b) break;

      errors.length = 0;
      const why = await tap(`${sel} [data-audit="${b.id}"]`, 1500);
      if (why) stuck.push(`${b.name} cannot be pressed — ${why}`);
      else pressed++;
      await wait(220);

      if (errors.length) stuck.push(`${b.name} threw: ${errors[0]}`);

      /* close anything that opened, so the next press is not blocked */
      await page.evaluate(() => {
        ["#sheet", "#chat", "#bandview", "#mv"].forEach(s2 => {
          const el = document.querySelector(s2);
          if (el) el.classList.remove("on");
        });
      });
      await wait(120);
      await page.evaluate(k => go(k), key);
      await restoreModes(sel, lit);
      await wait(260);
    }
    if (stuck.length) stuck.forEach(s2 => note(label, s2));
    else good(`every control on ${label} responds (${pressed} pressed)`);
  }

  console.log("\n" + "=".repeat(62));
  console.log(`${checks} things worked.`);
  if (findings.length) {
    console.log(`\n${findings.length} ROADBLOCKS:\n`);
    findings.forEach((f, i) => console.log(`${i + 1}. [${f.where}] ${f.what}${f.detail ? "\n     " + f.detail : ""}`));
  } else console.log("\nNo roadblocks found.");
  console.log("=".repeat(62));

  await browser.close();
  srv.close();
  process.exit(findings.length ? 1 : 0);
})();
