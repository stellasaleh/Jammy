/* Tests api.js directly, with a fake Supabase underneath.
   The thing being proved: a request that never answers must not leave
   the app waiting forever. That is what froze sign-up. */
const fs=require("fs");
let pass=0,fail=0;
const ok=(c,m)=>{c?(pass++,console.log("  ✓ "+m)):(fail++,console.log("  ✗ "+m))};

function load(opts){
  const never=new Promise(()=>{});                 // answers never
  const calls=[];
  const q={
    insert(v){calls.push(["insert",v]);return this},
    update(v){calls.push(["update",v]);return this},
    select(){return this}, eq(){return this},
    single(){ return opts.hang?never:Promise.resolve({data:{id:"u1"},error:null}) },
    then(res,rej){ return (opts.hang?never:Promise.resolve({data:null,error:null})).then(res,rej) }
  };
  let getUserCalls=0;
  const sb={
    from(){return q},
    rpc(){return opts.hang?never:Promise.resolve({data:[],error:null})},
    auth:{
      getSession:async()=>({data:{session:{user:{id:"u1"}}}}),
      getUser:async()=>{getUserCalls++;return {data:{user:{id:"u1"}}}},
      onAuthStateChange(){return {data:{subscription:{unsubscribe(){}}}}},
      signInWithOtp:async()=>({data:{},error:null}),
      verifyOtp:async()=>({data:{},error:null}),
      signOut:async()=>({error:null}),
    },
    channel(){return {on(){return this},subscribe(){return this}}},
    removeChannel(){},
  };
  const g={ JAMMY_LIVE:true,
            JAMMY_CONFIG:{url:"https://x.supabase.co",anonKey:"sb_publishable_x",timeoutMs:opts.timeoutMs||150},
            supabase:{createClient:()=>sb} };
  const src=fs.readFileSync("/mnt/user-data/outputs/jammy/www/api.js","utf8");
  new Function("window",src)(g);
  return {api:g.JammyAPI,calls,getUserCount:()=>getUserCalls};
}

(async()=>{
  console.log("\n1. A HUNG request gives up instead of waiting forever");
  {
    const {api}=load({hang:true,timeoutMs:150});
    const started=Date.now();
    const r=await api.profile.create({handle:"stella",name:"Stella",city:"Boston",
      instruments:["Trumpet"],genres:["Jazz"],birthDate:"2004-03-01"});
    const took=Date.now()-started;
    ok(r && r.error, "comes back with an error rather than never coming back");
    ok(took<1000, `gives up quickly (${took}ms)`);
    ok(/didn't answer in time/i.test(r.error.message), "says the server didn't answer");
  }

  console.log("\n2. WRITES no longer make a network call just to learn who you are");
  {
    const {api,getUserCount}=load({});
    await api.profile.create({handle:"stella",name:"Stella",city:"Boston",
      instruments:["Trumpet"],genres:["Jazz"],birthDate:"2004-03-01"});
    await api.profile.update({bio:"hi"});
    ok(getUserCount()===0,"getUser() — the call that could deadlock — is never used on a write");
  }

  console.log("\n3. THE PROFILE it writes matches what the database requires");
  {
    const {api,calls}=load({});
    await api.profile.create({handle:"@Stella",name:"Stella Saleh",city:"Boston",
      instruments:["Trumpet"],genres:["Jazz"],lookingFor:"Form a band",
      birthDate:"2004-03-01",days:["Wed"]});
    const row=calls.find(c=>c[0]==="insert")[1];
    ok(row.id==="u1","uses your own account id, which row-level security requires");
    ok(row.handle==="stella","strips the @ and lowercases the handle");
    ok(row.display_name==="Stella Saleh","sends a display name");
    ok(row.birth_date==="2004-03-01","sends the date of birth the table insists on");
    ok(Array.isArray(row.instruments)&&row.instruments.length===1,"sends instruments as a list");
    ok(typeof row.terms_agreed_at==="string","records when the terms were agreed");
  }


  console.log("\n4. AUTOMATIC location never renames your city");
  {
    const {api,calls}=load({});
    await api.profile.setLocation(42.36,-71.06,"Ulanbataar");          // a launch-time guess
    const auto=calls.filter(c=>c[0]==="update").pop()[1];
    ok(auto.city===undefined,"a detected location writes coordinates only");
    ok(typeof auto.location==="string","and still writes the coordinates");

    await api.profile.setLocation(42.36,-71.06,"Boston",true);          // the person chose it
    const manual=calls.filter(c=>c[0]==="update").pop()[1];
    ok(manual.city==="Boston","a location the person picked may set the city");

    await api.profile.setLocation(42.36,-71.06,"your area",true);
    const vague=calls.filter(c=>c[0]==="update").pop()[1];
    ok(vague.city===undefined,'"your area" is never written as a city');
  }

  console.log("\n5. COORDINATES are blunted before they leave the device");
  {
    const {api,calls}=load({});
    await api.profile.setLocation(42.360812345,-71.058912345,"Boston");
    const row=calls.filter(c=>c[0]==="update").pop()[1];
    ok(/POINT\(-71\.06 42\.36\)/.test(row.location),
       "rounded to about a kilometre, so no one's exact address is stored");
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail?1:0);
})();
