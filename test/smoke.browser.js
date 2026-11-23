/* CLICK EVERYTHING.
   Opens the real app in a real browser, signed in, with a fake server
   underneath, and clicks every primary control — checking that something
   actually happens. A button that renders and does nothing passes every
   unit test ever written about the function behind it. Two have now
   shipped that way. */
const { chromium } = require("playwright");
const http = require("http"), fs = require("fs"), path = require("path");

/* Run against the working copy by default, so this tests what was just
   changed rather than what was last deployed. */
const ROOT = process.env.ROOT || "/mnt/user-data/outputs/jammy/www";
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".png": "image/png",
                ".webmanifest": "application/manifest+json" };

let pass = 0, fail = 0;
const ok = (c, m) => { c ? (pass++, console.log("  ✓ " + m)) : (fail++, console.log("  ✗ " + m)); };

const FAKE_API = `
/* stands in for api.js so the real app talks to a server we control */
const rows = {
  profile: {id:"u1",handle:"stella",display_name:"Stella Saleh",city:"Boston",
            instruments:["Trumpet"],genres:["Jazz"],looking_for:"Form a band",
            /* has_location, not location. Since 23_columns.sql the real
               server never returns the coordinate to anybody, so a fake
               that still hands one over is testing a server that no longer
               exists, and the srvLoc path goes uncovered. */
            rehearsal_days:["Wed"],has_location:true,bio:""},
  people: [{id:"p1",display_name:"Mina Okafor",handle:"minabass",city:"Boston",
            instruments:["Bass"],genres:["Jazz"],looking_for:"A band",bio:"",
            photo_path:null,miles:2.4,shared_genres:["Jazz"],they_need_me:["Trumpet"],
            is_remote:false,fit:82}],
  bands: [{id:"band1",name:"The Flaming Weirdos",city:"Boston",genres:["Jazz"],
           about:"",avatar_path:null,my_role:"Horns",i_am_admin:true,member_count:1,
           next_kind:null,next_at:null,next_place:null}],
  /* band_roster() includes YOU. The band page draws you separately at the
     top, so the app has to drop your own row or you appear twice. */
  roster: [{user_id:"u1",display_name:"Stella Saleh",handle:"stella",photo_path:null,
            instruments:["Trumpet"],role_label:"Horns",is_admin:true,on_jammy:true},
           {user_id:"u7",display_name:"Hasan Reza",handle:"hasan",photo_path:null,
            instruments:["Bass"],role_label:"Bass",is_admin:false,on_jammy:true}],
  /* What band_schedule() hands a NON-MEMBER: the public gig, with no
     address and no note, and no sign of the practice at all. The real
     function decides this; the fake must not be more generous than it. */
  chart: [1,2,3,4,5].map(n=>({track_id:"t"+n,title:"Track "+n,key:"Am",bpm:100,
            audio_path:"u5/t"+n+".mp3",owner_id:"u"+n,artist_name:"Artist "+n,
            artist_handle:"a"+n,artist_photo:null,plays:20-n,listeners:10-n,
            last_week_rank:n+1,rank:n,is_new:false,move:1,mine:false})),
  rising: [{track_id:"tr9",title:"First Take",key:"C",bpm:92,
            audio_path:"u9/tracks/first.mp3",duration_ms:95000,plays:0,
            artist_id:"u9",artist_name:"Bo Kerrigan",artist_handle:"bo",
            artist_photo:null,artist_city:"Boston",
            artist_bio:"Just moved here, looking for people.",
            artist_instruments:["Drums"],artist_genres:["Indie"],
            shared_genres:["Indie"],miles:2.4,uploaded_days_ago:0}],
  myTracks: [{id:"t1",title:"Kitchen Demo 2",key:"A minor",bpm:104,
              audio_path:"u1/tracks/abc.mp3",is_public:true,
              created_at:new Date().toISOString(),plays:0}],
  feed: [{id:"f1",author_id:"u5",body:"Looking for a drummer. Tuesdays, Brighton.",
          tag:"looking",track_id:null,media_path:null,
          fields:{instrument:"Drums",when:"Tue evenings",where:"Brighton"},
          created_at:new Date(Date.now()-36e5).toISOString(),
          like_count:3,comment_count:1,author_name:"Rue Delacroix",
          author_handle:"rue",author_city:"Boston",author_photo:null,
          liked_by_me:false,mine:false}],
  chart: [1,2,3,4,5].map(n=>({track_id:"t"+n,title:"Track "+n,key:"Am",bpm:100,
            audio_path:"u5/t"+n+".mp3",owner_id:"u"+n,artist_name:"Artist "+n,
            artist_handle:"a"+n,artist_photo:null,plays:20-n,listeners:10-n,
            last_week_rank:n+1,rank:n,is_new:false,move:1,mine:false})),
  rising: [{track_id:"tr9",title:"First Take",key:"C",bpm:92,
            audio_path:"u9/tracks/first.mp3",duration_ms:95000,plays:0,
            artist_id:"u9",artist_name:"Bo Kerrigan",artist_handle:"bo",
            artist_photo:null,artist_city:"Boston",
            artist_bio:"Just moved here, looking for people.",
            artist_instruments:["Drums"],artist_genres:["Indie"],
            shared_genres:["Indie"],miles:2.4,uploaded_days_ago:0}],
  myTracks: [{id:"t1",title:"Kitchen Demo 2",key:"A minor",bpm:104,
              audio_path:"u1/tracks/abc.mp3",is_public:true,
              created_at:new Date().toISOString(),plays:0}],
  feed: [{id:"f1",author_id:"u5",body:"Looking for a drummer. Tuesdays, Brighton.",
          tag:"looking",track_id:null,media_path:null,
          fields:{instrument:"Drums",when:"Tue evenings",where:"Brighton"},
          created_at:new Date(Date.now()-36e5).toISOString(),
          like_count:3,comment_count:1,author_name:"Rue Delacroix",
          author_handle:"rue",author_city:"Boston",author_photo:null,
          liked_by_me:false,mine:false}],
  schedule: [{id:"e9",kind:"gig",
              starts_at:new Date(Date.now()+6*864e5).toISOString(),
              ends_at:null,place:"The Middle East",address:null,note:null,
              visibility:"public",mine:false}],
  convos: [], requests: [], messages: [],
  gigs: [{event_id:"e9",band_id:"band9",band_name:"The Fog Signals",
          band_genres:["Indie"],band_avatar:null,
          starts_at:new Date(Date.now()+6*864e5).toISOString(),
          place:"The Middle East",city:"Boston",miles:2.8,i_am_member:false}],
  otherRoster: [{user_id:"u9",display_name:"Hey Sandoval",handle:"hey",photo_path:null,
                 instruments:["Guitar"],role_label:"Guitar",is_admin:true,on_jammy:true},
                {user_id:"u8",display_name:"Rue Delacroix",handle:"rue",photo_path:null,
                 instruments:["Drums"],role_label:"Drums",is_admin:false,on_jammy:true}],
  bandPage: [{id:"band9",name:"The Fog Signals",city:"Boston",genres:["Indie"],
              about:"We practise Tuesdays",avatar_path:null,member_count:2,
              next_gig:new Date(Date.now()+6*864e5).toISOString(),
              i_am_member:false,i_am_admin:false,my_request:null}],
  bandRequests: [{request_id:"q1",band_id:"band1",band_name:"The Flaming Weirdos",
                  user_id:"u7",display_name:"Hasan",handle:"hasan",photo_path:null,
                  instruments:["Bass"],role_label:"Bass",
                  note:"saw you at the Middle East",
                  asked_at:new Date().toISOString()}]
};
window.__calls = [];
const okr = (d) => Promise.resolve({ data: d, error: null });
  window.__rows = rows;
window.JammyAPI = {
  sb: { rpc: (n,a) => { window.__calls.push("rpc:"+n);
          if (n === "rising_track")  return okr(rows.rising);
          if (n === "weekly_chart")  return okr(rows.chart);
          if (n === "listening_now") return okr(3);
          if (n === "my_posts" || n === "posts_by") return okr([]);
          if (n === "tracks_by")     return okr(rows.myTracks);
          return okr([]); },
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
           /* A band you are NOT in has a roster without you in it. The
              fake used to hand back your own band's roster for every
              band, which quietly hid the bug this now checks for. */
           roster: (b) => okr(b === "band9" ? rows.otherRoster : rows.roster),
           schedule: () => okr(rows.schedule),
           /* A real server answers my_bands() with the band it just made.
              A fake that forgets to is a fake that tests a world which
              does not exist — and it hid a freeze in openBand(). */
           create: (f) => { window.__calls.push("bands.create:"+f.name);
                            rows.bands.push({id:"band2",name:f.name,city:f.city||"",
                              genres:f.genres||[],about:"",avatar_path:null,
                              my_role:f.myRole||"Member",i_am_admin:true,member_count:1,
                              next_kind:null,next_at:null,next_place:null});
                            return okr("band2"); },
           /* join_band returns FALSE since joining became asking. A fake
              that returns true tests a world that no longer exists. */
           join: (b) => { window.__calls.push("bands.join:"+b); return okr(false); },
           leave: (b) => { window.__calls.push("bands.leave:"+b);
                           rows.bands = rows.bands.filter(x => x.id !== b);
                           return okr(true); },
           removeMember: (b,u) => { window.__calls.push("bands.removeMember:"+b+":"+u);
                                    rows.roster = rows.roster.filter(x => x.user_id !== u);
                                    return okr(true); },
           addEvent: (b,e) => { window.__calls.push("bands.addEvent:"+e.kind); return okr("ev1"); },
           cancelEvent: () => okr(true), schedule_mine: () => okr([]),
           gigsNearMe: (m,d) => { window.__calls.push("bands.gigsNearMe:"+m); return okr(rows.gigs); },
           page: (b) => { window.__calls.push("bands.page:"+b); return okr(rows.bandPage); },
           askToJoin: (b) => { window.__calls.push("bands.askToJoin:"+b); return okr("sent"); },
           requests: (b) => { window.__calls.push("bands.requests"); return okr(rows.bandRequests); },
           requestCount: () => okr(rows.bandRequests.length),
           answerRequest: (r,y) => { window.__calls.push("bands.answerRequest:"+r+":"+y);
                                     rows.bandRequests = []; return okr(true); },
           media: () => okr([]) },
  feed: { posts: (b,n,bid) => { window.__calls.push("feed.posts:"+(b?"more":"first")); return okr(rows.feed); },
          comments: () => okr([]), comment: () => okr({}),
          deleteComment: () => okr({}), subscribeComments: () => ({}), unsubscribe: () => {},
          like: () => okr({}), likers: () => okr([]), post: () => okr({}),
          upload: (blob,kind) => { window.__calls.push("feed.upload:"+kind); return okr("u1/posts/x.jpg"); },
          mediaUrl: (p) => p ? "/_m/"+p : null,
          remove: (id) => { window.__calls.push("feed.remove:"+id);
                            rows.feed = rows.feed.filter(x=>x.id!==id); return okr(null); } },
  account: { export: () => { window.__calls.push("account.export");
                             return okr({profile:{display_name:"Stella Saleh"},posts:[]}); },
             remove: (w) => { window.__calls.push("account.remove:"+w); return okr({deleted:true}); } },
  clips: { send: () => okr({}), url: () => okr("") },
  radio: { chart: () => okr(rows.chart || []),
           logPlay: (id,secs) => { window.__calls.push("logPlay:"+id); return okr(null); },
           upload: (blob,meta) => { window.__calls.push("uploadTrack:"+(meta&&meta.title)); return okr({id:"t9"}); },
           url: (p) => p ? "/_t/"+p : null,
           mine: () => okr(rows.myTracks || []),
           removeTrack: (id) => { window.__calls.push("removeTrack:"+id);
                                  rows.myTracks = rows.myTracks.filter(t=>t.id!==id);
                                  return okr(true); } },
  safety: { blocked: () => okr([]), block: (id) => { window.__calls.push("block"); return okr({}); },
            unblock: () => okr({}), report: () => { window.__calls.push("report"); return okr({}); } },
};
`;

