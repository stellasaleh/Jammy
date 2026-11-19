/* ============================================================
   JAMMY — api.js
   The data layer. Swap localStorage calls for these, one at a time.

   Load it before index.html's own script:
     <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js"></script>
     <script src="api.js"></script>

   Your keys live in config.js — that's the only file you edit.
   The anon key is PUBLIC and safe to ship; row-level security is
   what protects your data, not key secrecy.
   ============================================================ */
(function () {
  "use strict";

  const cfg = window.JAMMY_CONFIG || {};
  const SUPABASE_URL = cfg.url;
  const SUPABASE_ANON_KEY = cfg.anonKey;

  /* no keys yet, or supabase-js blocked: stay in demo mode quietly */
  if (!window.JAMMY_LIVE) {
    window.JammyAPI = null;
    console.info("Jammy: demo mode. Add your keys to config.js to go live.");
    return;
  }
  if (!window.supabase) {
    console.error("Jammy: supabase-js didn't load — staying in demo mode.");
    window.JammyAPI = null;
    return;
  }
  const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true },
  });

  /* ------------------------------------------------------------------
     WHO AM I

     Every write used to begin with auth.getUser(), which is a network
     round trip to the auth server AND takes an internal lock on the
     session. Called from inside another auth-related operation it can
     wait on a lock that is never released, and then it waits forever —
     no error, no timeout, just a button that says "Creating your
     profile…" until the page is closed.

     getSession() reads what is already on the device. No network, no
     lock, no deadlock. We cache it and let the auth listener keep it
     current.
     ------------------------------------------------------------------ */
  let CURRENT_UID = null;
  async function uid() {
    if (CURRENT_UID) return CURRENT_UID;
    try {
      const { data } = await sb.auth.getSession();
      CURRENT_UID = data && data.session && data.session.user ? data.session.user.id : null;
    } catch (e) {
      CURRENT_UID = null;
    }
    return CURRENT_UID;
  }
  sb.auth.onAuthStateChange((_e, session) => {
    CURRENT_UID = session && session.user ? session.user.id : null;
  });

  /* ------------------------------------------------------------------
     NOTHING WAITS FOREVER

     A request that never answers is worse than one that fails: the app
     has no way to tell the person anything. Every call gets a ceiling.
     ------------------------------------------------------------------ */
  const CALL_TIMEOUT_MS = cfg.timeoutMs || 20000;
  function withTimeout(promise, ms) {
    let t;
    const limit = new Promise((_, reject) => {
      t = setTimeout(
        () => reject(new Error("The server didn't answer in time. Check your connection and try again.")),
        ms
      );
    });
    return Promise.race([promise, limit]).finally(() => clearTimeout(t));
  }

  /* every call returns {data, error} — never throws, so one failed
     request can't blank the app the way an exception would */
  const ok = (data) => ({ data, error: null });
  const fail = (error) => {
    console.error("Jammy API:", error);
    return { data: null, error };
  };
  async function call(fn) {
    try {
      const { data, error } = await withTimeout(
        Promise.resolve().then(fn),
        CALL_TIMEOUT_MS
      );
      return error ? fail(error) : ok(data);
    } catch (e) {
      return fail(e);
    }
  }

  /* ---------------- AUTH ---------------- */
  const auth = {
    /* step 1: send the code */
    sendPhoneCode: (phone) => call(() => sb.auth.signInWithOtp({ phone })),
    sendEmailCode: (email) => call(() => sb.auth.signInWithOtp({ email })),

    /* step 2: verify it. this is where the session is created */
    verifyPhone: (phone, token) =>
      call(() => sb.auth.verifyOtp({ phone, token, type: "sms" })),
    verifyEmail: (email, token) =>
      call(() => sb.auth.verifyOtp({ email, token, type: "email" })),

    /* Apple sign-in is REQUIRED by App Store rules if you offer Google */
    appleOAuth: () => call(() => sb.auth.signInWithOAuth({ provider: "apple" })),
    googleOAuth: () => call(() => sb.auth.signInWithOAuth({ provider: "google" })),

    signOut: () => call(() => sb.auth.signOut()),
    session: () => call(() => sb.auth.getSession()),
    user: () => call(() => sb.auth.getUser()),
    onChange: (cb) => sb.auth.onAuthStateChange((_e, s) => cb(s)),
  };

  /* ---------------- PROFILE ---------------- */
  const profile = {
    /* call this once, right after the age gate and terms screen */
    async create(fields) {
      const me = await uid();
      if (!me) return fail(new Error("not signed in"));
      return call(() =>
        sb.from("profiles").insert({
          id: me,
          handle: fields.handle.replace(/^@/, "").toLowerCase(),
          display_name: fields.name,
          city: fields.city,
          instruments: fields.instruments || [],
          genres: fields.genres || [],
          looking_for: fields.lookingFor || null,
          looking_for_instruments: fields.needs || [],
          rehearsal_days: fields.days || [],
          birth_date: fields.birthDate, // "1991-04-02"
          terms_agreed_at: new Date().toISOString(),
          remote_ok: fields.remoteOk !== false,
        }).select().single()
      );
    },

    mine: () =>
      call(async () => {
        const me = await uid();
        return sb.from("profiles").select("*").eq("id", me).single();
      }),

    get: (id) => call(() => sb.from("profiles").select("*").eq("id", id).single()),

    update: (patch) =>
      call(async () => {
        const me = await uid();
        return sb.from("profiles").update(patch).eq("id", me).select().single();
      }),

    /* Snap the location to ~1km before it ever leaves the device.
       Storing exact coordinates for a stranger-meeting app is a
       safety problem, not a precision tradeoff. */
    async setLocation(lat, lng, label) {
      const r = (n) => Math.round(n * 100) / 100; // ~1.1km
      return call(async () => {
        const me = await uid();
        return sb.from("profiles").update({
          city: label || null,
          location: `SRID=4326;POINT(${r(lng)} ${r(lat)})`,
        }).eq("id", me);
      });
    },
  };

  /* ---------------- DISCOVERY ---------------- */
  const discover = {
    /* filters shape matches the app's S.filters exactly */
    find: (f) =>
      call(() =>
        sb.rpc("discover", {
          radius_miles: f.radius || 0,
          exclude_same: f.excludeSame !== false,
          needs: f.needs || [],
          min_shared_genres: f.minGenres || 0,
          include_remote: !!f.remoteOk,
          max_results: 50,
        })
      ),

    /* Records the swipe AND says whether it became a match, in one trip.
       Writing the row on its own tells the app nothing useful — the
       connection is created by a trigger, server-side, and the client has
       no honest way to know that happened. */
    swipe: (toId, direction) =>
      call(() => sb.rpc("swipe_and_check", { to_user: toId, dir: direction })),

    /* everyone you've matched with, with enough to draw the row */
    connections: () => call(() => sb.rpc("my_connections")),
  };

  /* ---------------- CHAT ---------------- */
  const chat = {
    /* The message list in one request: who it's with, their photo, the
       last thing said, and how many you haven't read. Done row by row
       this was forty queries to draw ten conversations. */
    list: () => call(() => sb.rpc("my_conversations")),

    /* find (or open) the conversation with someone you've matched with */
    dmWith: (userId) => call(() => sb.rpc("dm_with", { other: userId })),

    /* a band's group chat, creating it on first use */
    bandConversation: (bandId) =>
      call(() => sb.rpc("band_conversation", { band: bandId })),

    /* everyone in a conversation, so a band thread can label who spoke */
    people: (conversationId) =>
      call(() => sb.rpc("conversation_people", { convo: conversationId })),

    conversations: () =>
      call(() =>
        sb.from("conversation_members")
          .select("conversation_id, last_read_at, conversations(id, kind, band_id)")
      ),

    /* keyset pagination. pass the created_at of the oldest message you
       already have as `before`. Never use .range()/offset here — at 5,000
       messages an offset query walks every row it skips. */
    messages: (conversationId, before = null, pageSize = 40) =>
      call(() =>
        sb.rpc("messages_page", {
          convo: conversationId,
          before: before,
          page_size: pageSize,
        })
      ),

    send: (conversationId, body) =>
      call(async () => {
        const me = await uid();
        return sb.from("messages").insert({
          conversation_id: conversationId,
          sender_id: me,
          body,
        }).select().single();
      }),

    /* live updates. this is the moment the app stops being a demo */
    subscribe(conversationId, onMessage) {
      return sb
        .channel("convo:" + conversationId)
        .on(
          "postgres_changes",
          { event: "INSERT", schema: "public", table: "messages",
            filter: "conversation_id=eq." + conversationId },
          (payload) => onMessage(payload.new)
        )
        .subscribe();
    },
    unsubscribe: (channel) => sb.removeChannel(channel),

    markRead: (conversationId) =>
      call(async () => {
        const me = await uid();
        return sb.from("conversation_members")
          .update({ last_read_at: new Date().toISOString() })
          .eq("conversation_id", conversationId)
          .eq("user_id", me);
      }),
  };

  /* ---------------- JAM CLIPS ---------------- */
  const clips = {
    /* peaks are computed on the client at record time and stored on the row —
       decoding audio just to draw a waveform in a list is slow and drains battery */
    async send(conversationId, blob, { durationMs, peaks, label }) {
      const me = await uid();
      if (!me) return fail(new Error("not signed in"));
      const ext = (blob.type || "").includes("mp4") ? "m4a" : "webm";
      const id = crypto.randomUUID();
      const path = `clips/${conversationId}/${id}.${ext}`;

      const up = await call(() =>
        sb.storage.from("jam-clips").upload(path, blob, {
          contentType: blob.type || "audio/webm",
          cacheControl: "3600",
        })
      );
      if (up.error) return up;

      return call(() =>
        sb.from("messages").insert({
          conversation_id: conversationId,
          sender_id: me,
          clip_path: path,
          clip_mime: blob.type || "audio/webm",
          clip_duration_ms: Math.round(durationMs || 0),
          clip_peaks: peaks || [],
          clip_label: label || "Jam clip",
        }).select().single()
      );
    },

    /* short-lived signed URL. If the sender is later blocked or leaves,
       a fresh URL simply isn't issued — which is why we never hand out
       permanent public links. */
    url: (path, seconds = 3600) =>
      call(() => sb.storage.from("jam-clips").createSignedUrl(path, seconds)),
  };

  /* ---------------- BANDS ---------------- */
  const bands = {
    mine: () =>
      call(() =>
        sb.from("band_members")
          .select("band_id, role_label, instruments, bands(*)")
      ),

    create: (fields) =>
      call(async () => {
        const me = await uid();
        const { data: band, error } = await sb.from("bands").insert({
          name: fields.name,
          kind: fields.kind || "jammy",
          city: fields.city,
          genres: fields.genres || [],
          about: fields.about,
          created_by: me,
        }).select().single();
        if (error) return { data: null, error };
        await sb.from("band_members").insert({
          band_id: band.id,
          user_id: me,
          instruments: fields.myInstruments || [],
          role_label: fields.myRole,
          is_admin: true,
        });
        return { data: band, error: null };
      }),

    members: (bandId) =>
      call(() =>
        sb.from("band_members")
          .select("id, user_id, display_name, instruments, role_label, is_admin, profiles(display_name, handle, city, photo_path)")
          .eq("band_id", bandId)
      ),

    /* RLS decides what comes back here: members get everything,
       everyone else gets announced gigs only */
    events: (bandId) =>
      call(() =>
        sb.from("band_events")
          .select("*, event_tasks(task, done, user_id)")
          .eq("band_id", bandId)
          .gte("starts_at", new Date(Date.now() - 86400000).toISOString())
          .order("starts_at", { ascending: true })
      ),

    addEvent: (bandId, ev) =>
      call(async () => {
        const me = await uid();
        const { data: row, error } = await sb.from("band_events").insert({
          band_id: bandId,
          kind: ev.kind,
          starts_at: ev.startsAt,
          place: ev.place,
          address: ev.address || null,
          note: ev.note || null,
          private_function: !!ev.privateFunction,
          created_by: me,
        }).select().single();
        if (error) return { data: null, error };
        if (ev.myTask) {
          await sb.from("event_tasks").insert({
            event_id: row.id, user_id: me, task: ev.myTask,
          });
        }
        return { data: row, error: null };
      }),

    setEventVisibility: (eventId, visibility) =>
      call(() => sb.from("band_events").update({ visibility }).eq("id", eventId)),

    media: (bandId) =>
      call(() =>
        sb.from("band_media").select("*").eq("band_id", bandId)
          .order("created_at", { ascending: false })
      ),
  };

  /* ---------------- FEED ---------------- */
  const feed = {
    /* one query, counts already on the row, blocks filtered in the database.
       The old version pulled every like and comment row just to show a number. */
    posts: (before = null, pageSize = 20) =>
      call(() => sb.rpc("feed_page", { before: before, page_size: pageSize })),
    post: (body, tag, trackId) =>
      call(async () => {
        const me = await uid();
        return sb.from("posts").insert({
          author_id: me, body, tag: tag || null, track_id: trackId || null,
        }).select().single();
      }),
    like: (postId, on) =>
      call(async () => {
        const me = await uid();
        return on
          ? sb.from("post_likes").upsert({ post_id: postId, user_id: me })
          : sb.from("post_likes").delete().eq("post_id", postId).eq("user_id", me);
      }),
    /* comments, paged by cursor like everything else */
    comments: (postId, before = null, pageSize = 30) =>
      call(() => sb.rpc("comments_page", {
        post: postId, before: before, page_size: pageSize,
      })),

    comment: (postId, body) =>
      call(async () => {
        const me = await uid();
        return sb.from("post_comments").insert({
          post_id: postId, author_id: me, body,
        }).select("id, body, created_at, author_id").single();
      }),

    deleteComment: (id) =>
      call(() => sb.from("post_comments").delete().eq("id", id)),

    /* live comments while the sheet is open, so two people reading the same
       post see each other type */
    subscribeComments(postId, onComment) {
      return sb.channel("post:" + postId)
        .on("postgres_changes",
          { event: "INSERT", schema: "public", table: "post_comments",
            filter: "post_id=eq." + postId },
          (payload) => onComment(payload.new))
        .subscribe();
    },
    unsubscribe: (channel) => sb.removeChannel(channel),

    /* who liked a post — used for the "x and 3 others" line */
    likers: (postId, limit = 12) =>
      call(() => sb.from("post_likes")
        .select("user_id, profiles(display_name, handle, photo_path)")
        .eq("post_id", postId).limit(limit)),
  };

  /* ---------------- RADIO ---------------- */
  const radio = {
    chart: () =>
      call(() =>
        sb.from("weekly_chart_v")
          .select("*, tracks(title, key, bpm, audio_path, profiles(display_name, handle))")
          .order("score", { ascending: false })
          .limit(10)
      ),
    /* only count a play at 30 seconds or more, or the chart is trivially gamed */
    logPlay: (trackId, seconds, source) =>
      seconds < 30
        ? Promise.resolve(ok(null))
        : call(async () => {
            const me = await uid();
            return sb.from("plays").insert({
              track_id: trackId,
              user_id: me || null,
              seconds: Math.round(seconds),
              source: source || "radio",
            });
          }),
  };

  /* ---------------- SAFETY ---------------- */
  const safety = {
    block: (id) =>
      call(async () => {
        const me = await uid();
        return sb.from("blocks").upsert({ blocker_id: me, blocked_id: id });
      }),
    unblock: (id) =>
      call(async () => {
        const me = await uid();
        return sb.from("blocks").delete().eq("blocker_id", me).eq("blocked_id", id);
      }),
    blocked: () =>
      call(() => sb.from("blocks").select("blocked_id, created_at, profiles!blocks_blocked_id_fkey(display_name, handle)")),
    report: ({ userId, postId, messageId, reason, note }) =>
      call(async () => {
        const me = await uid();
        return sb.from("reports").insert({
          reporter_id: me,
          target_user: userId || null,
          target_post: postId || null,
          target_message: messageId || null,
          reason, note: note || null,
        });
      }),
    registerDevice: (token, platform) =>
      call(async () => {
        const me = await uid();
        return sb.from("device_tokens").upsert({
          user_id: me, token, platform,
          updated_at: new Date().toISOString(),
        });
      }),
  };

  window.JammyAPI = { sb, auth, profile, discover, chat, clips, bands, feed, radio, safety };
})();
