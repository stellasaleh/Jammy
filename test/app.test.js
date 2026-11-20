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
    _blocked: new Set(),
    sb: { rpc: async (n, a) => { log.push("rpc:" + n); return { data: [], error: null }; },
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
      setLocation: async () => { log.push("setLocation"); return { data: {}, error: null }; },
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
        const rows = (opts.convos || []).filter((c) => !api._blocked.has(c.other_id));
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
      markRead: async (c) => { log.push("markRead:" + c); return { data: {}, error: null }; },
    },
    feed: { posts: async () => ({ data: [], error: null }), comments: async () => ({ data: [], error: null }), comment: async () => ({ data: {}, error: null }), deleteComment: async () => ({ data: {}, error: null }), subscribeComments: () => ({}), unsubscribe: () => {}, like: async () => ({ data: {}, error: null }), likers: async () => ({ data: [], error: null }), post: async () => ({ data: {}, error: null }) },
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
      requests: async (b) => { log.push("bandRequests:" + (b || "all")); return { data: opts.bandRequests || [], error: null }; },
      requestCount: async () => ({ data: (opts.bandRequests || []).length, error: null }),
      answerRequest: async (r, y) => { log.push("answerBandRequest:" + r + ":" + y); return opts.answerBandFails ? err(opts.answerBandFails) : { data: true, error: null }; },
      media: async () => ({ data: [], error: null }),
    },
    clips: {}, radio: { chart: async () => ({ data: [], error: null }), logPlay: async () => ({}) },
    safety: {
      blocked: async () => ({ data: [], error: null }),
      block: async (id) => {
        log.push("block:" + id);
        if (opts.blockFails) return err(opts.blockFails);
        api._blocked.add(id);
        return { data: {}, error: null };
      },
      unblock: async (id) => { log.push("unblock:" + id); api._blocked.delete(id); return { data: {}, error: null }; },
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
  const BANDEVENTS = [
    { id: "e1", kind: "practice", starts_at: "2026-11-26T19:00:00Z", ends_at: null,
      place: "Sound Museum", address: "Room 214", note: "bring the PA",
      visibility: "members", mine: true },
    { id: "e2", kind: "gig", starts_at: "2026-11-29T20:00:00Z", ends_at: null,
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
    ok(w.__peek("ALLBANDS()[0].members.length") === 2, "both members are there");
    ok(w.__peek("ALLBANDS()[0].members[1].role") === "Bass", "with what each plays");
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
    ok(/Look anywhere/i.test(txt), "and offers to widen the search");
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

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
