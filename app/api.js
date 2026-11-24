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
  /* Every column an ordinary member is allowed to read. select("*") used
     to be fine because the database handed out whole tables; since
     23_columns.sql it does not, and "*" is refused outright.

     `birth_date` and `location` are deliberately missing. Nobody reads
     those two through the table — not even about themselves. Your own
     date of birth comes back through export_my_data(), and has_location
     answers the only question the app ever asks about the coordinate:
     does the server have one yet. */
  /* A media type with its parameters stripped off.

     MediaRecorder hands back a blob whose type is "audio/webm;codecs=opus",
     and Supabase matches a bucket's allowed types as exact strings, so that
     does not match "audio/webm" and the upload is refused. Every recorded
     message failed this way, silently, and the first person to try to send
     one found it. A file picked from the phone usually has a clean type,
     which is why the file-upload paths appeared to work. */
  const baseType = (t) => String(t || "").split(";")[0].trim().toLowerCase();

  const PROFILE_COLUMNS = [
    "id", "handle", "display_name", "bio", "city", "photo_path",
    "instruments", "instrument_keys", "genres",
    "looking_for", "looking_for_instruments", "influences",
    "rehearsal_days", "remote_ok",
    "verified_at", "is_banned", "terms_agreed_at", "created_at",
    "has_location"
  ].join(",");

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
          /* birth_date may be WRITTEN once, here, at signup. It can
             never be read back or changed — see 23_columns.sql. */
        }).select(PROFILE_COLUMNS).single()
      );
    },

    mine: () =>
      call(async () => {
        const me = await uid();
        return sb.from("profiles").select(PROFILE_COLUMNS).eq("id", me).single();
      }),

    get: (id) =>
      call(() => sb.from("profiles").select(PROFILE_COLUMNS).eq("id", id).single()),

    update: (patch) =>
      call(async () => {
        const me = await uid();
        return sb.from("profiles").update(patch).eq("id", me)
                 .select(PROFILE_COLUMNS).single();
      }),

    /* Snap the location to ~1km before it ever leaves the device.
       Storing exact coordinates for a stranger-meeting app is a
       safety problem, not a precision tradeoff. */
    /* The city is the person's own words about where they play. Automatic
       location detection never touches it — it writes coordinates only.
       It used to write a guessed place name every launch, which meant a
       stale value on one device would overwrite a correction made
       anywhere else, on every single page load. Only a deliberate choice
       (the location picker, or editing the profile) passes writeCity. */
    async setLocation(lat, lng, label, writeCity) {
      const r = (n) => Math.round(n * 100) / 100; // ~1.1km
      return call(async () => {
        const me = await uid();
        const patch = { location: `SRID=4326;POINT(${r(lng)} ${r(lat)})` };
        const clean = (label || "").trim();
        if (writeCity && clean && clean.toLowerCase() !== "your area") patch.city = clean;
        return sb.from("profiles").update(patch).eq("id", me);
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

    /* People who have asked to play with you and are still waiting.
       Needs the server because you can only see your own swipes — which
       is precisely why nobody could tell they had been asked. */
    requests: () => call(() => sb.rpc("incoming_requests")),
    requestCount: () => call(() => sb.rpc("incoming_request_count")),
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
      const ext = baseType(blob.type).includes("mp4") ? "m4a" : "webm";
      const id = crypto.randomUUID();
      const path = `clips/${conversationId}/${id}.${ext}`;

      const up = await call(() =>
        sb.storage.from("jam-clips").upload(path, blob, {
          contentType: baseType(blob.type) || "audio/webm",
          cacheControl: "3600",
        })
      );
      if (up.error) return up;

      return call(() =>
        sb.from("messages").insert({
          conversation_id: conversationId,
          sender_id: me,
          clip_path: path,
          clip_mime: baseType(blob.type) || "audio/webm",
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
    /* Each of these answers a whole screen in one request. The older
       versions below fetched a band, then its roster, then its diary,
       then a profile per member — about a dozen round trips to draw one
       page, every time it opened. */
    mine: () => call(() => sb.rpc("my_bands")),
    roster: (bandId) => call(() => sb.rpc("band_roster", { b: bandId })),
    schedule: (bandId) => call(() => sb.rpc("band_schedule", { b: bandId })),

    /* Creating a band, joining it and opening its group chat are one act.
       Split across three calls, any one can fail and leave a band with
       nobody in it. */
    create: (f) =>
      call(() => sb.rpc("create_band", {
        p_name: f.name,
        p_city: f.city || null,
        p_genres: f.genres || [],
        p_about: f.about || null,
        p_my_instruments: f.myInstruments || [],
        p_my_role: f.myRole || null,
      })),

    join: (bandId, instruments, role) =>
      call(() => sb.rpc("join_band", {
        b: bandId, p_instruments: instruments || [], p_role: role || null,
      })),

    leave: (bandId) => call(() => sb.rpc("leave_band", { b: bandId })),

    addEvent: (bandId, ev) =>
      call(() => sb.rpc("add_band_event", {
        b: bandId,
        p_kind: ev.kind,
        p_starts_at: ev.startsAt,
        p_place: ev.place || null,
        p_address: ev.address || null,
        p_note: ev.note || null,
        p_ends_at: ev.endsAt || null,
        p_visibility: ev.visibility || null,
      })),

    cancelEvent: (eventId) => call(() => sb.rpc("cancel_band_event", { e: eventId })),

    /* everything coming up across all your bands — what reminders read */
    schedule_mine: (days) => call(() => sb.rpc("my_schedule", { days: days || 30 })),

    /* for people who only want to listen */
    gigsNearMe: (miles, days) =>
      call(() => sb.rpc("gigs_near_me", { radius_miles: miles ?? 25, days: days || 30 })),

    /* The public half of a band, for anyone who is not in it: the
       name, the city, how many play in it, the next public gig, and
       where the person asking stands with it. */
    page: (bandId) => call(() => sb.rpc("band_page", { b: bandId })),

    /* Joining is asking. A member can read the rehearsal address,
       which is usually somebody's home. */
    askToJoin: (bandId, instruments, role, note) =>
      call(() =>
        sb.rpc("ask_to_join_band", {
          b: bandId,
          p_instruments: instruments || [],
          p_role: role || null,
          p_note: note || null,
        })),

    /* Taking somebody off the roster. Admin only, and it refuses to
       strand a band without an admin or to empty it. */
    removeMember: (bandId, userId) =>
      call(() => sb.rpc("remove_band_member", { b: bandId, who: userId })),

    /* everyone waiting on an answer from a band you run */
    requests: (bandId) => call(() => sb.rpc("band_requests", { b: bandId || null })),
    requestCount: () => call(() => sb.rpc("band_request_count")),
    answerRequest: (requestId, yes) =>
      call(() => sb.rpc("answer_band_request", { req: requestId, yes: !!yes })),

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
    /* The cursor is the last row's time AND its id. Time alone looked
       enough until two posts landed in the same second, and then the next
       page quietly skipped every post that shared the boundary — which is
       most likely exactly when the feed is busy. */
    posts: (before = null, pageSize = 20, beforeId = null) =>
      call(() => sb.rpc("feed_page", {
        before: before, page_size: pageSize, before_id: beforeId,
      })),
    post: (body, tag, trackId, mediaPath) =>
      call(async () => {
        const me = await uid();
        return sb.from("posts").insert({
          author_id: me, body, tag: tag || null, track_id: trackId || null,
          media_path: mediaPath || null,
        }).select().single();
      }),

    /* A picture or a video on a post.

       Every file goes to <your user id>/… because the storage rule checks
       that the first folder is your own id — that is what stops one person
       writing over another's. The bucket is public to read, like every
       social app, so the URL can go straight in an <img> or <video>. */
    async upload(blob, kind) {
      const me = await uid();
      if (!me) return fail(new Error("not signed in"));
      const type = baseType(blob.type) || (kind === "video" ? "video/mp4" : "image/jpeg");
      const ext = ({
        "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp",
        "image/gif": "gif", "video/mp4": "mp4", "video/webm": "webm",
        "video/quicktime": "mov",
      })[type] || (kind === "video" ? "mp4" : "jpg");

      if (blob.size > 25 * 1024 * 1024)
        return fail(new Error("That file is bigger than 25MB, which is the limit."));

      const path = `${me}/posts/${crypto.randomUUID()}.${ext}`;
      const up = await call(() =>
        sb.storage.from("jammy-media").upload(path, blob, {
          contentType: type, cacheControl: "3600",
        })
      );
      if (up.error) return up;
      return { data: path, error: null };
    },

    /* The bucket is public, so this needs no round trip and never expires. */
    mediaUrl: (path) =>
      path ? sb.storage.from("jammy-media").getPublicUrl(path).data.publicUrl : null,

    remove: (postId) =>
      call(() => sb.from("posts").delete().eq("id", postId)),
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

  /* ---------------- YOUR ACCOUNT ---------------- */
  const account = {
    /* Everything Jammy holds about you, as one JSON document — the
       "Download my data" the privacy policy promises. Neither of these
       takes a user id, on purpose: a function that did would be one
       mistake away from handing out somebody else's life. */
    export: () => call(() => sb.rpc("export_my_data")),

    /* Permanent, and it needs the word "delete". Apple rejects apps that
       let you create an account and not remove it. */
    remove: (confirm) => call(() => sb.rpc("delete_my_account", { confirm })),
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
    /* Putting a recording on your profile.

       The sheet that asks for this used to read the title, the key and the
       tempo and throw the audio file away, then say "Published — you're in
       the rotation". The file goes to storage now and the row points at it,
       so pressing play opens the actual recording. */
    async upload(blob, { title, key, bpm, durationMs } = {}) {
      const me = await uid();
      if (!me) return fail(new Error("not signed in"));
      if (!blob || !blob.size) return fail(new Error("Pick an audio file first."));
      if (blob.size > 40 * 1024 * 1024)
        return fail(new Error("That file is bigger than 40MB. Try a shorter clip or a smaller export."));

      const type = baseType(blob.type) || "audio/mpeg";
      const ext = ({ "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/x-m4a": "m4a",
                     "audio/wav": "wav", "audio/x-wav": "wav", "audio/ogg": "ogg",
                     "audio/webm": "webm", "audio/flac": "flac" })[type]
                || (blob.name && blob.name.split(".").pop()) || "mp3";

      const path = `${me}/tracks/${crypto.randomUUID()}.${ext}`;
      const up = await call(() =>
        sb.storage.from("jammy-media").upload(path, blob, { contentType: type, cacheControl: "3600" })
      );
      if (up.error) return up;

      return call(() =>
        sb.from("tracks").insert({
          owner_id: me,
          title: (title || "Untitled").slice(0, 120),
          audio_path: path,
          key: key || null,
          bpm: bpm || null,
          duration_ms: durationMs || null,
        }).select().single()
      );
    },

    /* The bucket is public to read, so this needs no round trip. */
    url: (path) =>
      path ? sb.storage.from("jammy-media").getPublicUrl(path).data.publicUrl : null,

    mine: () => call(async () => {
      const me = await uid();
      return sb.rpc("tracks_by", { who: me });
    }),

    /* Taking a recording down: off your profile, off the radio, and the
       file itself out of storage.

       The row goes first and the file second, deliberately. If the file
       went first and the row failed, you would be left with a track that
       plays nothing. This way round the worst case is a file nobody can
       reach any more, which costs a little space and breaks nothing —
       and the chart entry goes either way, because play_daily cascades
       from tracks. */
    async removeTrack(id) {
      const me = await uid();
      if (!me) return fail(new Error("not signed in"));

      const found = await call(() =>
        sb.from("tracks").select("audio_path, owner_id").eq("id", id).single()
      );
      if (found.error) return found;
      if (found.data && found.data.owner_id !== me)
        return fail(new Error("that recording isn't yours"));

      const gone = await call(() => sb.from("tracks").delete().eq("id", id));
      if (gone.error) return gone;

      const path = found.data && found.data.audio_path;
      if (path) {
        /* Best effort. The recording is already off Jammy at this point,
           so a failure here is not worth telling anybody about. */
        try { await sb.storage.from("jammy-media").remove([path]); } catch (e) {}
      }
      return { data: true, error: null };
    },

    /* Fifteen seconds counts as a play. The real rule is the roll_up_play
       trigger in the database — this only avoids a round trip that the
       server would throw away, so the two numbers must agree. A play
       counts once per person per track per day however often it is
       played, which is what stops the chart being climbed by tapping. */
    logPlay: (trackId, seconds, source) =>
      seconds < 15
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
    /* Ending a connection without blocking anybody. Blocking is for
       someone who frightens you; this is for someone you played with
       once and it didn't work. The server clears the connection and
       both swipes, so each goes back into the other's Discover. */
    disconnect: (id) => call(() => sb.rpc("disconnect_from", { who: id })),

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

  window.JammyAPI = { sb, auth, profile, discover, chat, clips, bands, feed, radio, safety, account };
})();
