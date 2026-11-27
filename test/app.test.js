/* Headless test of the live sign-up path.
   Loads the real index.html in jsdom with a fake Supabase underneath,
   then walks onboarding the way a person would and checks that the app
   talks to the database at the right moments and survives failures. */
const fs = require("fs");
const { JSDOM } = require("jsdom");
const APP = process.env.APP || "/mnt/user-data/outputs/jammy/www/index.html";

let pass = 0, fail = 0;
const ok = (c, m) => { c ? (pass++, console.log("  ✓ " + m)) : (fail++, console.log("  ✗ " + m)); };

function makeAPI(opts = {}) {
  const log = [];
  const err = (m) => ({ data: null, error: new Error(m) });
  const api = {
    _log: log,
    _disconnected: new Set(),
    _blocked: new Set(),
    sb: { rpc: async (n, a) => {
            log.push("rpc:" + n);
            /* a few RPCs the app calls directly; the rest answer empty */
            if (n === "weekly_chart")   return { data: opts.chart || [], error: null };
            if (n === "listening_now")  return { data: opts.listeners ?? 0, error: null };
            if (n === "rising_track")   return { data: opts.rising || [], error: null };
            if (n === "add_post")       return opts.addPostFails ? err(opts.addPostFails) : { data: "newpost", error: null };
            if (n === "my_posts" || n === "posts_by") return { data: opts.myPosts || [], error: null };
            return { data: [], error: null };
          },
          functions: { invoke: async () => ({ data: null, error: new Error("no edge fn") }) } },
    auth: {
      sendEmailCode: async (e) => { log.push("sendEmailCode:" + e); return opts.sendFails ? err(opts.sendFails) : { data: {}, error: null }; },
      sendPhoneCode: async (p) => { log.push("sendPhoneCode:" + p); return { data: {}, error: null }; },
      verifyEmail: async (e, t) => { log.push("verifyEmail:" + t); return opts.verifyFails ? err(opts.verifyFails) : { data: { user: { id: "u1" } }, error: null }; },
      verifyPhone: async () => ({ data: {}, error: null }),
      signOut: async () => { log.push("signOut"); return { data: {}, error: null }; },
      session: async () => ({ data: { session: opts.session || null }, error: null }),
      user: async () => ({ data: { user: { id: "u1" } }, error: null }),
      onChange: () => {},
    },
    profile: {
      create: async (f) => { log.push("createProfile:" + f.handle); return opts.createFails ? err(opts.createFails) : { data: { id: "u1", handle: f.handle, display_name: f.name, city: f.city, instruments: f.instruments, genres: f.genres, looking_for: f.lookingFor, rehearsal_days: f.days }, error: null }; },
      mine: async () => { log.push("loadMe"); return opts.profile ? { data: opts.profile, error: null } : { data: null, error: null }; },
      /* setLocationFails lets a test hold srvLoc still. Saving a location
         successfully also sets it, so a test watching what the PROFILE
         READ decided is otherwise racing the location detector that runs
         a moment after boot. */
      setLocation: async () => { log.push("setLocation"); return opts.setLocationFails ? err(opts.setLocationFails) : { data: {}, error: null }; },
      get: async () => ({ data: null, error: null }),
      update: async () => ({ data: null, error: null }),
    },
    discover: {
      find: async (f) => { log.push("find:r" + (f && f.radius)); return opts.findFails ? err(opts.findFails) : { data: opts.people || [], error: null }; },
      swipe: async (id, dir) => { log.push("swipe:" + dir + ":" + id); return opts.swipeFails ? err(opts.swipeFails) : { data: [{ matched: !!opts.matched, conversation_id: opts.matched ? "c1" : null }], error: null }; },
      connections: async () => ({ data: [], error: null }),
      requests: async () => { log.push("requests"); return { data: opts.requests || [], error: null }; },
      requestCount: async () => ({ data: (opts.requests || []).length, error: null }),
    },
    chat: {
      /* the real my_conversations() drops anyone blocked either way, so the
         fake one must too, or tests pass against a server that does not exist */
      list: async () => {
        log.push("convoList");
        const rows = (opts.convos || [])
          .filter((c) => !api._blocked.has(c.other_id))
          .filter((c) => !api._disconnected.has(c.other_id));
        return { data: rows, error: null };
      },
      dmWith: async (u) => { log.push("dmWith:" + u); return { data: "c1", error: null }; },
      bandConversation: async (b) => ({ data: "cb1", error: null }),
      people: async () => ({ data: [], error: null }),
      conversations: async () => ({ data: [], error: null }),
      messages: async (c) => { log.push("thread:" + c); return opts.threadFails ? err(opts.threadFails) : { data: opts.messages || [], error: null }; },
      send: async (c, body) => { log.push("send:" + body); return opts.sendFails ? err(opts.sendFails) : { data: { id: "m99", created_at: "2026-11-18T12:00:00Z" }, error: null }; },
      subscribe: (c, cb) => { log.push("subscribe:" + c); api._push = cb; return { ch: c }; },
      unsubscribe: (ch) => { log.push("unsubscribe"); },
      /* records the handler so a test can play the part of somebody else
         posting, the way the real realtime channel would */
      watchPosts: (fn) => { log.push("watchPosts"); api._onNewPost = fn; return { ch: "feed:new" }; },
      markRead: async (c) => { log.push("markRead:" + c); return { data: {}, error: null }; },
    },
    feed: {
      upload: async (blob, kind) => { log.push("upload:" + kind); return opts.uploadFails ? err(opts.uploadFails) : { data: "u1/posts/x.jpg", error: null }; },
      mediaUrl: (p) => p ? "https://files.example/" + p : null,
      remove: async (id) => { log.push("deletePost:" + id); return opts.deletePostFails ? err(opts.deletePostFails) : { data: null, error: null }; }, posts: async (before, n, beforeId) => { log.push("feedPage:" + (before ? "more" : "first")); return { data: opts.feed || [], error: null }; }, comments: async () => ({ data: [], error: null }), comment: async () => ({ data: {}, error: null }), deleteComment: async () => ({ data: {}, error: null }), subscribeComments: () => ({}), unsubscribe: () => {}, like: async () => ({ data: {}, error: null }), likers: async () => ({ data: [], error: null }), post: async () => ({ data: {}, error: null }) },
    bands: {
      mine: async () => { log.push("myBands"); return { data: opts.bands || [], error: null }; },
      roster: async (b) => { log.push("roster:" + b); return { data: opts.roster || [], error: null }; },
      schedule: async (b) => { log.push("schedule:" + b); return { data: opts.bandEvents || [], error: null }; },
      create: async (f) => { log.push("createBand:" + f.name); return opts.createBandFails ? err(opts.createBandFails) : { data: "band1", error: null }; },
      join: async (b) => { log.push("joinBand:" + b); return { data: true, error: null }; },
      leave: async (b) => { log.push("leaveBand:" + b); return { data: true, error: null }; },
      addEvent: async (b, ev) => { log.push("addEvent:" + ev.kind + ":" + (ev.visibility || "")); return opts.addEventFails ? err(opts.addEventFails) : { data: "ev1", error: null }; },
      cancelEvent: async () => ({ data: true, error: null }),
      schedule_mine: async () => ({ data: [], error: null }),
      gigsNearMe: async (m, d) => { log.push("gigsNearMe:" + m); return { data: opts.gigs || [], error: null }; },
      page: async (b) => { log.push("bandPage:" + b); return { data: opts.bandPage ? [opts.bandPage] : [], error: null }; },
      askToJoin: async (b) => { log.push("askToJoin:" + b); return opts.askFails ? err(opts.askFails) : { data: "sent", error: null }; },
      removeMember: async (b, u) => { log.push("removeMember:" + b + ":" + u); return opts.removeFails ? err(opts.removeFails) : { data: true, error: null }; },
      requests: async (b) => { log.push("bandRequests:" + (b || "all")); return { data: opts.bandRequests || [], error: null }; },
      requestCount: async () => ({ data: (opts.bandRequests || []).length, error: null }),
      answerRequest: async (r, y) => { log.push("answerBandRequest:" + r + ":" + y); return opts.answerBandFails ? err(opts.answerBandFails) : { data: true, error: null }; },
      media: async () => ({ data: [], error: null }),
    },
    clips: {
      send: async (c, blob, meta) => { log.push("sendClip:" + c); return opts.clipFails ? err(opts.clipFails) : { data: { id: "m1" }, error: null }; },
      url: async (p) => ({ data: { signedUrl: "https://files.example/" + p }, error: null }),
    },
    radio: {
      chart: async () => ({ data: opts.chart || [], error: null }),
      logPlay: async (id, secs, src) => { log.push("logPlay:" + id + ":" + Math.round(secs)); return { data: null, error: null }; },
      upload: async (blob, meta) => { log.push("uploadTrack:" + (meta && meta.title)); return opts.uploadTrackFails ? err(opts.uploadTrackFails) : { data: { id: "t9" }, error: null }; },
      url: (p) => p ? "https://files.example/" + p : null,
      mine: async () => ({ data: opts.myTracks || [], error: null }),
      removeTrack: async (id) => { log.push("removeTrack:" + id); return opts.removeTrackFails ? err(opts.removeTrackFails) : { data: true, error: null }; },
    },
    account: {
      export: async () => { log.push("exportMyData"); return { data: opts.exportData || { profile: { display_name: "Stella Saleh" }, posts: [] }, error: null }; },
      remove: async (w) => { log.push("deleteAccount:" + w); return opts.deleteAccountFails ? err(opts.deleteAccountFails) : { data: { deleted: true }, error: null }; },
    },
    safety: {
      blocked: async () => ({ data: [], error: null }),
      block: async (id) => {
        log.push("block:" + id);
        if (opts.blockFails) return err(opts.blockFails);
        api._blocked.add(id);
        return { data: {}, error: null };
      },
      unblock: async (id) => { log.push("unblock:" + id); api._blocked.delete(id); return { data: {}, error: null }; },
      disconnect: async (id) => {
        log.push("disconnect:" + id);
        if (opts.disconnectFails) return err(opts.disconnectFails);
        /* the real server drops the DM from both people's lists, so a
           later convos() must not hand it back — otherwise this fake
           would report success on something the database does not do */
        api._disconnected.add(id);
        return { data: null, error: null };
      },
      report: async (r) => { log.push("report:" + r.reason); return opts.reportFails ? err(opts.reportFails) : { data: {}, error: null }; },
    },
  };
  return api;
}

async function boot(live, apiOpts) {
  const html = fs.readFileSync(APP, "utf8")
    .replace(/<script src="https:\/\/cdn[^"]*"><\/script>/g, "")
    .replace(/<script src="config\.js"><\/script>/, "")
    .replace(/<script src="api\.js"><\/script>/, "");
  const dom = new JSDOM(html, { runScripts: "outside-only", pretendToBeVisual: true, url: "https://jammy.social/" });
  const w = dom.window;
  w.JAMMY_LIVE = live;
  w.JammyAPI = live ? makeAPI(apiOpts || {}) : null;
  w.matchMedia = w.matchMedia || (() => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} }));
  w.scrollTo = () => {};
  w.HTMLElement.prototype.scrollIntoView = () => {};
  w.navigator.geolocation = { getCurrentPosition: (_s, e) => e && e({ code: 1 }) };
  w.indexedDB = undefined;
  const errors = [];
  w.addEventListener("error", (e) => errors.push(String(e.message || e.error)));
  const script = [...fs.readFileSync(APP, "utf8").matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)][0][1];
  /* the appended line gives the test a window into the app's own scope */
  try { w.eval(script + "\n;window.__peek=function(x){return eval(x)};"); }
  catch (e) { errors.push("THREW: " + e.message); }
  await new Promise((r) => setTimeout(r, 60));
  return { w, dom, errors, api: w.JammyAPI };
}

