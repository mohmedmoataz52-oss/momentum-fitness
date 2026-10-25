
// Existing navigation remains available while the verified profile loads.
window.openPage = page => { window.location.href = page; };
(async function initializeAthlete() {
  const fields=['headerEmail','profileName','profileAge','profileWeight','profileHeight','athleteIdDisplay'];
  fields.forEach(id=>document.getElementById(id).textContent='--');
  document.getElementById('athleteIdDisplay').style.overflowWrap='anywhere';
  document.getElementById('athleteIdDisplay').style.minWidth='0';
  document.getElementById('headerName').textContent='Loading your profile...';
  document.getElementById('copyAthleteId').disabled=true;
  document.getElementById('updateWeight').disabled=true;
  try {
    if (!window.supabase) throw new Error('Could not load Supabase. Check your connection and reload.');
    const sb=window.supabase.createClient(
      'https://xcgbxurbnsytecrdupct.supabase.co',
      'sb_publishable_PAd7gf0Q-N9H4PqgqqaVNg_EfE583xO');
    window.momentumClient=sb;
    const {data:auth,error:authError}=await sb.auth.getUser();
    if(authError || !auth.user) {
      if(authError && !['AuthSessionMissingError','AuthApiError'].includes(authError.name)) throw authError;
      localStorage.setItem('isLoggedIn','false');
      window.location.replace('test.html?role=athlete');
      return;
    }
    const user=auth.user;
    const {data:profile,error}=await sb.from('profiles')
      .select('id,full_name,role,age,weight,height,whatsapp').eq('id',user.id).single();
    if(error) throw error;
    if(profile.role==='trainer') {window.location.replace('test4.html'); return;}
    if(profile.role!=='athlete') throw new Error('This profile does not have an athlete role.');
    const previousUser=localStorage.getItem('userID');
    // Prevent another account's old local trainer card from appearing here.
    if(previousUser!==user.id || localStorage.getItem('momentumTrainerCacheOwner')!==user.id) {
      localStorage.removeItem('myTrainer');
    }
    localStorage.setItem('momentumTrainerCacheOwner',user.id);
    const userName=profile.full_name || 'User';
    const userEmail=user.email || '';
    const userAge=profile.age ?? '--';
    // The verified backend profile is authoritative; ignore earlier browser-only weights.
    const userWeight=profile.weight ?? '--';
    localStorage.removeItem('momentumWeight_'+user.id);
    const userHeight=profile.height ?? '--';
    const cache={userID:user.id,athleteId:user.id,userName,userEmail,userAge,userWeight,userHeight,
      userRole:profile.role,userPhone:profile.whatsapp ?? '',isLoggedIn:'true'};
    Object.entries(cache).forEach(([key,value])=>localStorage.setItem(key,String(value)));
    localStorage.removeItem('userPassword');
        /* =========================================
           ATHLETE ID
        ========================================= */

        const athleteId =
            user.id;


        document.getElementById(
            "athleteIdDisplay"
        ).textContent = athleteId;


        /* =========================================
           COPY ATHLETE ID
        ========================================= */

        const copyAthleteId =
            document.getElementById(
                "copyAthleteId"
            );


        copyAthleteId.addEventListener(
            "click",
            async function () {

                try {

                    await navigator.clipboard.writeText(
                        athleteId
                    );


                    copyAthleteId.innerHTML =
                        '<i class="fa-solid fa-check"></i>';


                    copyAthleteId.classList.add(
                        "copied"
                    );


                    setTimeout(function () {

                        copyAthleteId.innerHTML =
                            '<i class="fa-regular fa-copy"></i>';

                        copyAthleteId.classList.remove(
                            "copied"
                        );

                    }, 1500);

                }

                catch (error) {

                    console.error(
                        "Could not copy Athlete ID:",
                        error
                    );

                }

            }
        );


        /* =========================================
           SHOW USER DATA
        ========================================= */

        document.getElementById("headerName").textContent =
            "Hello, " + userName;

        document.getElementById("headerEmail").textContent =
            userEmail;

        document.getElementById("profileName").textContent =
            userName;

        document.getElementById("profileAge").textContent =
            userAge;

        document.getElementById("profileWeight").textContent =
            userWeight;

        document.getElementById("profileHeight").textContent =
            userHeight;


        /* =========================================
           UPDATE WEIGHT
        ========================================= */

        const newWeight=document.getElementById('newWeight'),updateWeight=document.getElementById('updateWeight'),weightMessage=document.getElementById('weightMessage');
        let weightSaving=false;
        function weightNotice(text,ok=false){weightMessage.textContent=text;weightMessage.style.color=ok?'#24e3a3':'#ff6b6b';}
        async function verifyWeightAccount(){const {data,error}=await sb.auth.getUser();if(error||data.user?.id!==user.id)throw new Error('Account changed. Reload and sign in to the correct athlete account.');}
        async function weightRPC(args){const {data,error}=await sb.rpc('momentum_tracking',args);if(error)throw error;if(!data||data.athlete_id!==user.id)throw new Error('Could not verify your daily record. Reload this page.');return data;}
        function showSavedWeight(weight){document.getElementById('profileWeight').textContent=weight;localStorage.setItem('userWeight',String(weight));localStorage.removeItem('momentumWeight_'+user.id);}
        updateWeight.addEventListener('click',async()=>{
          if(weightSaving)return;const text=newWeight.value.trim(),value=Number(text);
          if(!text||!Number.isFinite(value)||value<20||value>300){weightNotice('Please enter a weight between 20 and 300 kg.');return;}
          weightSaving=true;updateWeight.disabled=true;newWeight.disabled=true;weightNotice('Saving your weight...',true);
          try{
            await verifyWeightAccount();
            // Load the latest server state, retaining the chosen day, meals, water and exercises.
            const latest=await weightRPC({action:'load'});
            const state={...latest.state,body_weight:value};
            const saved=await weightRPC({action:'save',log_date:latest.date,expected_revision:latest.revision,payload:{day:latest.day_index,plan_revision:latest.snapshot.plan_revision,state}});
            await verifyWeightAccount();
            showSavedWeight(saved.state.body_weight);newWeight.value='';weightNotice('Weight saved to Supabase for '+saved.date+'. Your coach can see it in Progress.',true);
            await syncHomeWorkoutProgress();
          }catch(error){weightNotice((error.message||'Could not save weight.')+' Your input has been kept.');}
          finally{weightSaving=false;updateWeight.disabled=false;newWeight.disabled=false;}
        });
        async function refreshHomeWeight(){if(weightSaving)return;try{await verifyWeightAccount();const {data,error}=await sb.from('profiles').select('id,weight').eq('id',user.id).single();if(error)throw error;if(data.id!==user.id)throw new Error('Account changed. Reload.');if(data.weight!==null)showSavedWeight(data.weight);}catch(error){weightNotice(error.message);}}
        window.addEventListener('focus',refreshHomeWeight);


        /* =========================================
           FIND TRAINER
        ========================================= */

        document.getElementById(
            "findTrainerBtn"
        ).addEventListener(
            "click",
            function () {

                window.location.href =
                    "trainer-search.html";

            }
        );


        /* =========================================
           LOAD MY TRAINER
        ========================================= */

        async function loadMyTrainer() {
          const empty=document.getElementById('trainerEmpty'),card=document.getElementById('trainerCard'),status=document.getElementById('trainerStatus');
          card.style.display='none';empty.style.display='none';status.textContent='LOADING';
          const oldLink=document.getElementById('trainerWhatsapp');if(oldLink)oldLink.remove();
          try {
            const {data:trainer,error}=await sb.rpc('momentum_coaching',{action:'connection',target:null,decision:null});
            if(error)throw error;
            if(!trainer){empty.style.display='flex';status.textContent='NOT CONNECTED';localStorage.removeItem('myTrainer');return;}
            document.getElementById('trainerName').textContent=trainer.name||'Trainer';
            document.getElementById('trainerId').textContent=trainer.id;
            document.getElementById('trainerId').style.overflowWrap='anywhere';
            document.getElementById('trainerPhoto').dataset.momentumAvatar=trainer.id;
            document.getElementById('trainerPhoto').src='https://ui-avatars.com/api/?name='+encodeURIComponent(trainer.name||'Trainer')+'&background=0a1822&color=24e3a3&size=160';
            const phone=String(trainer.whatsapp||'').replace(/[^0-9]/g,'');
            // Use an international number. Convert the common Egyptian local format.
            const international=/^01[0125][0-9]{8}$/.test(phone)?'20'+phone.slice(1):phone.replace(/^00/,'');
            if(/^[1-9][0-9]{7,14}$/.test(international)){
              const link=document.createElement('a');link.id='trainerWhatsapp';link.href='https://wa.me/'+international;
              link.target='_blank';link.rel='noopener noreferrer';link.title='Contact your trainer on WhatsApp';link.setAttribute('aria-label',link.title);
              link.style.cssText='color:#24e3a3;font-size:28px;margin:0 12px';link.innerHTML='<i class="fa-brands fa-whatsapp"></i>';card.appendChild(link);
            }
            localStorage.setItem('myTrainer',JSON.stringify(trainer));
            card.style.display='flex';status.textContent='CONNECTED';
          }catch(error){status.textContent='COULD NOT LOAD TRAINER';status.title=error.message;}
        }

        /* =========================================
           PAGE NAVIGATION
        ========================================= */

        function openPage(page) {

            window.location.href =
                page;

        }


        /* =========================================
           INITIALIZE
        ========================================= */

        document.getElementById('copyAthleteId').disabled=false;
        document.getElementById('updateWeight').disabled=false;
        const trainerReady=loadMyTrainer();
        window.addEventListener("focus", loadMyTrainer);
        window.openPage = openPage;

    
        /* =========================================
           LIVE WORKOUT PROGRESS FROM EXERCISES
        ========================================= */
        async function syncHomeWorkoutProgress() {
          const circle=document.getElementById('homeProgressCircle');
          const bar=document.getElementById('homeProgressBar');
          const count=document.getElementById('homeProgressCount');
          try {
            const {data,error}=await sb.rpc('momentum_tracking',{action:'read',log_date:null,payload:null,expected_revision:null,target:null,date_from:null,date_to:null});
            if(error)throw error;
            if(data&&data.athlete_id!==user.id)throw new Error('Account changed. Reload the page.');
            const metrics=data?.metrics;
            const percent=metrics?.workout_percent??0;
            if(circle){circle.style.background=`conic-gradient(#24e3a3 ${percent}%, #243542 ${percent}%)`;circle.dataset.value=percent+'%';circle.textContent='';circle.style.display='grid';circle.style.placeItems='center';circle.style.fontWeight='800';circle.style.color='#f4f8fb';circle.title='Today’s exercise logs from Supabase';}
            if(bar)bar.style.width=percent+'%';
            if(count)count.textContent=metrics?.prescribed_rest?'Rest assigned':metrics?.rest_override?'Workout skipped':`${metrics?.exercises_done??0}/${metrics?.exercises_total??0}`;
          }catch(error){if(circle){circle.dataset.value='—';circle.textContent='';circle.title=error.message;}if(bar)bar.style.width='0%';if(count)count.textContent='—';}
        }
        await Promise.allSettled([trainerReady,syncHomeWorkoutProgress()]);
        window.addEventListener('focus',syncHomeWorkoutProgress);


    document.getElementById('copyAthleteId').disabled=false;
    document.getElementById('updateWeight').disabled=false;
  } catch(error) {
    document.getElementById('headerName').textContent='Could not load your profile';
    document.getElementById('headerEmail').textContent=error.message || 'Please reload and try again.';
    localStorage.setItem('isLoggedIn','false');
  }
})();