/* only this needs to run before the page does */
const PRIME = `try { localStorage.setItem("jammy:v1", JSON.stringify({ onboarded: true, firstRun: false })); } catch (e) {}`;

(async () => {
  /* 1 second of 8kHz mono silence: a 44-byte RIFF header and 8000 zeroes. */
  const SILENT_WAV = (() => {
    const data = 8000, b = Buffer.alloc(44 + data);
    b.write("RIFF", 0); b.writeUInt32LE(36 + data, 4); b.write("WAVE", 8);
    b.write("fmt ", 12); b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20);
    b.writeUInt16LE(1, 22); b.writeUInt32LE(8000, 24); b.writeUInt32LE(8000, 28);
    b.writeUInt16LE(1, 32); b.writeUInt16LE(8, 34);
    b.write("data", 36); b.writeUInt32LE(data, 40);
    b.fill(128, 44);                       // 128 is silence for 8-bit PCM
    return b;
  })();

  const srv = http.createServer((req, res) => {
    const u = req.url.split("?")[0];
    if (u === "/api.js") {               // serve the fake in place of the real one
      res.writeHead(200, { "Content-Type": "text/javascript" });
      res.end(FAKE_API);
      return;
    }
    /* A real, if silent, sound file for the uploaded-track paths. Serving a
       404 here made the player stop the moment it started, which looked
       like a bug in the player and was a gap in this server. */
    if (u.startsWith("/_t/") || u.startsWith("/_m/")) {
      res.writeHead(200, { "Content-Type": "audio/wav" });
      res.end(SILENT_WAV);
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
  await page.addInitScript(() => { window.__pageErrors = [];
    window.addEventListener("error", e => window.__pageErrors.push(String(e.message))); });
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

  console.log("\n-- the feed, which used to be eight invented musicians --");
  await page.evaluate(() => go("feed")); await page.waitForTimeout(600);
  {
    const txt = await page.textContent("#feed");
    ok(await page.evaluate(() => LIVEPOSTS.length > 0), "the feed came from the server");
    ok(/Rue Delacroix/.test(txt), "and a real post is on it");
    ok(/Brighton/.test(txt), "with what they are looking for, not just the prose");
    ok(!/Kitchen Demo/.test(txt), "and nothing invented");
    const stories = await page.$$("#stories .story");
    ok(stories.length <= 1, `no invented stories either (${stories.length} tiles, only your own)`);
  }

  clear();
  if (await clickIt('[data-like="f1"]', "the like button can be pressed")) {
    pass++; console.log("  ✓ the like button can be pressed");
    await page.waitForTimeout(400);
    const n = await page.evaluate(() => LIVEPOSTS.find(p => p.id === "f1").likes);
    ok(n === 4, `the count moves with the heart (now ${n})`);
  }

  console.log("\n-- your own band: the roster, removing somebody, and leaving --");
  await page.evaluate(() => { document.querySelector("#bandview").classList.remove("on"); openBand("band1"); });
  await page.waitForTimeout(700);
  {
    const body = await page.textContent("#bv-body");
    /* band_roster() includes you. Left in, you appeared twice and were
       counted twice. */
    const yous = (body.match(/Stella Saleh/g) || []).length;
    ok(yous <= 1, `you appear once on your own band page, not twice (found ${yous})`);
    ok(/Hasan Reza/.test(body), "and the other member is listed");
    ok(/2 people/.test(body), "and the count is right");
  }

  clear();
  const rmSel = await page.evaluate(() => {
    const b = document.querySelector("[data-remove]");
    if (!b) return null;
    b.id = b.id || "__rm"; return "#" + b.id;
  });
  ok(!!rmSel, "whoever runs the band is offered a way to remove somebody");
  if (rmSel && await clickIt(rmSel, "Remove can be pressed")) {
    pass++; console.log("  ✓ Remove can be pressed");
    await page.waitForTimeout(300);
    /* It must ask first, and it must ask INSIDE the page: the artifact
       viewer and some phone browsers never show confirm(), and a
       confirmation that silently returns false is a button that does
       nothing at all. */
    ok(/Take Hasan Reza out of/i.test(await page.textContent("#bv-body")),
       "and it asks first, in the page rather than in a dialog");
    ok((await calls()).every((c) => !c.startsWith("bands.removeMember")),
       "and has not removed anybody yet");

    const yesSel = await page.evaluate(() => {
      const b = document.querySelector("[data-remove-yes]");
      if (!b) return null;
      b.id = b.id || "__rmyes"; return "#" + b.id;
    });
    if (yesSel && await clickIt(yesSel, "confirming the removal can be pressed")) {
      pass++; console.log("  ✓ confirming the removal can be pressed");
      await page.waitForTimeout(700);
      ok((await calls()).some((c) => c === "bands.removeMember:band1:u7"),
         "and it reaches the server");
      ok(!/Hasan Reza/.test(await page.textContent("#bv-body")),
         "and they are off the band page");
    }
  }

  console.log("\n-- leaving a band has to reach the server --");
  /* THE BUG: this button edited what the phone believed and never told
     the database. You stayed on the roster, stayed in the band chat, and
     could still read the rehearsal address. */
  clear();
  const lvSel = await page.evaluate(() => {
    const b = [...document.querySelectorAll("#bv-body button")]
      .find((x) => /leave this band/i.test(x.textContent || ""));
    if (!b) return null;
    b.id = b.id || "__leave"; return "#" + b.id;
  });
  ok(!!lvSel, "a member is offered a way to leave");
  if (lvSel && await clickIt(lvSel, "Leave can be pressed")) {
    pass++; console.log("  ✓ Leave can be pressed");
    await page.waitForTimeout(700);
    ok((await calls()).some((c) => c === "bands.leave:band1"),
       "and leaving actually tells the server");
    ok((await page.evaluate(() => S.joined.includes("band1"))) === false,
       "and the band is off your list");
  }

  /* Put the band back before the wider walk. Leaving really removes it
     now, and the screens further down are about being IN a band — without
     this they fail for the right reason at the wrong moment. */
  await page.evaluate(() => {
    window.__rows.bands.push({id:"band1",name:"The Flaming Weirdos",city:"Boston",
      genres:["Jazz"],about:"",avatar_path:null,my_role:"Horns",i_am_admin:true,
      member_count:1,next_kind:null,next_at:null,next_place:null});
  });
  await page.evaluate(() => loadBands());
  await page.waitForTimeout(400);
  ok(await page.evaluate(() => S.joined.includes("band1")), "and rejoining puts it back");

  console.log("\n-- a band that cannot be fetched gives up, rather than freezing --");
  /* THE BUG THIS CATCHES: openBand() re-opened on faith after fetching,
     so a band the server never returns sent it round and round. The page
     locked up, and every control after it failed for no visible reason. */
  await page.evaluate(() => { document.querySelector("#bandview").classList.remove("on"); });
  const froze = await page.evaluate(async () => {
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    const before = window.__calls.length;
    openBand("band-that-does-not-exist");
    await sleep(900);
    const asks = window.__calls.slice(before).filter((c) => c.startsWith("bands.page")).length;
    return { asks, text: (document.querySelector("#bv-body") || {}).textContent || "" };
  });
  ok(froze.asks <= 2, `it asks the server once or twice, not forever (asked ${froze.asks} times)`);
  ok(/isn't here|out of date/i.test(froze.text), "and says plainly that the band is not there");
  ok(await page.evaluate(() => { go("disc"); return true; }), "and the app still answers afterwards");

  console.log("\n-- gigs near you --");
  /* The screen that did not exist. Every click here is a REAL click, so
     anything sitting on top of these controls fails the test rather than
     passing it the way a scripted .click() would. */
  await page.evaluate(() => go("disc")); await page.waitForTimeout(250);
  clear();
  if (await clickIt("#m-gigs", "the Gigs tab can be pressed")) {
    pass++; console.log("  ✓ the Gigs tab can be pressed");
    await page.waitForTimeout(500);
    ok((await calls()).some((x) => x.startsWith("bands.gigsNearMe")), "and it asks the server for gigs");
    ok(await visible("#gigs"), "the gig list is on screen");
    const txt = await page.textContent("#gigs");
    ok(/Fog Signals/.test(txt), "a band you are not in appears");
    ok(/Middle East/.test(txt), "with the venue");
    ok(!/practice/i.test(txt.replace(/Practices never do[^.]*\./i, "")), "and no practice anywhere on it");
    ok(!(await visible("#deck")) || (await page.evaluate(() => getComputedStyle(document.querySelector("#deck")).display)) === "none",
       "and the people deck is out of the way");
  }

  clear();
  if (await clickIt("#gigs .evrow", "a gig row can be pressed")) {
    pass++; console.log("  ✓ a gig row can be pressed");
    await page.waitForTimeout(600);
    ok((await calls()).some((x) => x === "bands.page:band9"), "and it fetches that band");
    ok(await visible("#bandview"), "and opens the band page");
    const body = await page.textContent("#bv-body");
    ok(/Fog Signals/.test(body), "showing the band");
    ok(/not in this band/i.test(body), "and saying you are not in it");
    ok(/Middle East/.test(body), "and the gig is on their page too");
    ok(!/Dane St|bring the/i.test(body), "with no address and no band note");

    /* THE BUG STELLA FOUND. The Members list always opened with you,
       tagged YOU, and the count always added one for you, whether or not
       you were in the band. Nobody could hit it until gigs made band
       pages reachable by people who are not members. */
    ok((await page.$$("#bv-body .tagme")).length === 0,
       "and no YOU tag, because you are not one of them");
    ok(!/Stella Saleh/.test(body),
       "and you are not in the members list at all");
    ok(/Members[\s\S]{0,40}?2 people/.test(body),
       "and the count is the band, not the band plus you");
  }

  console.log("\n-- asking to join a band you are not in --");
  clear();
  const askSel = await page.evaluate(() => {
    const b = [...document.querySelectorAll("#bv-body button")]
      .find((x) => /ask to join/i.test(x.textContent || ""));
    if (!b) return null;
    b.id = b.id || "__ask";
    return "#" + b.id;
  });
  ok(!!askSel, "a non-member is offered Ask to join");
  if (askSel && await clickIt(askSel, "the Ask to join button can be pressed")) {
    pass++; console.log("  ✓ the Ask to join button can be pressed");
    await page.waitForTimeout(500);
    ok((await calls()).some((x) => x === "bands.askToJoin:band9"), "and it reaches the server");
    ok(/asked to join/i.test(await page.textContent("#bv-body")), "and the page says it is waiting on them");
    ok((await page.evaluate(() => S.joined.includes("band9"))) === false,
       "and asking did NOT put you in the band");
  }

  console.log("\n-- approving somebody who asked to join --");
  await page.evaluate(() => { document.querySelector("#bandview").classList.remove("on"); go("chats"); });
  await page.waitForTimeout(600);
  const chats = await page.textContent("#chats");
  ok(/Wants to join your band/i.test(chats), "the request shows up in Chats");
  ok(/Hasan/.test(chats), "with who is asking");
  clear();
  if (await clickIt("[data-bq-yes]", "Approve can be pressed")) {
    pass++; console.log("  ✓ Approve can be pressed");
    await page.waitForTimeout(500);
    ok((await calls()).some((x) => x === "bands.answerRequest:q1:true"), "and it reaches the server");
    ok(!/Wants to join your band/i.test(await page.textContent("#chats")), "and the request clears");
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


  console.log("-- the video call is gone --");
  ok(await page.evaluate(() => typeof openCallWith === "undefined"),
     "there is no call function left");
  ok(!(await page.$("#ch-call")), "no call button in a conversation");
  ok(!(await page.$("#call")), "and no call screen in the page");

  console.log("\n-- the top three, and somebody new --");
  await page.evaluate(() => go("radio")); await page.waitForTimeout(700);
  {
    const pods = await page.$$("#radio .podrow");
    ok(pods.length === 3, `the top three are set apart (${pods.length} of them)`);
    ok(/1st/.test(await page.textContent("#radio .podrow.p1")), "and the first says so");
    ok((await page.$$("#radio .lbrow")).length === 2, "with the rest as an ordinary list");

    const card = await page.$("#radio .newartist");
    ok(!!card, "and there is somebody new to discover");
    const txt = await page.textContent("#radio .newartist");
    ok(/Bo Kerrigan/.test(txt), "with their name");
    ok(/First Take/.test(txt), "and their track");
    ok(/Just moved here/.test(txt), "and something about them");

    /* a real click, because a card at the bottom of a scrolling screen is
       exactly where a button ends up under something else */
    clear();
    if (await clickIt("[data-naplay]", "their track can be played")) {
      pass++; console.log("  ✓ their track can be played");
      await page.waitForTimeout(300);
      ok(await page.evaluate(() => nowPlaying === "t:tr9"), "and it starts");
      await page.evaluate(() => stopAudio());
    }
    if (await clickIt("[data-naprofile]", "and their profile can be opened")) {
      pass++; console.log("  ✓ and their profile can be opened");
      await page.waitForTimeout(300);
      ok(/Bo Kerrigan/.test(await page.textContent("#sheetbody")), "and it is them");
      await page.evaluate(() => document.querySelector("#sheet").classList.remove("on"));
    }
  }

  console.log("\n-- the radio plays the recording, not a synthesiser --");
  await page.evaluate(() => go("you")); await page.waitForTimeout(500);
  {
    ok(await page.evaluate(() => S.me.tracks.length > 0), "your recordings load from the server");
    ok(await page.evaluate(() => !!S.me.tracks[0].path), "and each knows where its file is");
    clear();
    const ok1 = await page.evaluate(() => {
      play(S.me.tracks[0], { id: "u1", name: "Stella Saleh" });
      return typeof realAudio !== "undefined" && realAudio !== null;
    });
    ok(ok1, "pressing play opens the actual recording");
    await page.evaluate(() => { realPlayedFor = 31; reportPlay(); });
    await page.waitForTimeout(300);
    ok((await calls()).some((c) => c === "logPlay:t1"), "and a full listen is reported, so the chart can fill");
    await page.evaluate(() => stopAudio());
  }

  console.log("\n-- taking a recording back down --");
  await page.evaluate(() => go("you")); await page.waitForTimeout(700);
  {
    ok(!!(await page.$("[data-rmtrack]")), "your own recording has a way to remove it");
    clear();
    if (await clickIt("[data-rmtrack]", "the remove button can be pressed")) {
      pass++; console.log("  \u2713 the remove button can be pressed");
      await page.waitForTimeout(350);
      ok(/off your profile and the radio/i.test(await page.textContent("#you .trow")),
         "and it asks first, in the row rather than in a dialog");
      ok(!(await calls()).some((c) => c.startsWith("removeTrack")), "with nothing removed yet");

      if (await clickIt("[data-rmtrack-yes]", "and confirming can be pressed")) {
        pass++; console.log("  \u2713 and confirming can be pressed");
        await page.waitForTimeout(700);
        ok((await calls()).some((c) => c === "removeTrack:t1"), "which removes it for real");
        ok(!/Kitchen Demo 2/.test(await page.textContent("#you")), "and it leaves your profile");
      }
    }
  }

  console.log("\n-- the last thing, because it ends the session --");
  console.log("\n-- delete my account, which Apple requires --");
  await page.evaluate(() => openDeleteAccount()); await page.waitForTimeout(400);
  {
    const body = await page.textContent("#sheetbody");
    ok(/cannot be undone/i.test(body), "it says plainly that it cannot be undone");
    ok(!!(await page.$("#da-word")), "and makes you type the word");
    clear();
    if (await clickIt("#da-go", "the delete button can be pressed")) {
      pass++; console.log("  ✓ the delete button can be pressed");
      await page.waitForTimeout(300);
      ok(!(await calls()).some((c) => c.startsWith("account.remove")),
         "and pressing it WITHOUT the word deletes nothing");
    }
    await page.fill("#da-word", "delete");
    clear();
    if (await clickIt("#da-go", "and with the word it can be pressed")) {
      pass++; console.log("  ✓ and with the word it can be pressed");
      await page.waitForTimeout(600);
      ok((await calls()).some((c) => c === "account.remove:delete"),
         "and that reaches the server");
      /* the old reset rebuilt the settings without `filters`, so the next
         render threw and the screen went blank with nothing to explain it */
      const errs = await page.evaluate(() => window.__pageErrors || []);
      ok(errs.length === 0, errs.length ? "it threw: " + errs[0] : "and clearing the app does not throw");
    }
  }


  console.log(`\n${pass} passed, ${fail} failed`);
  await browser.close();
  srv.close();
  process.exit(fail ? 1 : 0);
})();