const click = (w, sel) => { const e = w.document.querySelector(sel); if (!e) throw new Error("no element " + sel); e.click(); };
const type = (w, sel, v) => { const e = w.document.querySelector(sel); e.value = v; e.dispatchEvent(new w.Event("input", { bubbles: true })); };
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  console.log("\n1. DEMO MODE still works end to end");
  {
    const { w, errors } = await boot(false);
    ok(errors.length === 0, "app starts with no errors" + (errors.length ? " — " + errors[0] : ""));
    ok(w.document.querySelector("#onb").classList.contains("on"), "onboarding opens for a new user");
    click(w, "#ob-next");                                  // welcome
    click(w, '[data-m="email"]');                          // choose email
    type(w, "#ob-contact", "stella@example.com");
    click(w, "#ob-next"); await wait(20);                  // send code
    ok(w.document.querySelector("#ob-codewrap").style.display === "block", "code box appears");
    type(w, "#ob-code", "012345");
    click(w, "#ob-next"); await wait(20);
    ok(w.document.querySelector("h1").textContent.includes("born"), "demo accepts any code and moves on");
  }

  console.log("\n2. LIVE MODE talks to the database at the right moments");
  {
    const { w, errors, api } = await boot(true);
    ok(errors.length === 0, "app starts with no errors" + (errors.length ? " — " + errors[0] : ""));
    click(w, "#ob-next");
    click(w, '[data-m="email"]');
    type(w, "#ob-contact", "stella@example.com");
    click(w, "#ob-next"); await wait(30);
    ok(api._log.includes("sendEmailCode:stella@example.com"), "asks the server to send a real code");
    type(w, "#ob-code", "123456");
    click(w, "#ob-next"); await wait(40);
    ok(api._log.some((l) => l.startsWith("verifyEmail:")), "verifies the code against the server");
    ok(api._log.includes("loadMe"), "checks whether a profile already exists");
    ok(w.document.querySelector("h1").textContent.includes("born"), "new user continues to the age gate");
  }

  console.log("\n3. LIVE MODE refuses routes that aren't switched on");
  {
    const { w, api } = await boot(true);
    click(w, "#ob-next");
    click(w, '[data-m="apple"]'); await wait(10);
    ok(!w.document.querySelector("h1").textContent.includes("born"), "Apple sign-in does not pretend to work");
    click(w, '[data-m="phone"]'); await wait(10);
    ok(api._log.length === 0, "phone sign-in does not call the server");
  }

  console.log("\n4. A WRONG CODE is handled, not swallowed");
  {
    const { w, api } = await boot(true, { verifyFails: "Token has expired or is invalid" });
    click(w, "#ob-next"); click(w, '[data-m="email"]');
    type(w, "#ob-contact", "stella@example.com");
    click(w, "#ob-next"); await wait(30);
    type(w, "#ob-code", "999999");
    click(w, "#ob-next"); await wait(40);
    ok(!w.document.querySelector("h1").textContent.includes("born"), "stays on the code screen");
    ok(w.document.querySelector("#ob-code").value === "", "clears the field to retype");
    const box = w.document.querySelector(".oberr.on");
    ok(!!box, "shows an error that stays on screen");
    ok(/wrong or has expired/i.test(box.textContent), "says the code is wrong in plain English");
    ok(/expired or is invalid/i.test(box.textContent), "and keeps the server's own words underneath");
  }

  console.log("\n5. A RETURNING user skips onboarding");
  {
    const { w, api } = await boot(true, {
      session: { access_token: "x" },
      profile: { id: "u1", handle: "stella", display_name: "Stella Saleh", city: "Boston", instruments: ["Trumpet"], genres: ["Jazz"], looking_for: "Form a band", rehearsal_days: ["Wed"] },
    });
    await wait(60);
    ok(!w.document.querySelector("#onb").classList.contains("on"), "goes straight into the app");
    ok(w.__peek("S.me.name") === "Stella Saleh", "loads the real profile from the server");
    ok(w.__peek("S.me.handle") === "@stella", "uses the handle the server stored");
  }

  console.log("\n6. AN EXPIRED session is caught instead of failing silently");
  {
    const { w } = await boot(true, { session: null });
    w.__peek("S.onboarded=true;save();");
    await w.__peek("resumeSession()"); await wait(40);
    ok(w.document.querySelector("#onb").classList.contains("on"), "asks the user to sign in again");
    ok(w.__peek("S.onboarded") === false, "stops claiming to be signed in");
  }

  console.log("\n7. A REJECTED profile keeps the user on the screen");
  {
    const { w, api } = await boot(true, { createFails: 'duplicate key value violates unique constraint "profiles_handle_key"' });
    w.__peek(`obDraft={instruments:["Bass"],genres:["Jazz"],goal:"Form a band",agreed:true,method:"email",name:"Stella",handle:"@stella",city:"Boston",dob:"2004-03-01",days:["Wed"]};`);
    await w.__peek("finishOnboarding()"); await wait(40);
    ok(api._log.some((l) => l.startsWith("createProfile:")), "tries to create the profile");
    ok(w.__peek("S.onboarded") === false, "does NOT mark the account as set up");
    const box = w.document.querySelector(".oberr.on");
    ok(!!box, "shows an error that stays on screen");
    ok(/handle is taken/i.test(box.textContent), "explains that the handle is taken");
  }

  console.log("\n8. A GOOD profile is adopted from what the server stored");
  {
    const { w, api } = await boot(true, {});
    w.__peek(`obDraft={instruments:["Bass"],genres:["Jazz"],goal:"Form a band",agreed:true,method:"email",name:"Stella Saleh",handle:"@Stella Saleh!!",city:"Boston",dob:"2004-03-01",days:["Wed"]};`);
    await w.__peek("finishOnboarding()"); await wait(40);
    ok(api._log.some((l) => l === "createProfile:stellasaleh"), "cleans the handle to what the database allows");
    ok(w.__peek("S.onboarded") === true, "marks the account as set up");
    ok(w.__peek("S.me.id") === "u1", "adopts the server's id rather than the local placeholder");
  }


  const PEOPLE = [
    { id: "p1", display_name: "Mina Okafor", handle: "minabass", city: "Jamaica Plain", instruments: ["Bass"], genres: ["Funk", "Jazz"], looking_for: "A rhythm section", bio: "Low end first.", photo_path: null, miles: 2.4, shared_genres: ["Jazz"], they_need_me: ["Trumpet"], is_remote: false, fit: 82 },
    { id: "p2", display_name: "Leo Park", handle: "leodrums", city: "Allston", instruments: ["Drums"], genres: ["Jazz"], looking_for: "Weekly rehearsals", bio: "Pocket.", photo_path: null, miles: 5.1, shared_genres: ["Jazz"], they_need_me: [], is_remote: false, fit: 61 },
  ];
  const signedIn = (extra) => Object.assign({
    session: { access_token: "x" },
    profile: { id: "u1", handle: "stella", display_name: "Stella Saleh", city: "Boston", instruments: ["Trumpet"], genres: ["Jazz"], looking_for: "Form a band", rehearsal_days: ["Wed"] },
    people: PEOPLE,
  }, extra || {});

  /* ------------------------------------------------------------
     The server stopped handing out coordinates (23_columns.sql).
     The app only ever wanted one bit from that column — does the
     server know where I am — and it now reads that bit by name.
     Checked here because the browser fakes could go on returning
     a coordinate for months and nothing would have noticed.
     ------------------------------------------------------------ */
  console.log("\n8b. WHERE THE APP THINKS YOU ARE");
  {
    const { w } = await boot(true, signedIn({
      profile: { id: "u1", handle: "stella", display_name: "Stella Saleh",
                 city: "Boston", instruments: ["Trumpet"], genres: ["Jazz"],
                 looking_for: "Form a band", rehearsal_days: ["Wed"],
                 has_location: true },
      setLocationFails: "offline",   /* so only the profile read can set it */
    }));
    await wait(260);
    ok(w.__peek("srvLoc") === true,
       "the app learns the server has your location from has_location");
  }
  {
    const { w } = await boot(true, signedIn({
      profile: { id: "u1", handle: "stella", display_name: "Stella Saleh",
                 city: "Boston", instruments: ["Trumpet"], genres: ["Jazz"],
                 looking_for: "Form a band", rehearsal_days: ["Wed"],
                 has_location: false },
      setLocationFails: "offline",
    }));
    await wait(260);
    ok(w.__peek("srvLoc") === false,
       "and knows when it does not, so Discover can say so");
  }
  {
    /* the shape the server will never send again */
    const { w } = await boot(true, signedIn({
      profile: { id: "u1", handle: "stella", display_name: "Stella Saleh",
                 city: "Boston", instruments: ["Trumpet"], genres: ["Jazz"],
                 looking_for: "Form a band", rehearsal_days: ["Wed"],
                 location: "POINT(-71 42)" },
      setLocationFails: "offline",
    }));
    await wait(260);
    ok(w.__peek("srvLoc") === false,
       "and a raw coordinate is not treated as an answer");
  }

  console.log("\n9. DISCOVER shows real people from the database");
  {
    const { w, api } = await boot(true, signedIn());
    await wait(80);
    ok(api._log.some((l) => l.startsWith("find:")), "asks the database who is nearby");
    ok(w.__peek("LIVEPOOL.length") === 2, "holds the people it was sent");
    ok(w.document.querySelectorAll(".dcard").length > 0, "draws cards for them");
    /* the deck stacks back-to-front: the top card is the last in the DOM */
    const cards = [...w.document.querySelectorAll(".dcard")];
    const top = cards[cards.length - 1];
    ok(w.__peek("queue()[0].id") === "p1", "puts the best-fitting person first");
    ok(/Mina/.test(top.textContent), "shows them on the top card");
    ok(/82% fit/.test(top.textContent), "uses the score the database worked out");
    ok(/2\.4 mi/.test(top.textContent), "uses the distance the database worked out");
    ok(/Needs a trumpet/i.test(top.textContent), "says why they match");
  }

  console.log("\n10. A SWIPE is recorded, and a non-match says so");
  {
    const { w, api } = await boot(true, signedIn({ matched: false }));
    await wait(80);
    click(w, "#d-yes"); await wait(60);
    ok(api._log.some((l) => l === "swipe:yes:p1"), "tells the database about the swipe");
    const t = w.document.querySelector("#toast");
    ok(t && /request sent/i.test(t.textContent), "says the request was sent");
    ok(w.__peek("S.connections.length") === 0, "does not invent a connection");
  }

  console.log("\n11. A MUTUAL swipe opens a real connection");
  {
    /* the real server creates the conversation as part of the match, so the
       list it returns a moment later already contains it */
    const newConvo = [{ conversation_id: "c1", kind: "dm", band_id: null, other_id: "p1", other_name: "Mina Okafor", other_handle: "minabass", other_city: "Jamaica Plain", other_photo: null, band_name: null, last_body: null, last_clip_label: null, last_sender_id: null, last_at: null, unread: 0 }];
    const { w, api } = await boot(true, signedIn({ matched: true, convos: newConvo }));
    await wait(80);
    click(w, "#d-yes"); await wait(120);
    ok(w.__peek("S.connections.length") === 1, "records the connection");
    ok(w.__peek("S.connections[0]") === "p1", "with the right person");
    ok(w.__peek("CONVOID.p1") === "c1", "and the conversation the server made for it");
    ok(w.__peek("(S.threads.p1||[]).length") === 0, "the thread starts genuinely empty — no fabricated hello");
  }

  console.log("\n12. A FAILED swipe is put back, not silently lost");
  {
    const { w, api } = await boot(true, signedIn({ swipeFails: "Failed to fetch" }));
    await wait(80);
    click(w, "#d-yes"); await wait(60);
    ok(w.__peek("S.seen.p1") === undefined, "the card comes back rather than vanishing");
    const t = w.document.querySelector("#toast");
    ok(t && /connection/i.test(t.textContent), "tells the user it did not save");
  }

  console.log("\n13. CHANGING the distance asks the database again");
  {
    const { w, api } = await boot(true, signedIn());
    await wait(80);
    const before = api._log.filter((l) => l.startsWith("find:")).length;
    w.__peek("S.filters.radius=3;save();loadDeckSoon();"); await wait(300);
    const after = api._log.filter((l) => l.startsWith("find:")).length;
    ok(after === before + 1, "refetches once for the new ring");
    ok(api._log[api._log.length - 1] === "find:r3" || api._log.includes("find:r3"), "asks for the ring that was chosen");
  }

  console.log("\n14. DEMO mode is untouched by all of this");
  {
    const { w, errors } = await boot(false);
    w.__peek("S.onboarded=true;save();renderAll();");
    await wait(40);
    ok(errors.length === 0, "still starts clean");
    ok(w.__peek("POOL().length") === w.__peek("ARTISTS.length"), "still uses the written-in musicians");
    ok(w.document.querySelectorAll(".dcard").length > 0, "still deals a deck");
  }


  const CONVOS = [
    { conversation_id: "c1", kind: "dm", band_id: null, other_id: "p1", other_name: "Mina Okafor", other_handle: "minabass", other_city: "Jamaica Plain", other_photo: null, band_name: null, last_body: "bring the trumpet", last_clip_label: null, last_duration_ms: null, last_sender_id: "p1", last_at: "2026-11-18T11:00:00Z", unread: 2 },
  ];
  const MSGS = [
    { id: "m2", sender_id: "u1", body: "on my way", created_at: "2026-11-18T11:01:00Z", clip_path: null },
    { id: "m1", sender_id: "p1", body: "bring the trumpet", created_at: "2026-11-18T11:00:00Z", clip_path: null },
  ];

  console.log("\n15. THE MESSAGE LIST comes from the database");
  {
    const { w, api } = await boot(true, signedIn({ convos: CONVOS }));
    await wait(90);
    ok(api._log.includes("convoList"), "asks the server for the conversation list");
    ok(w.__peek("S.connections.length") === 1, "learns who you're connected to from it");
    ok(w.__peek("S.unread.p1") === 2, "carries the unread count the server worked out");
    ok(w.__peek("CONVOID.p1") === "c1", "remembers which conversation that is");
    const rows = [...w.document.querySelectorAll("#chats .crow")].map((r) => r.textContent);
    ok(rows.some((t) => /Mina Okafor/.test(t)), "draws the row");
    ok(rows.some((t) => /bring the trumpet/.test(t)), "shows the last message without opening it");
    ok(rows.some((t) => /2/.test(t)), "shows the unread badge");
  }

  console.log("\n16. OPENING a thread loads it and marks it read");
  {
    const { w, api } = await boot(true, signedIn({ convos: CONVOS, messages: MSGS }));
    await wait(90);
    w.__peek('openChat("p1")'); await wait(90);
    ok(api._log.includes("thread:c1"), "fetches the messages");
    ok(w.__peek("S.threads.p1.length") === 2, "stores both of them");
    ok(w.__peek("S.threads.p1[0].t") === "bring the trumpet", "oldest first, the way the screen reads");
    ok(w.__peek('S.threads.p1[1].f') === "me", "knows which ones are yours");
    ok(api._log.includes("markRead:c1"), "marks it read");
    ok(api._log.includes("subscribe:c1"), "subscribes for new messages");
  }

  console.log("\n17. SENDING shows immediately, then confirms");
  {
    const { w, api } = await boot(true, signedIn({ convos: CONVOS, messages: MSGS }));
    await wait(90);
    w.__peek('openChat("p1")'); await wait(90);
    w.__peek('sendMsg("sounds good")');
    ok(w.__peek("S.threads.p1.length") === 3, "appears on screen straight away");
    ok(w.__peek("S.threads.p1[2].sending") === true, "marked as still sending");
    await wait(60);
    ok(api._log.includes("send:sounds good"), "sends it to the server");
    ok(w.__peek("S.threads.p1[2].sending") === undefined, "clears the sending state");
    ok(w.__peek("S.threads.p1[2].id") === "m99", "keeps the id the server gave it");
    ok(w.__peek("JSON.stringify(S.threads.p1.map(m=>m.t))").includes("sounds good"), "the message stays put");
  }

  console.log("\n18. A FAILED send is kept and retryable, not lost");
  {
    const { w, api } = await boot(true, signedIn({ convos: CONVOS, messages: MSGS, sendFails: "Failed to fetch" }));
    await wait(90);
    w.__peek('openChat("p1")'); await wait(90);
    w.__peek('sendMsg("did this send")'); await wait(60);
    ok(w.__peek("S.threads.p1[2].failed") === true, "the message is marked as failed");
    ok(w.__peek("S.threads.p1[2].t") === "did this send", "the text is still there to retry");
    ok(w.__peek("S.threads.p1[2].why") === "Failed to fetch",
       "keeps the server's own words about why it failed");
    const failed = w.document.querySelector(".msg.failed");
    ok(!!failed, "shows it differently on screen");
    ok(/tap to retry/i.test(failed.textContent), "says how to retry");
    ok(/Failed to fetch/.test(failed.textContent), "and shows the reason on the message itself");
  }

  console.log("\n19. AN INCOMING message arrives without a refresh");
  {
    const { w, api } = await boot(true, signedIn({ convos: CONVOS, messages: MSGS }));
    await wait(90);
    w.__peek('openChat("p1")'); await wait(90);
    api._push({ id: "m100", sender_id: "p1", body: "see you at 7", created_at: "2026-11-18T12:05:00Z", clip_path: null });
    await wait(30);
    ok(w.__peek("S.threads.p1.length") === 3, "lands in the thread");
    ok(w.__peek("S.threads.p1[2].t") === "see you at 7", "with the right text");
    ok(/see you at 7/.test(w.document.querySelector("#ch-msgs").textContent), "and on screen");
  }

  console.log("\n20. YOUR OWN message doesn't arrive twice");
  {
    const { w, api } = await boot(true, signedIn({ convos: CONVOS, messages: MSGS }));
    await wait(90);
    w.__peek('openChat("p1")'); await wait(90);
    w.__peek('sendMsg("only once")'); await wait(60);
    /* the server echoes every insert back down the subscription, including ours */
    api._push({ id: "m99", sender_id: "u1", body: "only once", created_at: "2026-11-18T12:00:00Z", clip_path: null });
    await wait(30);
    const texts = JSON.parse(w.__peek("JSON.stringify(S.threads.p1.map(m=>m.t))"));
    ok(texts.filter((t) => t === "only once").length === 1, "appears exactly once, not twice");
  }

  console.log("\n21. LIVE mode doesn't show the made-up bands");
  {
    const { w } = await boot(true, signedIn({ convos: CONVOS }));
    await wait(90);
    const chats = w.document.querySelector("#chats").textContent;
    ok(!/Flaming Weirdos|Buttheads/i.test(chats), "none of the demo bands appear");
    /* The copy used to say bands weren't ready. They are, so an empty
       list should point at the two ways in, not apologise for a gap. */
    ok(/Start one from your profile|ask to join one/i.test(chats),
       "and the empty list says how to get a band instead");
    ok(!/arrive with the bands feature/i.test(chats),
       "with no leftover copy claiming bands don't work yet");
  }


  console.log("\n22. THE CODE FIELD accepts whatever length the server sends");
  {
    const { w, api } = await boot(true, {});
    click(w, "#ob-next"); click(w, '[data-m="email"]');
    type(w, "#ob-contact", "stella@example.com");
    click(w, "#ob-next"); await wait(30);
    const f = w.document.querySelector("#ob-code");
    ok(!!f, "there is a single code field, not a fixed row of boxes");
    type(w, "#ob-code", "12345678");
    ok(f.value === "12345678", "an eight-digit code fits");
    ok(w.document.querySelector("#ob-next").disabled === false, "and the button is usable");
    type(w, "#ob-code", "1234");
    ok(f.value === "1234", "a four-digit code fits too");
    type(w, "#ob-code", "12 34-56");
    ok(f.value === "123456", "spaces and dashes from a pasted code are stripped");
    type(w, "#ob-code", "12a3b");
    ok(f.value === "123", "letters are ignored");
    type(w, "#ob-code", "123");
    ok(w.document.querySelector("#ob-next").disabled === true, "too short leaves the button off");
  }


  console.log("\n23. CONNECT goes through the server, and tells the truth about it");
  {
    const { w, api } = await boot(true, signedIn({ matched: false }));
    await wait(90);
    await w.__peek('connect("p1")'); await wait(60);
    ok(api._log.some((l) => l === "swipe:yes:p1"), "asks the server, instead of deciding by itself");
    ok(w.__peek("S.connections.length") === 0, "does NOT claim you are connected");
    ok(w.__peek("S.requested.p1") === true, "remembers that you asked");
    const t = w.document.querySelector("#toast");
    ok(t && /say yes/i.test(t.textContent), "says you are waiting on them");
  }

  console.log("\n24. CONNECT when they already said yes");
  {
    const newConvo = [{ conversation_id: "c1", kind: "dm", band_id: null, other_id: "p1", other_name: "Mina Okafor", other_handle: "minabass", other_city: "JP", other_photo: null, band_name: null, last_body: null, last_clip_label: null, last_sender_id: null, last_at: null, unread: 0 }];
    const { w, api } = await boot(true, signedIn({ matched: true, convos: newConvo }));
    await wait(90);
    await w.__peek('connect("p1", true)'); await wait(90);
    ok(w.__peek("S.connections.indexOf('p1')") > -1, "connects you");
    ok(w.__peek("S.requested.p1") === undefined, "and stops calling it a request");
  }

  console.log("\n25. A REFUSED connect does not leave a false 'Requested'");
  {
    const { w, api } = await boot(true, signedIn({ swipeFails: "Failed to fetch" }));
    await wait(90);
    await w.__peek('connect("p1")'); await wait(60);
    ok(w.__peek("S.requested.p1") === undefined, "the button goes back to Connect");
    ok(w.__peek("S.connections.length") === 0, "and you are not connected");
  }

  console.log("\n26. BLOCKING reaches the server");
  {
    const { w, api } = await boot(true, signedIn({ convos: CONVOS }));
    await wait(90);
    const ok1 = await w.__peek('blockUser("p1","harassment","")'); await wait(60);
    ok(api._log.some((l) => l === "block:p1"), "tells the server about the block");
    ok(ok1 === true, "and reports that it worked");
    ok(w.__peek("isBlocked('p1')") === true, "the person is blocked here too");
    ok(w.__peek("S.connections.indexOf('p1')") === -1, "and removed from your connections");
  }

  console.log("\n27. A BLOCK the server refuses is undone, not pretended");
  {
    const { w, api } = await boot(true, signedIn({ convos: CONVOS, blockFails: "Failed to fetch" }));
    await wait(90);
    const res = await w.__peek('blockUser("p1","harassment","")'); await wait(60);
    ok(res === false, "reports the failure instead of swallowing it");
    ok(w.__peek("isBlocked('p1')") === false, "the block is rolled back");
    ok(w.__peek("S.connections.indexOf('p1')") > -1, "and the connection comes back");
    const t = w.document.querySelector("#toast");
    ok(t && /couldn't block/i.test(t.textContent), "and says so plainly");
  }

  console.log("\n28. REPORTS are filed with the server, or not claimed");
  {
    const { w, api } = await boot(true, signedIn({}));
    await wait(90);
    const sent = await w.__peek('reportUser("p1","harassment","they would not stop")');
    ok(api._log.some((l) => l === "report:harassment"), "the report is sent");
    ok(sent === true, "and confirmed");
  }
  {
    const { w, api } = await boot(true, signedIn({ reportFails: "Failed to fetch" }));
    await wait(90);
    const sent = await w.__peek('reportUser("p1","harassment","")');
    ok(sent === false, "a report that could not be filed is never called filed");
    const t = w.document.querySelector("#toast");
    ok(t && /couldn't send that report/i.test(t.textContent), "and the user is told");
  }


  const ASKED = [{ id: "p2", display_name: "Leo Park", handle: "leodrums", city: "Allston",
    photo_path: null, instruments: ["Drums"], genres: ["Jazz"], looking_for: "A horn player",
    bio: "", shared_genres: ["Jazz"], they_need_me: ["Trumpet"], miles: 5.1,
    asked_at: "2026-11-19T10:00:00Z" }];

  console.log("\n29. SOMEONE ASKING TO PLAY shows up instead of vanishing");
  {
    const { w, api } = await boot(true, signedIn({ requests: ASKED }));
    await wait(90);
    w.__peek('go("chats")'); await wait(90);
    ok(api._log.includes("requests"), "the app asks who is waiting on you");
    ok(w.__peek("REQUESTS.length") === 1, "and holds them");
    const txt = w.document.querySelector("#chats").textContent;
    ok(/Requests/.test(txt), "there is a section for it");
    ok(/Leo Park/.test(txt), "naming the person");
    ok(/Drums/.test(txt), "showing what they play");
    ok(!!w.document.querySelector("[data-req-yes='p2']"), "with an Approve button");
    ok(!!w.document.querySelector("[data-req-no='p2']"), "and a Decline button");
    const badge = w.document.querySelector("#nb");
    ok(badge && !badge.hidden, "the tab badge counts them");
  }

  console.log("\n30. ACCEPTING connects you; passing does not");
  {
    const newConvo = [{ conversation_id: "c9", kind: "dm", band_id: null, other_id: "p2", other_name: "Leo Park", other_handle: "leodrums", other_city: "Allston", other_photo: null, band_name: null, last_body: null, last_clip_label: null, last_sender_id: null, last_at: null, unread: 0 }];
    const { w, api } = await boot(true, signedIn({ requests: ASKED, matched: true, convos: newConvo }));
    await wait(90);
    w.__peek('go("chats")'); await wait(90);
    /* click the actual button — calling the function directly is how a
       dead button passed a test once already */
    w.document.querySelector("[data-req-yes='p2']").click(); await wait(120);
    ok(api._log.some((l) => l === "swipe:yes:p2"), "clicking Approve tells the server");
    ok(w.__peek("S.connections.indexOf('p2')") > -1, "and connects you");
    ok(w.__peek("REQUESTS.length") === 0, "the request is cleared");
  }
  {
    const { w, api } = await boot(true, signedIn({ requests: ASKED, matched: false }));
    await wait(90);
    w.__peek('go("chats")'); await wait(90);
    w.document.querySelector("[data-req-no='p2']").click(); await wait(120);
    ok(api._log.some((l) => l === "swipe:no:p2"), "clicking Decline tells the server too");
    ok(w.__peek("S.connections.length") === 0, "and does not connect you");
    ok(w.__peek("REQUESTS.length") === 0, "and clears the request");
  }

  console.log("\n31. A REFUSED answer puts the request back");
  {
    const { w, api } = await boot(true, signedIn({ requests: ASKED, swipeFails: "Failed to fetch" }));
    await wait(90);
    w.__peek('go("chats")'); await wait(90);
    w.document.querySelector("[data-req-yes='p2']").click(); await wait(160);
    ok(w.__peek("REQUESTS.length") === 1, "the person is still waiting, not silently dropped");
    ok(w.__peek("S.connections.length") === 0, "and you are not falsely connected");
  }


  const BAND = [{ id: "band1", name: "The Flaming Weirdos", city: "Boston",
    genres: ["Jazz", "Funk"], about: "Loud.", avatar_path: null, my_role: "Horns",
    i_am_admin: true, member_count: 2, next_kind: "practice",
    next_at: "2026-11-26T19:00:00Z", next_place: "Sound Museum" }];
  const ROSTER = [
    { user_id: "u1", display_name: "Stella Saleh", handle: "stella", photo_path: null,
      instruments: ["Trumpet"], role_label: "Horns", is_admin: true, on_jammy: true },
    { user_id: "p1", display_name: "Mina Okafor", handle: "minabass", photo_path: null,
      instruments: ["Bass"], role_label: "Bass", is_admin: false, on_jammy: true },
  ];
  /* Dated from today, not written down. These were fixed dates in
     November 2026, and once those days passed the practice stopped being
     the next event and this fixture started failing on the calendar
     rather than on anything in the app. Anything asserting "the next
     one" has to be relative to now. */
  const inDays = (n, h) => {
    const d = new Date();
    d.setUTCDate(d.getUTCDate() + n);
    d.setUTCHours(h, 0, 0, 0);
    return d.toISOString();
  };
  const BANDEVENTS = [
    { id: "e1", kind: "practice", starts_at: inDays(2, 19), ends_at: null,
      place: "Sound Museum", address: "Room 214", note: "bring the PA",
      visibility: "members", mine: true },
    { id: "e2", kind: "gig", starts_at: inDays(5, 20), ends_at: null,
      place: "Lilypad", address: "1353 Cambridge St", note: "doors 8",
      visibility: "public", mine: true },
  ];

  console.log("\n32. BANDS come from the database, not the written-in four");
  {
    const { w, api } = await boot(true, signedIn({ bands: BAND }));
    await wait(120);
    ok(api._log.includes("myBands"), "the app asks the server for your bands");
    ok(w.__peek("ALLBANDS().length") === 1, "and shows only the real one");
    ok(w.__peek("ALLBANDS()[0].name") === "The Flaming Weirdos", "with its real name");
    ok(w.__peek("S.joined.length") === 1, "membership comes from the server too");
    w.__peek('openBandList()'); await wait(40);
    ok(!/Buttheads|Flaming Weirdos *$/.test(w.document.querySelector("#bl-body").textContent.replace("The Flaming Weirdos","")),
       "the band list shows no made-up bands");
  }

  console.log("\n33. A BAND PAGE loads its roster and diary");
  {
    const { w, api } = await boot(true, signedIn({ bands: BAND, roster: ROSTER, bandEvents: BANDEVENTS }));
    await wait(120);
    w.__peek('openBand("band1")'); await wait(140);
    ok(api._log.includes("roster:band1"), "asks for the roster");
    ok(api._log.includes("schedule:band1"), "and the diary");
    /* The roster the server sends includes YOU (u1 here). The band page
       draws you separately at the top, so your own row has to come out
       or you are on the screen twice and counted twice. */
    ok(w.__peek("ALLBANDS()[0].members.length") === 1, "the other member is there");
    ok(w.__peek("ALLBANDS()[0].members[0].role") === "Bass", "with what they play");
    ok(w.__peek('ALLBANDS()[0].members.some(m=>m.id==="u1")') === false,
       "and you are not listed among them, because you are drawn above");
    ok(w.__peek("ALLBANDS()[0].myRole") === "Horns",
       "but your own part in the band is kept from that row");
    ok(w.__peek("bandEvents(ALLBANDS()[0]).length") === 2, "both dates are there");
    ok(w.__peek("nextEvent(ALLBANDS()[0]).type") === "practice", "and the next one is the practice");
  }

  console.log("\n34. STARTING a band creates it on the server");
  {
    const { w, api } = await boot(true, signedIn({ bands: [] }));
    await wait(120);
    w.__peek('openAddBand()'); await wait(40);
    w.document.querySelector("#nb-name").value = "The Buttheads";
    w.document.querySelector("#nb-city").value = "Allston";
    w.document.querySelector("#nb-gen").value = "Punk, Ska";
    w.document.querySelector("#nb-go").click(); await wait(160);
    ok(api._log.some((l) => l === "createBand:The Buttheads"), "one call makes the band, your membership and the chat");
    ok(api._log.filter((l) => l === "myBands").length > 1, "then reloads from the server rather than guessing");
  }

  console.log("\n35. A PRACTICE is never offered as public");
  {
    const { w, api } = await boot(true, signedIn({ bands: BAND, roster: ROSTER, bandEvents: BANDEVENTS }));
    await wait(120);
    w.__peek('openBand("band1")'); await wait(140);
    w.__peek('openAddEvent("band1")'); await wait(40);
    w.document.querySelector("#ne-type").value = "practice";
    w.document.querySelector("#ne-place").value = "My flat";
    w.document.querySelector("#ne-go").click(); await wait(140);
    ok(api._log.some((l) => l === "addEvent:practice:members"),
       "a practice is sent as members-only whatever the screen was showing");
  }

  console.log("\n36. A GIG goes out public by default");
  {
    const { w, api } = await boot(true, signedIn({ bands: BAND, roster: ROSTER, bandEvents: BANDEVENTS }));
    await wait(120);
    w.__peek('openBand("band1")'); await wait(140);
    w.__peek('openAddEvent("band1")'); await wait(40);
    w.document.querySelector("#ne-type").value = "gig";
    w.document.querySelector("#ne-type").dispatchEvent(new w.Event("change"));
    w.document.querySelector("#ne-place").value = "Lilypad";
    w.document.querySelector("#ne-go").click(); await wait(140);
    ok(api._log.some((l) => l === "addEvent:gig:public"), "a gig is announced");
  }

  console.log("\n37. A REFUSED date is not shown as added");
  {
    const { w, api } = await boot(true, signedIn({ bands: BAND, roster: ROSTER, bandEvents: BANDEVENTS, addEventFails: "only the band can put something in its diary" }));
    await wait(120);
    w.__peek('openBand("band1")'); await wait(140);
    w.__peek('openAddEvent("band1")'); await wait(40);
    w.document.querySelector("#ne-place").value = "Nowhere";
    w.document.querySelector("#ne-go").click(); await wait(140);
    ok(w.__peek("bandEvents(ALLBANDS()[0]).length") === 2, "the diary is unchanged");
    const t = w.document.querySelector("#toast");
    ok(t && /only the band/i.test(t.textContent), "and the reason is shown");
  }

  /* ----------------------------------------------------------
     38. The fake API must keep up with the real one.

     Every bug in this section so far has been the same bug: a new
     call added to api.js, not added to the fake, and a test suite
     that then proves nothing about the screen using it. This reads
     the real api.js and insists the fake answers everything the
     app's DB facade actually reaches for.
     ---------------------------------------------------------- */
  console.log("\n38. THE FAKE API still matches the real one");
  {
    const apiSrc = fs.readFileSync(APP.replace(/index\.html$/, "api.js"), "utf8");
    const appSrc = fs.readFileSync(APP, "utf8");

    // every JammyAPI.<group>.<method> the app actually calls
    const used = new Set();
    for (const m of appSrc.matchAll(/JammyAPI\.(\w+)\.(\w+)\s*\(/g)) used.add(m[1] + "." + m[2]);

    const fake = makeAPI({});
    const missing = [...used].filter((k) => {
      const [g, fn] = k.split(".");
      return !(fake[g] && typeof fake[g][fn] === "function");
    });
    ok(missing.length === 0,
       missing.length ? "the fake API is missing: " + missing.join(", ")
                      : `the fake answers all ${used.size} calls the app makes`);

    // and nothing the app calls is missing from the real api.js either
    const notReal = [...used].filter((k) => {
      const fn = k.split(".")[1];
      // `sb` is the raw Supabase client passed straight through, not a
      // list of named helpers, so there is nothing to match against
      if (k.startsWith("sb.")) return false;
      // defined as `name:` , `name(` or `async name(`
      return !new RegExp("(^|[\\s{,])(async\\s+)?" + fn + "\\s*[:(]").test(apiSrc);
    });
    ok(notReal.length === 0,
       notReal.length ? "the app calls something api.js does not define: " + notReal.join(", ")
                      : "and every one of them exists in api.js");
  }

  /* ----------------------------------------------------------
     39. GIGS NEAR YOU — the screen that was missing entirely.

     The database rule and gigs_near_me() both existed; no screen
     called either, so a public gig was correctly public and
     completely invisible.
     ---------------------------------------------------------- */
  const GIGS = [{
    event_id: "e9", band_id: "band9", band_name: "The Fog Signals",
    band_genres: ["Indie"], band_avatar: null,
    starts_at: new Date(Date.now() + 6 * 864e5).toISOString(),
    place: "The Middle East", city: "Boston", miles: 2.8, i_am_member: false
  }];

  console.log("\n39. GIGS NEAR YOU asks the server and lists what it gets");
  {
    const { w, api } = await boot(true, signedIn({ gigs: GIGS }));
    await wait(120);
    w.__peek('go("disc")'); await wait(40);
    w.document.querySelector("#m-gigs").click(); await wait(140);

    ok(api._log.some((l) => l.startsWith("gigsNearMe")), "switching to Gigs asks the server");
    const txt = w.document.querySelector("#gigs").textContent;
    ok(/Fog Signals/.test(txt), "and the gig is on the screen");
    ok(/Middle East/.test(txt), "with where it is");
    ok(/2\.8|3 mi/.test(txt), "and how far away");
    ok(w.document.querySelector("#gigs").style.display !== "none", "the gig list is visible");
    ok(w.document.querySelector("#deck").style.display === "none", "and the people deck is not");
  }

  console.log("\n39b. AND NOTHING NEARBY says so, instead of looking broken");
  {
    const { w } = await boot(true, signedIn({ gigs: [] }));
    await wait(120);
    w.__peek('go("disc")'); await wait(40);
    w.document.querySelector("#m-gigs").click(); await wait(140);
    const txt = w.document.querySelector("#gigs").textContent;
    ok(/No gigs coming up/i.test(txt), "an empty list explains itself");
    /* Jammy now searches everywhere by default — a 7-mile default made a
       new person's app look dead. With nothing to widen, offering to
       "look anywhere" would be nonsense, so the way forward is Try again. */
    ok(/anywhere/i.test(txt), "and says it already looked everywhere");
    ok(/Try again/i.test(txt), "and offers a way forward");
  }

  /* and when the search IS narrowed, widening is what it offers */
  {
    const { w } = await boot(true, signedIn({ gigs: [] }));
    await wait(120);
    w.__poke && w.__poke("S.filters.radius", 7);
    w.__peek('S.filters.radius=7'); await wait(20);
    w.__peek('go("disc")'); await wait(40);
    w.document.querySelector("#m-gigs").click(); await wait(140);
    const txt = w.document.querySelector("#gigs").textContent;
    ok(/within 7 miles/i.test(txt), "a narrowed search says how narrow");
    ok(/Look anywhere/i.test(txt), "and offers to widen it");
  }

  /* ----------------------------------------------------------
     40. A BAND YOU ARE NOT IN can be opened from a gig
     ---------------------------------------------------------- */
  const PAGE = {
    id: "band9", name: "The Fog Signals", city: "Boston",
    genres: ["Indie"], about: "We practise Tuesdays", avatar_path: null,
    member_count: 3, next_gig: new Date(Date.now() + 6 * 864e5).toISOString(),
    i_am_member: false, i_am_admin: false, my_request: null
  };

  console.log("\n40. TAPPING A GIG opens that band, even though you're not in it");
  {
    const { w, api } = await boot(true, signedIn({ gigs: GIGS, bandPage: PAGE }));
    await wait(120);
    w.__peek('go("disc")'); await wait(40);
    w.document.querySelector("#m-gigs").click(); await wait(140);

    const row = w.document.querySelector("#gigs .evrow");
    ok(!!row, "the gig is a row you can press");
    row.click(); await wait(220);

    ok(api._log.includes("bandPage:band9"), "pressing it fetches that band");
    ok(w.document.querySelector("#bandview").classList.contains("on"), "and opens the band page");
    const body = w.document.querySelector("#bv-body").textContent;
    ok(/Fog Signals/.test(body), "showing the band");
    ok(/not in this band/i.test(body), "and saying plainly that you are not in it");
  }

  console.log("\n40b. AND IT DOES NOT CALL YOU A MEMBER OF IT");
  /* THE BUG STELLA FOUND. The Members list always opened with you,
     tagged YOU, and the count always added one for you, whether or not
     you were in the band. The first person ever to open a band page
     from a gig was told he was in a band he had never joined. */
  {
    const OTHERROSTER = [
      { user_id: "u9", display_name: "Hey Sandoval", handle: "hey", photo_path: null,
        instruments: ["Guitar"], role_label: "Guitar", is_admin: true, on_jammy: true },
    ];
    const { w } = await boot(true, signedIn({
      gigs: GIGS,
      bandPage: { ...PAGE, member_count: 1 },
      roster: OTHERROSTER }));
    await wait(120);
    w.__peek('openBand("band9")'); await wait(260);

    const body = w.document.querySelector("#bv-body");
    const txt = body.textContent;
    ok(/Hey Sandoval/.test(txt), "the people actually in the band are listed");
    ok(body.querySelectorAll(".mrow2").length === 1,
       "and there is one member row, not one for you as well");
    ok(body.querySelectorAll(".tagme").length === 0,
       "there is no YOU tag on a band you are not in");
    ok(/Members[\s\S]{0,40}?1 person/.test(txt),
       "and the count is the people in it, not them plus you");
  }

  console.log("\n40c. BUT ON YOUR OWN BAND you are still there, once");
  {
    const { w } = await boot(true, signedIn({ bands: BAND, roster: ROSTER }));
    await wait(120);
    w.__peek('openBand("band1")'); await wait(260);
    const body = w.document.querySelector("#bv-body");
    ok(body.querySelectorAll(".tagme").length === 1, "you are tagged YOU exactly once");
    const txt = body.textContent;
    ok((txt.match(/Stella Saleh/g) || []).length <= 1, "and appear once, not twice");
    ok(/Members[\s\S]{0,40}?2 people/.test(txt), "and the count includes you");
  }

  console.log("\n41. ASK TO JOIN is there, and does something");
  {
    const { w, api } = await boot(true, signedIn({ gigs: GIGS, bandPage: PAGE }));
    await wait(120);
    w.__peek('openBand("band9")'); await wait(220);

    const btns = [...w.document.querySelectorAll("#bv-body button")];
    const ask = btns.find((b) => /ask to join/i.test(b.textContent));
    ok(!!ask, "a non-member is offered Ask to join");
    ask.click(); await wait(160);
    ok(api._log.includes("askToJoin:band9"), "and pressing it reaches the server");

    const body = w.document.querySelector("#bv-body").textContent;
    ok(/asked to join/i.test(body), "and the page then says it is waiting on them");
  }

  console.log("\n41b. AND IT IS NOT AUTOMATIC — nobody joins by pressing a button");
  {
    const { w } = await boot(true, signedIn({ gigs: GIGS, bandPage: PAGE }));
    await wait(120);
    w.__peek('openBand("band9")'); await wait(220);
    const ask = [...w.document.querySelectorAll("#bv-body button")]
      .find((b) => /ask to join/i.test(b.textContent));
    ask.click(); await wait(160);
    ok(w.__peek('S.joined.includes("band9")') === false,
       "asking does not put you in the band");
  }

  /* ----------------------------------------------------------
     42. APPROVE AND DECLINE must be pressable.

     This is the bug she hit twice: the handler lived somewhere the
     click never reached. Press the real button, not the function.
     ---------------------------------------------------------- */
  const BANDREQ = [{
    request_id: "q1", band_id: "band1", band_name: "The Flaming Weirdos",
    user_id: "u7", display_name: "Hasan", handle: "hasan", photo_path: null,
    instruments: ["Bass"], role_label: "Bass", note: "saw you at the Middle East",
    asked_at: new Date().toISOString()
  }];

  console.log("\n42. SOMEBODY ASKING TO JOIN shows up with Approve and Decline");
  {
    const { w, api } = await boot(true, signedIn({ bands: BAND, bandRequests: BANDREQ }));
    await wait(120);
    w.__peek('go("chats")'); await wait(160);

    const txt = w.document.querySelector("#chats").textContent;
    ok(/Wants to join your band/i.test(txt), "it appears in Chats, where the other requests are");
    ok(/Hasan/.test(txt), "with who is asking");
    ok(/Middle East/.test(txt), "and what they said");

    const yes = w.document.querySelector("[data-bq-yes]");
    ok(!!yes, "Approve is a real button");
    yes.click(); await wait(160);
    ok(api._log.some((l) => l === "answerBandRequest:q1:true"),
       "and pressing it reaches the server");
    ok(!/Wants to join your band/i.test(w.document.querySelector("#chats").textContent),
       "and the request clears off the screen");
  }

  console.log("\n42b. DECLINE reaches the server too, and connects nobody");
  {
    const { w, api } = await boot(true, signedIn({ bands: BAND, bandRequests: BANDREQ }));
    await wait(120);
    w.__peek('go("chats")'); await wait(160);
    w.document.querySelector("[data-bq-no]").click(); await wait(160);
    ok(api._log.some((l) => l === "answerBandRequest:q1:false"), "Decline is wired too");
  }

  console.log("\n42c. A REFUSED approval puts the request back rather than losing it");
  {
    const { w } = await boot(true, signedIn({
      bands: BAND, bandRequests: BANDREQ,
      answerBandFails: "only someone who runs this band can answer that" }));
    await wait(120);
    w.__peek('go("chats")'); await wait(160);
    w.document.querySelector("[data-bq-yes]").click(); await wait(220);
    const t = w.document.querySelector("#toast");
    ok(t && /only someone who runs/i.test(t.textContent), "the reason is shown");
    ok(/Wants to join your band/i.test(w.document.querySelector("#chats").textContent),
       "and the request is still there");
  }

  /* ----------------------------------------------------------
     43. THE FEED. Until now the first screen anyone opened was
     sixteen invented posts by eight invented musicians — shown to
     real signed-in people, not only in the demo.
     ---------------------------------------------------------- */
  const FEED = [
    { id: "f1", author_id: "u5", body: "Looking for a drummer. Tuesdays, Brighton.",
      tag: "looking", track_id: null, media_path: null,
      fields: { instrument: "Drums", when: "Tue evenings", where: "Brighton" },
      created_at: new Date(Date.now() - 36e5).toISOString(),
      like_count: 3, comment_count: 1, author_name: "Rue Delacroix",
      author_handle: "rue", author_city: "Boston", author_photo: null,
      liked_by_me: false, mine: false },
    { id: "f2", author_id: "u1", body: "New pedalboard",
      tag: "note", track_id: null, media_path: "u1/posts/board.jpg", fields: {},
      created_at: new Date(Date.now() - 72e5).toISOString(),
      like_count: 0, comment_count: 0, author_name: "Stella Saleh",
      author_handle: "stella", author_city: "Boston", author_photo: null,
      liked_by_me: false, mine: true },
  ];

  console.log("\n43. A SIGNED-IN FEED is only what people actually posted");
  {
    const { w, api } = await boot(true, signedIn({ feed: FEED }));
    await wait(200);
    ok(api._log.some((l) => l.startsWith("feedPage")), "the feed is fetched from the server");

    const txt = w.document.querySelector("#feed").textContent;
    ok(/Rue Delacroix/.test(txt), "a real post is on it");
    ok(/Brighton/.test(txt), "with the fields that make it useful, not just the prose");

    /* the invented ones, by name */
    ok(!/Kitchen Demo/.test(txt), "and nothing from the demo");
    ok(w.__peek("LIVEPOSTS.length") === 2, "the feed is exactly what the server sent");
    ok(w.__peek("allPosts().length") === 2, "and nothing is mixed in beside it");
    ok(w.__peek("SEED_POSTS.length > 0") === true,
       "(the demo posts still exist, for the signed-out demo)");
    ok(w.__peek("allStories().length") === 0, "and no invented stories either");
  }

  console.log("\n43b. SIGNED OUT, the demo is still the demo");
  {
    const { w } = await boot(false);
    await wait(160);
    ok(w.__peek("allPosts().length") > 0,
       `the signed-out demo still has its feed (${w.__peek("allPosts().length")} posts)`);
    ok(w.__peek("allStories().length > 0") === true, "and its stories");
  }

  console.log("\n43c. AN EMPTY FEED says so rather than looking broken");
  {
    const { w } = await boot(true, signedIn({ feed: [] }));
    await wait(200);
    const txt = w.document.querySelector("#feed").textContent;
    ok(/no |nothing|be the first/i.test(txt), "an empty feed explains itself");
    ok(w.__peek("LIVEPOSTS.length") === 0, "and has nothing invented in it");
  }

  console.log("\n44. LIKING moves the heart AND the number");
  {
    const { w, api } = await boot(true, signedIn({ feed: FEED }));
    await wait(200);
    const before = w.__peek('LIVEPOSTS.find(p=>p.id==="f1").likes');
    const btn = w.document.querySelector('[data-like="f1"]');
    ok(!!btn, "a post has a like button");
    btn.click(); await wait(160);
    const after = w.__peek('LIVEPOSTS.find(p=>p.id==="f1").likes');
    ok(after === before + 1, `the count moves with the heart (${before} -> ${after})`);
    ok(api._log.some((l) => l.indexOf("toggle_like") > -1 || l.indexOf("like") > -1),
       "and it reaches the server");
  }

  console.log("\n45. DELETING YOUR POST has to reach the server");
  {
    const { w, api } = await boot(true, signedIn({ feed: FEED }));
    await wait(200);
    w.__peek('(function(){ var b=document.querySelector(\'[data-post="f2"]\'); return !!b })');
    /* go through the app, not the DOM, since the menu lives in a sheet */
    w.__peek('openPostMenu && openPostMenu("f2")');
    await wait(120);
    const del = [...w.document.querySelectorAll("[data-a]")].find((b) => b.dataset.a === "delete");
    if (del) {
      del.click(); await wait(200);
      ok(api._log.some((l) => l === "deletePost:f2"), "deleting a post tells the database");
      ok(w.__peek("LIVEPOSTS.length") === 1, "and it leaves the feed");
    } else {
      ok(false, "could not reach the delete action");
    }
  }

  console.log("\n46. DELETE MY ACCOUNT is real, and asks in the page");
  {
    const { w, api } = await boot(true, signedIn({}));
    await wait(160);
    w.__peek("openDeleteAccount()"); await wait(140);

    const body = w.document.querySelector("#sheetbody").textContent;
    ok(/cannot be undone/i.test(body), "it says plainly that it cannot be undone");
    ok(/sent/i.test(body), "and what happens to messages you already sent");
    ok(!!w.document.querySelector("#da-word"), "and makes you type the word");

    /* pressing it without the word must do nothing at all */
    w.document.querySelector("#da-go").click(); await wait(140);
    ok(!api._log.some((l) => l.startsWith("deleteAccount")),
       "pressing delete without typing the word does not delete anything");

    w.document.querySelector("#da-word").value = "delete";
    w.document.querySelector("#da-go").click(); await wait(220);
    ok(api._log.some((l) => l === "deleteAccount:delete"), "typing it deletes for real");
  }

  console.log("\n46b. DOWNLOAD MY DATA, which the privacy policy promises");
  {
    const { w, api } = await boot(true, signedIn({}));
    await wait(160);
    w.__peek("exportMyData()"); await wait(220);
    ok(api._log.includes("exportMyData"), "it asks the server for everything it holds");
  }

  /* ----------------------------------------------------------
     47. THE CHART. It used to be invented tracks with invented
     play counts, under a banner reading "2,140 LISTENING" to a
     real signed-in person when the true number was nobody.
     ---------------------------------------------------------- */
  const CHART = [{
    track_id: "t1", title: "Kitchen Floor", key: "Am", bpm: 96,
    audio_path: "u5/t1.mp3", owner_id: "u5", artist_name: "Rue Delacroix",
    artist_handle: "rue", artist_photo: null, plays: 11, listeners: 4,
    last_week_rank: 3, rank: 1, is_new: false, move: 2, mine: false,
  }];

  console.log("\n47. THE CHART counts real plays and says who is really listening");
  {
    const { w, api } = await boot(true, signedIn({ chart: CHART, listeners: 2 }));
    await wait(220);
    w.__peek('go("radio")'); await wait(200);

    ok(api._log.includes("rpc:weekly_chart"), "the chart is fetched from the server");
    ok(api._log.includes("rpc:listening_now"), "and so is the number listening");

    const txt = w.document.querySelector("#radio").textContent;
    ok(/Kitchen Floor/.test(txt), "a real track is on it");
    ok(/Rue Delacroix/.test(txt), "with who made it");
    ok(/2 LISTENING/.test(txt), "and the true number listening");
    ok(!/2,140/.test(txt), "not the made-up one");
  }

  console.log("\n47b. ONE listener reads as one, not '1 listenings'");
  {
    const { w } = await boot(true, signedIn({ chart: CHART, listeners: 1 }));
    await wait(220);
    w.__peek('go("radio")'); await wait(200);
    ok(/1 LISTENING/.test(w.document.querySelector("#radio").textContent),
       "one person listening says so");
  }

  console.log("\n47c. AN EMPTY CHART says so instead of inventing one");
  {
    const { w } = await boot(true, signedIn({ chart: [], listeners: 0 }));
    await wait(220);
    w.__peek('go("radio")'); await wait(200);
    const txt = w.document.querySelector("#radio").textContent;
    ok(/Nothing on the chart yet/i.test(txt), "an empty chart explains itself");
    ok(!/2,140|LISTENING/.test(txt), "with no invented numbers anywhere on it");
    ok(w.__peek("chartData().length") === 0, "and nothing invented behind it");
  }

  console.log("\n47d. SIGNED OUT, the demo chart is still the demo");
  {
    const { w } = await boot(false);
    await wait(180);
    ok(w.__peek("chartData().length") > 0, "the signed-out demo still has a chart");
  }

  /* ----------------------------------------------------------
     48. JAM CLIPS. A clip used to be kept on the phone that made
     it and answered by an invented reply — in a real conversation,
     a message from somebody who never sent it.
     ---------------------------------------------------------- */
  console.log("\n48. A JAM CLIP goes to the other person, and nobody answers for them");
  {
    const { w, api } = await boot(true, signedIn({
      convos: [{ id: "c1", kind: "dm", other_id: "u5", other_name: "Rue Delacroix",
                 other_handle: "rue", other_photo: null, last_body: "hi",
                 last_at: new Date().toISOString(), unread: 0, messages: [] }] }));
    await wait(200);
    w.__peek('chatId="c1"');

    const before = api._log.length;
    w.__peek(`sendClip(new Blob(["x"],{type:"audio/webm"}), 4, "Jam clip")`);
    await wait(300);

    const after = api._log.slice(before);
    ok(after.some((l) => l.startsWith("sendClip:c1")), "the clip is sent to the conversation");

    /* the invented replies, by their actual words */
    const thread = JSON.stringify(w.__peek("S.threads") || {});
    ok(!/that tone is filthy|Your time is good/.test(thread),
       "and nothing replies on the other person's behalf");
    ok(w.__peek("(S.threads.c1||[]).length") === 0,
       "and the clip is not quietly kept on this phone instead");
  }

  console.log("\n48b. AND A CLIP THAT FAILS TO SEND says so");
  {
    const { w } = await boot(true, signedIn({
      clipFails: "Upload failed",
      convos: [{ id: "c1", kind: "dm", other_id: "u5", other_name: "Rue",
                 other_handle: "rue", other_photo: null, last_body: "hi",
                 last_at: new Date().toISOString(), unread: 0, messages: [] }] }));
    await wait(200);
    w.__peek('chatId="c1"');
    w.__peek(`sendClip(new Blob(["x"],{type:"audio/webm"}), 4, "Jam clip")`);
    await wait(300);
    const t = w.document.querySelector("#toast");
    ok(t && /upload failed/i.test(t.textContent), "the reason is shown rather than silence");
  }

  /* ----------------------------------------------------------
     49. THE RADIO. Uploading threw the audio file away, pressing
     play synthesised a tune from the key and tempo instead of
     opening the recording, and plays were counted on your own
     phone only — so the chart could never fill.
     ---------------------------------------------------------- */
  console.log("\n49. UPLOADING A TRACK keeps the file");
  {
    const { w, api } = await boot(true, signedIn({}));
    await wait(200);
    w.__peek("openUpload()"); await wait(140);

    ok(!!w.document.querySelector("#up-f"), "the sheet asks for an audio file");

    /* press Publish with no file chosen */
    w.document.querySelector("#up-t").value = "Kitchen Demo 2";
    w.document.querySelector("#up-go").click(); await wait(200);
    ok(!api._log.some((l) => l.startsWith("uploadTrack")),
       "publishing without a file does not pretend to publish");
    const t1 = w.document.querySelector("#toast");
    ok(t1 && /audio file/i.test(t1.textContent), "it asks for one instead");
  }

  console.log("\n50. PLAYING a real recording opens the file, not a synthesiser");
  {
    const TRACKS = [{ id: "t1", title: "Kitchen Demo 2", key: "A minor", bpm: 104,
                      audio_path: "u1/tracks/abc.mp3", plays: 0 }];
    const { w, api } = await boot(true, signedIn({ myTracks: TRACKS }));
    await wait(260);

    ok(w.__peek("S.me.tracks.length") === 1, "your recordings load from the server");
    ok(w.__peek("S.me.tracks[0].path") === "u1/tracks/abc.mp3",
       "and each one knows where its file is");

    /* play it, and watch what the app reaches for */
    w.__peek('play(S.me.tracks[0], {id:"u1", name:"Stella Saleh"})');
    await wait(200);
    ok(w.__peek("realAudio !== null"), "pressing play opens the actual recording");
    ok(w.__peek("nowPlaying !== null"), "and the player starts");
  }

  console.log("\n50b. A PLAY IS REPORTED, so the chart can fill");
  {
    const TRACKS = [{ id: "t1", title: "Kitchen Demo 2", key: "A minor", bpm: 104,
                      audio_path: "u1/tracks/abc.mp3", plays: 0 }];
    const { w, api } = await boot(true, signedIn({ myTracks: TRACKS }));
    await wait(260);
    w.__peek('play(S.me.tracks[0], {id:"u1", name:"Stella Saleh"})');
    await wait(120);

    /* under thirty seconds is not a play — otherwise the chart is climbed
       by tapping play */
    w.__peek("realPlayedFor = 12; reportPlay()");
    ok(!api._log.some((l) => l.startsWith("logPlay")), "twelve seconds is not a play");

    w.__peek("realPlayedFor = 31; reportPlay()");
    await wait(140);
    ok(api._log.some((l) => l.startsWith("logPlay:t1")), "thirty-one seconds is");

    const n = api._log.filter((l) => l.startsWith("logPlay")).length;
    w.__peek("reportPlay(); reportPlay()");
    await wait(140);
    ok(api._log.filter((l) => l.startsWith("logPlay")).length === n,
       "and one listen is reported once, not once a second");
  }

  /* ----------------------------------------------------------
     51. VIDEO CALLING, removed on request. It opened your own
     camera, drew the others as artwork and reported a made-up
     round-trip time, while contacting nobody.
     ---------------------------------------------------------- */
  console.log("\n51. THE VIDEO CALL is gone, and cannot come back by accident");
  {
    const { w } = await boot(true, signedIn({}));
    await wait(200);
    ok(w.__peek('typeof openCallWith') === "undefined", "there is no call function left");
    ok(!w.document.querySelector("#ch-call"), "no call button in a conversation");
    ok(!w.document.querySelector("#call"), "and no call screen in the page");

    /* the exact string the screen used to print, not the word in the
       comment that records why it was removed */
    const html = fs.readFileSync(APP, "utf8");
    ok(!/Round trip <b>/.test(html), "and the invented round-trip readout is gone with it");
    ok(!/cl-grid|cl-video|startCam/.test(html), "with none of the call screen left behind");
  }

  /* ----------------------------------------------------------
     52. A PLAY COUNTS AT FIFTEEN SECONDS, not thirty.
     ---------------------------------------------------------- */
  console.log("\n52. FIFTEEN SECONDS counts as a play");
  {
    const TRACKS = [{ id: "t1", title: "Kitchen Demo 2", key: "A minor", bpm: 104,
                      audio_path: "u1/tracks/abc.mp3", plays: 0 }];
    const { w, api } = await boot(true, signedIn({ myTracks: TRACKS }));
    await wait(260);
    w.__peek('play(S.me.tracks[0], {id:"u1", name:"Stella Saleh"})');
    await wait(120);

    ok(w.__peek("PLAY_COUNTS_AT") === 15, "the app's threshold is fifteen seconds");

    w.__peek("realPlayedFor = 14; reportPlay()");
    ok(!api._log.some((l) => l.startsWith("logPlay")), "fourteen seconds is not a play");

    w.__peek("realPlayedFor = 15; reportPlay()");
    await wait(140);
    ok(api._log.some((l) => l.startsWith("logPlay:t1")), "fifteen is");
  }

  console.log("\n52b. AND THE APP AND THE SERVER AGREE ON THE NUMBER");
  {
    /* Two copies of one rule is how they drift apart. The database's
       roll_up_play trigger is the real one; these must match it. */
    const appSrc = fs.readFileSync(APP, "utf8");
    const apiSrc = fs.readFileSync(APP.replace(/index\.html$/, "api.js"), "utf8");
    const sqlDir = APP.replace(/www\/index\.html$/, "backend/");
    const sql = fs.readdirSync(sqlDir).filter(f => /^\d\d_.*\.sql$/.test(f))
                  .map(f => fs.readFileSync(sqlDir + f, "utf8")).join("\n");

    const fromSql = [...sql.matchAll(/new\.seconds < (\d+)/g)].map(m => +m[1]).pop();
    const fromApi = +(apiSrc.match(/seconds < (\d+)/) || [])[1];
    const fromApp = +(appSrc.match(/PLAY_COUNTS_AT\s*=\s*(\d+)/) || [])[1];

    ok(fromSql === 15, `the database counts a play at ${fromSql}s`);
    ok(fromApi === fromSql, `and api.js agrees (${fromApi}s)`);
    ok(fromApp === fromSql, `and the app agrees (${fromApp}s)`);
  }

  /* ----------------------------------------------------------
     53. THE TOP THREE, and somebody new.
     ---------------------------------------------------------- */
  const BIGCHART = [1,2,3,4,5].map(n => ({
    track_id: "t" + n, title: "Track " + n, key: "Am", bpm: 100,
    audio_path: "u5/t" + n + ".mp3", owner_id: "u" + n,
    artist_name: "Artist " + n, artist_handle: "a" + n, artist_photo: null,
    plays: 20 - n, listeners: 10 - n, last_week_rank: n + 1, rank: n,
    is_new: false, move: 1, mine: false,
  }));

  console.log("\n53. THE TOP THREE are set apart from the rest of the chart");
  {
    const { w } = await boot(true, signedIn({ chart: BIGCHART, listeners: 3 }));
    await wait(240);
    w.__peek('go("radio")'); await wait(220);

    const radio = w.document.querySelector("#radio");
    ok(radio.querySelectorAll(".podrow").length === 3, "three of them, on their own");
    ok(!!radio.querySelector(".podrow.p1"), "first is marked as first");
    ok(/1st/.test(radio.querySelector(".podrow.p1").textContent), "and says so in words");
    ok(/Track 1/.test(radio.querySelector(".podrow.p1").textContent), "with the right track");
    ok(radio.querySelectorAll(".lbrow").length === 2, "and the rest are an ordinary list");
    ok(/4 to 5/.test(radio.textContent), "numbered on from four");
  }

  console.log("\n53b. A SHORT CHART does not pretend to have three");
  {
    const { w } = await boot(true, signedIn({ chart: BIGCHART.slice(0, 2), listeners: 1 }));
    await wait(240);
    w.__peek('go("radio")'); await wait(220);
    const radio = w.document.querySelector("#radio");
    ok(radio.querySelectorAll(".podrow").length === 2, "two tracks make a top two");
    ok(/Top 2 this week/.test(radio.textContent), "and it says top 2, not top 3");
    ok(radio.querySelectorAll(".lbrow").length === 0, "with no empty list under it");
  }

  const RISING = [{
    track_id: "tr9", title: "First Take", key: "C", bpm: 92,
    audio_path: "u9/tracks/first.mp3", duration_ms: 95000, plays: 0,
    artist_id: "u9", artist_name: "Bo Kerrigan", artist_handle: "bo",
    artist_photo: null, artist_city: "Boston", artist_bio: "Just moved here, looking for people.",
    artist_instruments: ["Drums"], artist_genres: ["Indie"],
    shared_genres: ["Indie"], miles: 2.4, uploaded_days_ago: 0,
  }];

  console.log("\n54. DISCOVER A NEW ARTIST shows one up-and-coming track and who made it");
  {
    const { w, api } = await boot(true, signedIn({ chart: BIGCHART, rising: RISING }));
    await wait(260);
    w.__peek('go("radio")'); await wait(240);

    ok(api._log.includes("rpc:rising_track"), "the radio asks for somebody new");
    const card = w.document.querySelector(".newartist");
    ok(!!card, "and shows them");
    const txt = card.textContent;
    ok(/Bo Kerrigan/.test(txt), "with their name");
    ok(/First Take/.test(txt), "the track");
    ok(/Boston/.test(txt), "where they are");
    ok(/Just moved here/.test(txt), "and something about them");
    ok(/Indie/.test(txt), "and what you both play");
    ok(/added today/.test(txt), "and how new it is");
    ok(/Not played yet/.test(w.document.querySelector("#radio").textContent),
       "and says plainly that nobody has played it");
  }

  console.log("\n54b. AND BOTH ITS BUTTONS DO SOMETHING");
  {
    const { w } = await boot(true, signedIn({ chart: BIGCHART, rising: RISING }));
    await wait(260);
    w.__peek('go("radio")'); await wait(240);

    w.document.querySelector("[data-naplay]").click();
    await wait(200);
    ok(w.__peek("nowPlaying") === "t:tr9" && w.__peek("realTrackId") === "tr9",
       "play starts their track");
    ok(w.__peek('document.querySelector("[data-naplay]").dataset.play') === w.__peek("nowPlaying"),
       "and the button knows it, so its icon can flip to pause");

    w.document.querySelector("[data-naprofile]").click();
    await wait(200);
    ok(/Bo Kerrigan/.test(w.document.querySelector("#sheetbody").textContent),
       "and the other opens their profile");
  }

  console.log("\n54c. WITH NOBODY NEW, it shows nothing rather than an empty box");
  {
    const { w } = await boot(true, signedIn({ chart: BIGCHART, rising: [] }));
    await wait(300);
    w.__peek('go("radio")'); await wait(240);
    ok(!w.document.querySelector(".newartist"), "no card at all");
    ok(!/Discover a new artist/.test(w.document.querySelector("#radio").textContent),
       "and no heading for it either");
  }

  /* ----------------------------------------------------------
     55. TAKING A RECORDING DOWN. Stella asked whether a track can
     be removed later. It could not: the API function existed and
     nothing called it, so an upload was permanent.
     ---------------------------------------------------------- */
  const MYTRACKS = [{ id: "t1", title: "Kitchen Demo 2", key: "A minor", bpm: 104,
                      audio_path: "u1/tracks/abc.mp3", plays: 3 }];

  console.log("\n55. YOU CAN TAKE YOUR OWN RECORDING DOWN");
  {
    const { w, api } = await boot(true, signedIn({ myTracks: MYTRACKS }));
    await wait(280);
    w.__peek('go("you")'); await wait(220);

    const btn = w.document.querySelector("[data-rmtrack]");
    ok(!!btn, "there is a way to remove it");

    btn.click(); await wait(160);
    const row = w.document.querySelector(".trow");
    ok(/off your profile and the radio/i.test(row.textContent), "it asks first, in the row");
    ok(/can't be undone/i.test(row.textContent), "and says it cannot be undone");
    ok(!api._log.some((l) => l.startsWith("removeTrack")), "and has not removed anything yet");

    w.document.querySelector("[data-rmtrack-yes]").click(); await wait(260);
    ok(api._log.some((l) => l === "removeTrack:t1"), "confirming removes it for real");
  }

  /* ------------------------------------------------------------
     LEAVING A CONNECTION

     The first person to use Jammy found there was no way out of
     one. Blocking existed, but blocking is for somebody who
     frightens you; most people who want out played together once
     and it didn't work. Forcing them to block a person to do that
     is a bad choice to put in front of anyone.
     ------------------------------------------------------------ */
  /* click a menu row by what it says, not where it sits — the order
     changes as the menu grows and an index silently points elsewhere */
  const menuRow = (w, re) => {
    const rows = [...w.document.querySelectorAll("[data-row]")];
    const hit = rows.find((r) => re.test(r.textContent));
    if (!hit) throw new Error("no menu row matching " + re + " — menu says: " +
      rows.map((r) => r.textContent.trim().split("\n")[0]).join(" | "));
    hit.click();
  };

  const DISC_CONVOS = [
    { conversation_id: "dc1", kind: "dm", band_id: null, other_id: "p1",
      other_name: "Mina Okafor", other_handle: "minabass", other_city: "Jamaica Plain",
      other_photo: null, band_name: null, last_body: "bring the trumpet",
      last_clip_label: null, last_duration_ms: null, last_sender_id: "p1",
      last_at: "2026-11-18T11:00:00Z", unread: 0 },
  ];

  console.log("\n55a2. DISCONNECTING, without having to block anybody");
  {
    const { w, api } = await boot(true, signedIn({ convos: DISC_CONVOS }));
    await wait(200);
    w.__peek('go("chats")'); await wait(200);

    const other = w.__peek("LIVECONVOS[0] && LIVECONVOS[0].other_id");
    ok(other === "p1", "there is somebody to disconnect from");

    w.__peek('openProfile("p1")'); await wait(200);

    /* The relationship is the button. Before this, Disconnect was one of
       four identical grey buttons at the bottom of the sheet and the
       first person to use Jammy said it wasn't clear how to remove
       somebody — nothing on screen said they WERE connected. */
    const state = w.document.querySelector("#pf-state");
    ok(!!state, "a connected person's profile says so, as a button");
    if (!state) throw new Error("no #pf-state — the relationship is not a button");
    ok(/Connected/i.test(state.textContent), "and the button names the relationship");

    state.click(); await wait(200);
    const menu = w.document.querySelector("#sheetbody").textContent;
    ok(/Remove connection/i.test(menu), "tapping it is where removing them lives");
    ok(/Message/i.test(menu), "alongside the things you do with a connection");
    ok(/Block/i.test(menu), "and blocking, in the same menu rather than another one");

    menuRow(w, /Remove connection/i); await wait(200);
    const warn = w.document.querySelector("#sheetbody").textContent;
    ok(/Keep the connection/i.test(warn), "and asks before doing it");
    /* "aren't told" could be read as "they will never know", which is
       not true — the connection visibly disappears. The copy says we
       don't notify them, and is clear they may notice. */
    ok(/don't notify/i.test(warn), "saying we don't notify them");
    ok(/notice/i.test(warn), "while being straight that they may notice anyway");
    ok(/disappears for both/i.test(warn),
       "and is honest that the conversation goes too");
    ok(/can't be undone/i.test(warn), "and that it cannot be undone");

    w.document.querySelector("#dc-yes").click(); await wait(400);
    ok(api._log.some(l => l.startsWith("disconnect:")),
       "confirming actually tells the server");
    ok(!(w.__peek("S.connections") || []).includes(other),
       "and they stop being a connection here too");
  }

  console.log("\n55a3. CHANGING YOUR MIND about disconnecting");
  {
    const { w, api } = await boot(true, signedIn({ convos: DISC_CONVOS }));
    await wait(200);
    w.__peek('go("chats")'); await wait(200);
    const other = "p1";
    w.__peek('openProfile("p1")'); await wait(200);
    w.document.querySelector("#pf-state").click(); await wait(200);
    menuRow(w, /Remove connection/i); await wait(200);
    w.document.querySelector("#dc-no").click(); await wait(200);
    ok(!api._log.some(l => l.startsWith("disconnect:")),
       "backing out tells the server nothing");
    ok((w.__peek("S.connections") || []).includes(other),
       "and they are still a connection");
  }

  console.log("\n55a4. BLOCKING, from the same place Facebook keeps it");
  {
    const { w, api } = await boot(true, signedIn({ convos: DISC_CONVOS }));
    await wait(200);
    w.__peek('go("chats")'); await wait(200);
    w.__peek('openProfile("p1")'); await wait(200);

    /* Blocking and parting ways are different acts, so they are not
       side by side looking identical. Blocking is behind the "..."
       button, the way it is everywhere else. */
    const more = w.document.querySelector("#pf-more");
    ok(!!more, "every profile has a more menu");
    more.click(); await wait(200);
    const m = w.document.querySelector("#sheetbody").textContent;
    ok(/Block/i.test(m), "which is where blocking lives");
    ok(/Report/i.test(m), "and reporting");
    ok(/Remove connection/i.test(m), "and removing them, in the same place");

    menuRow(w, /^\s*Block/i); await wait(200);
    const warn = w.document.querySelector("#sheetbody").textContent;
    ok(/Block/i.test(warn), "blocking asks first");
    ok(/don't notify/i.test(warn), "and says we don't notify them");

    w.document.querySelector("#bl-yes").click(); await wait(400);
    ok(api._log.some((l) => l.startsWith("block:")), "and then actually blocks them");
  }

  console.log("\n55a5. CHANGING YOUR MIND about blocking");
  {
    const { w, api } = await boot(true, signedIn({ convos: DISC_CONVOS }));
    await wait(200);
    w.__peek('openProfile("p1")'); await wait(200);
    w.document.querySelector("#pf-more").click(); await wait(200);
    menuRow(w, /^\s*Block/i); await wait(200);
    w.document.querySelector("#bl-no").click(); await wait(200);
    ok(!api._log.some((l) => l.startsWith("block:")), "backing out blocks nobody");
  }

  /* ------------------------------------------------------------
     THE LIST OF WHO YOU ARE CONNECTED TO

     There wasn't one. Tapping "Connections" on your own profile
     dropped you on Messages — which is a list of CONVERSATIONS,
     not of people. Somebody you connected with and never messaged
     appeared nowhere at all, so there was no way to remove them
     short of finding them again in Discover.
     ------------------------------------------------------------ */
  console.log("\n55a6. YOUR CONNECTIONS, as an actual list");
  {
    const { w, api } = await boot(true, signedIn({ convos: DISC_CONVOS }));
    await wait(200);
    w.__peek('go("chats")'); await wait(200);   /* loads connections */
    w.__peek('go("you")'); await wait(300);

    w.document.querySelector('[data-s="conn"]').click(); await wait(300);
    const list = w.document.querySelector("#sheetbody").textContent;
    ok(/Your connections/i.test(list), "the Connections stat opens a list of people");
    ok(/Mina Okafor/.test(list), "with the people you're connected to on it");

    const rows = w.document.querySelectorAll(".cxrow");
    ok(rows.length === 1, "one row per person", "rows: " + rows.length);

    w.document.querySelector(".cxmore").click(); await wait(250);
    const menu = w.document.querySelector("#sheetbody").textContent;
    ok(/Remove connection/i.test(menu), "and each one can be removed from there");
    ok(/Block/i.test(menu), "or blocked");

    menuRow(w, /Remove connection/i); await wait(200);
    w.document.querySelector("#dc-yes").click(); await wait(400);
    ok(api._log.some((l) => l.startsWith("disconnect:")),
       "and removing them from the list really removes them");
  }

  console.log("\n55a7. AND THE SAME OPTIONS ON A MESSAGE ROW");
  {
    const { w, api } = await boot(true, signedIn({ convos: DISC_CONVOS }));
    await wait(200);
    w.__peek('go("chats")'); await wait(300);

    const more = w.document.querySelector(".crmore");
    ok(!!more, "every conversation row has a more button");
    more.click(); await wait(250);
    const menu = w.document.querySelector("#sheetbody").textContent;
    ok(/Remove connection/i.test(menu), "holding the same Remove connection");
    ok(/Block/i.test(menu), "and the same Block");
    ok(/View profile/i.test(menu), "and a way through to their profile");

    menuRow(w, /^\s*Block/i); await wait(250);
    w.document.querySelector("#bl-yes").click(); await wait(400);
    ok(api._log.some((l) => l.startsWith("block:")),
       "and blocking from Messages really blocks");
  }

  /* ------------------------------------------------------------
     THE OTHER END OF A REMOVAL

     She removed a connection and the other person still saw it,
     still had the messages. The server was right — it drops the
     conversation for both — but this app kept its own copy in
     S.threads and went on showing it. Nothing here ever threw
     anything away, and nothing re-asked the server.
     ------------------------------------------------------------ */
  console.log("\n55a8. WHEN SOMEBODY ELSE REMOVES YOU");
  {
    /* hold the fake's options so the test can change what the server
       says mid-flight, the way a real server would after the other
       person removed you */
    const opts = signedIn({ convos: DISC_CONVOS.slice(), messages: [
      { id: "m1", sender_id: "p1", body: "see you Thursday",
        created_at: "2026-11-18T11:00:00Z", clip_path: null },
    ] });
    const { w } = await boot(true, opts);
    await wait(200);
    w.__peek('go("chats")'); await wait(250);
    w.__peek('openChat("p1")'); await wait(350);

    ok((w.__peek("S.connections") || []).includes("p1"), "you start out connected");
    ok((w.__peek("Object.keys(S.threads)") || []).includes("p1"),
       "with their messages on this device");

    /* the other person removes you: the server simply stops listing it */
    opts.convos = [];
    w.__peek("refreshConvos(true)"); await wait(450);

    ok(!(w.__peek("S.connections") || []).includes("p1"),
       "after a refresh they are no longer a connection");
    ok(!(w.__peek("Object.keys(S.threads)") || []).includes("p1"),
       "and their messages are gone from this device too");
    ok(w.__peek("chatId") === null,
       "and you are taken out of the conversation rather than left typing into it");
  }

  console.log("\n55a9. COMING BACK TO A TAB LEFT OPEN");
  {
    const { w, api } = await boot(true, signedIn({ convos: DISC_CONVOS }));
    await wait(200);
    w.__peek('go("chats")'); await wait(300);
    const before = api._log.filter((l) => l === "convoList").length;
    w.__peek('lastConvoCheck = 0');
    w.__peek('document.dispatchEvent(new Event("visibilitychange"))');
    await wait(400);
    const after = api._log.filter((l) => l === "convoList").length;
    ok(after > before, "coming back to the app re-asks who you are connected to",
       `convos calls before ${before}, after ${after}`);
  }

  /* ------------------------------------------------------------
     SOMEBODY ELSE POSTS

     Hasan posted and nothing appeared on hey's phone. Two
     reasons: `posts` was never in Supabase's realtime
     publication (post_likes and post_comments were, from back in
     04, but not the table they hang off), and the feed only ever
     loaded once — the condition guarding it fired while
     LIVEPOSTS was empty, so coming back to Feed did nothing.
     ------------------------------------------------------------ */
  console.log("\n55b0. A POST SOMEBODY ELSE MADE");
  {
    const opts = signedIn({ feed: [] });
    const { w, api } = await boot(true, opts);
    await wait(250);
    w.__peek('go("feed")'); await wait(300);

    ok(api._log.includes("watchPosts"),
       "the app listens for posts other people make");

    const first = api._log.filter((l) => l.startsWith("feedPage")).length;

    /* Hasan posts. The server now has it; this phone does not. */
    opts.feed = [{ id: "np1", author_id: "p9", body: "drummer needed Thursday",
      tag: "looking", created_at: new Date().toISOString(), like_count: 0,
      comment_count: 0, author_name: "Hasan", author_handle: "hasan",
      author_city: "Boston", author_photo: null, liked_by_me: false, mine: false }];

    w.__peek("lastFeedCheck = 0");
    api._onNewPost && api._onNewPost({ id: "np1", author_id: "p9" });
    await wait(500);

    ok(api._log.filter((l) => l.startsWith("feedPage")).length > first,
       "and refetches when one arrives");
    ok(/drummer needed Thursday/.test(w.document.querySelector("#feed").textContent),
       "so the post actually shows up");
  }

  console.log("\n55b1. COMING BACK TO THE FEED");
  {
    /* the feed must already have something in it, or the old
       load-once guard ("only if LIVEPOSTS is empty") fires anyway and
       this test passes against the very bug it is here to catch */
    const opts = signedIn({ feed: [{ id: "old1", author_id: "p9",
      body: "bass player here", tag: "looking",
      created_at: "2026-11-20T10:00:00Z", like_count: 0, comment_count: 0,
      author_name: "Hasan", author_handle: "hasan", author_city: "Boston",
      author_photo: null, liked_by_me: false, mine: false }] });
    const { w, api } = await boot(true, opts);
    await wait(250);
    w.__peek('go("feed")'); await wait(300);
    w.__peek('go("you")'); await wait(150);

    const before = api._log.filter((l) => l.startsWith("feedPage")).length;
    w.__peek("lastFeedCheck = 0");
    w.__peek('go("feed")'); await wait(400);
    ok(api._log.filter((l) => l.startsWith("feedPage")).length > before,
       "opening Feed again re-asks the server",
       "it used to load once and never again");
  }

  console.log("\n55b2. COMING BACK TO THE APP");
  {
    const opts = signedIn({ feed: [] });
    const { w, api } = await boot(true, opts);
    await wait(250);
    w.__peek('go("feed")'); await wait(300);
    const before = api._log.filter((l) => l.startsWith("feedPage")).length;
    w.__peek("lastFeedCheck = 0");
    w.__peek('document.dispatchEvent(new Event("visibilitychange"))');
    await wait(400);
    ok(api._log.filter((l) => l.startsWith("feedPage")).length > before,
       "returning to the app checks for posts too");
  }

  console.log("\n55b. CHANGING YOUR MIND leaves it alone");
  {
    const { w, api } = await boot(true, signedIn({ myTracks: MYTRACKS }));
    await wait(280);
    w.__peek('go("you")'); await wait(220);
    w.document.querySelector("[data-rmtrack]").click(); await wait(160);

    const keep = [...w.document.querySelectorAll(".trow button")]
      .find((b) => /keep it/i.test(b.textContent));
    ok(!!keep, "there is a way out of it");
    keep.click(); await wait(200);
    ok(!api._log.some((l) => l.startsWith("removeTrack")), "and nothing is removed");
    ok(/Kitchen Demo 2/.test(w.document.querySelector("#you").textContent),
       "and the recording is still there");
  }

  console.log("\n55c. A REFUSED REMOVAL says why, and keeps the track");
  {
    const { w } = await boot(true, signedIn({
      myTracks: MYTRACKS, removeTrackFails: "that recording isn't yours" }));
    await wait(280);
    w.__peek('go("you")'); await wait(220);
    w.document.querySelector("[data-rmtrack]").click(); await wait(160);
    w.document.querySelector("[data-rmtrack-yes]").click(); await wait(300);
    const t = w.document.querySelector("#toast");
    ok(t && /isn't yours/i.test(t.textContent), "the reason is shown");
    ok(/Kitchen Demo 2/.test(w.document.querySelector("#you").textContent),
       "and the recording stays");
  }

  console.log("\n55d. AND THE PLAY BUTTON ON YOUR PROFILE knows what is playing");
  {
    /* Same bug as the chart had: the button carried "me:"+title while the
       player keys on the track's id, so the icon never changed to pause. */
    const { w } = await boot(true, signedIn({ myTracks: MYTRACKS }));
    await wait(280);
    w.__peek('go("you")'); await wait(220);
    const playBtn = w.document.querySelector(".trow [data-play]");
    w.__peek('play(S.me.tracks[0], S.me)'); await wait(200);
    ok(playBtn.dataset.play === w.__peek("nowPlaying"),
       "the button and the player agree on what is playing");
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
