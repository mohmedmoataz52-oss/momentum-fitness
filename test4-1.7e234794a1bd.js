
const sb=window.supabase?.createClient('https://xcgbxurbnsytecrdupct.supabase.co','sb_publishable_PAd7gf0Q-N9H4PqgqqaVNg_EfE583xO');
async function requireProfile(role) {
 if(!sb) throw new Error('Supabase could not load. Check your connection and reload.');
 const {data,error}=await sb.auth.getUser();
 if(error || !data.user) {window.location.replace('test.html?role='+role);throw new Error('Please sign in again.');}
 const result=await sb.from('profiles').select('id,full_name,role,age,weight,height,whatsapp').eq('id',data.user.id).single();
 if(result.error) throw result.error;
 if(result.data.role!==role) {window.location.replace(result.data.role==='trainer'?'test4.html':'test3.html');throw new Error('Wrong account type.');}
 return result.data;
}
async function coaching(action,target=null,decision=null) {
 const {data,error}=await sb.rpc('momentum_coaching',{action,target,decision});
 if(error) throw new Error(error.message+' (Check that momentum_connections.sql ran successfully.)');
 return data;
}
const escapeHTML=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

const $=id=>document.getElementById(id);
let athletes=[],pending=[],busy=false,coachOwner=null,refreshVersion=0;let dashboard=null;
function resetStats(){
 $('activePlansStat').textContent='—';$('avgCircle').dataset.value='—';$('avgCircle').style.setProperty('--value','0%');$('avgComplianceText').textContent='No recorded activity loaded';
 document.querySelectorAll('.today-circle').forEach(c=>{c.dataset.value='—';c.style.setProperty('--value','0%');c.title='No recorded data';});
 const note=document.getElementById('activityCoverage');if(note)note.textContent='No activity loaded.';
}
function renderStats(){
 if(!dashboard)return;const d=dashboard;
 $('activePlansStat').textContent=d.active_plans;$('avgCircle').dataset.value=d.average===null?'—':d.average+'%';$('avgCircle').style.setProperty('--value',(d.average??0)+'%');
 $('avgComplianceText').textContent=d.logged_days+' / '+d.eligible_days+' athlete-days recorded this month';
 let note=$('activityCoverage');if(!note){note=document.createElement('p');note.id='activityCoverage';note.className='footer-note';document.querySelector('.today-grid').after(note);}
 note.textContent=d.today.recorded_athletes+' athletes with a record today · '+d.month_start+' → '+d.date+' · Cairo dates. Averages use recorded days only; no-record days are unknown. Unassigned categories are excluded.';
 const keys=['workout','diet','water','overall'];document.querySelectorAll('.today-circle').forEach((c,i)=>{const value=d.today[keys[i]];c.dataset.value=value===null?'—':value+'%';c.style.setProperty('--value',(value??0)+'%');c.title=value===null?'No recorded data for this category':'Average of today’s recorded, assigned '+keys[i]+' entries';});
}
function clearDashboard(){dashboard=null;athletes=[];pending=[];resetStats();updateAthletes();renderRequests();for(const id of ['coachName','topCoachName','sidebarCoachName','coachAge','coachId'])$(id).textContent='—';}

const list=$('athletesList');list.innerHTML='';
const search=document.createElement('input');search.type='search';search.placeholder='Search athlete name or ID...';
search.setAttribute('aria-label','Search athlete by name or ID');
search.style.cssText='width:100%;padding:11px 14px;background:rgba(3,12,10,.55);border:1px solid rgba(57,217,138,.22);border-radius:10px;color:#f5faf8;outline:none;margin:12px 0 0;font-size:12px';
list.parentElement.insertBefore(search,list);
const status=document.createElement('p');status.setAttribute('role','status');status.style.cssText='color:#39d98a;overflow-wrap:anywhere';
list.parentElement.insertBefore(status,list);status.textContent='Loading your account...';
const requests=document.createElement('div');requests.className='panel';requests.id='connectionRequests';
list.parentElement.insertBefore(requests,list);
for(const id of ['coachName','topCoachName','sidebarCoachName','coachAge','coachId'])$(id).textContent='--';
for(const id of ['totalAthletes','totalAthletesStat'])$(id).textContent='0';
$('activePlansStat').textContent='—';$('avgComplianceText').textContent='Awaiting exercise and meal logs';
resetStats();
const badge=document.querySelector('.notification-badge');badge.textContent='0';
$('todayDate').innerHTML='<i class="fa-regular fa-calendar"></i> '+new Date().toLocaleDateString('en-GB',{timeZone:'Africa/Cairo',month:'short',day:'numeric',year:'numeric'});
function updateAthletes(){
 const term=search.value.trim().toLowerCase(),sort=$('sortAthletes').value;
 const visible=athletes.filter(a=>(a.name||'').toLowerCase().includes(term)||a.id.toLowerCase().includes(term));
 visible.sort((a,b)=>sort==='age'?(a.age||0)-(b.age||0):(a.name||'').localeCompare(b.name||''));
 list.innerHTML=visible.map(a=>{const stats=dashboard?.athletes.find(x=>x.id===a.id),value=stats?.average??null;return `<div class="athlete-row" data-id="${escapeHTML(a.id)}" tabindex="0" role="button"><div class="athlete-info"><div class="athlete-photo" data-momentum-avatar="${escapeHTML(a.id)}" style="display:grid;place-items:center;color:#39d98a"><i class="fa-solid fa-user"></i></div><div><div class="athlete-name">${escapeHTML(a.name||'Athlete')}</div><div class="athlete-meta">Age: ${escapeHTML(a.age??'—')} · ${escapeHTML(a.weight??'—')} kg · ${escapeHTML(a.height??'—')} cm</div><div class="athlete-meta" style="overflow-wrap:anywhere">${escapeHTML(a.id)}</div></div></div><div class="progress-circle" title="${escapeHTML(stats?stats.logged_days+' / '+stats.eligible_days+' days recorded this month':'Activity unavailable')}" style="--progress:${value??0}%"><span>${value===null?'—':value+'%'}</span></div><div class="progress-bar"><span style="width:${value??0}%"></span></div><div class="status">${stats?stats.logged_days+' days logged':'Connected'}</div><div class="arrow">›</div></div>`;}).join('');
 list.querySelectorAll('.athlete-row').forEach(row=>{
  const open=()=>{localStorage.setItem('momentumSelectedAthleteId',row.dataset.id);localStorage.setItem('selectedAthleteId',row.dataset.id);window.location.href='test9.html?athlete='+encodeURIComponent(row.dataset.id);};
  row.addEventListener('click',open);row.addEventListener('keydown',e=>{if(['Enter',' '].includes(e.key)){e.preventDefault();open();}});
 });
 $('emptyState').style.display=visible.length?'none':'block';
 $('emptyState').textContent=athletes.length?'No matching athletes.':'No connected athletes yet.';
 $('totalAthletes').textContent=athletes.length;$('totalAthletesStat').textContent=athletes.length;
}
function renderRequests(){
 requests.innerHTML='<div class="panel-header"><div class="panel-title"><h2>Connection Requests</h2></div></div>'+
 (pending.length?pending.map(a=>`<div class="athlete-row"><div class="athlete-info"><div><div class="athlete-name">${escapeHTML(a.name||'Athlete')}</div><div class="athlete-meta" style="overflow-wrap:anywhere">${escapeHTML(a.id)}</div></div></div><div style="display:flex;gap:8px"><button class="connection-action" data-request="${escapeHTML(a.request_id)}" data-decision="accepted" style="background:#39d98a;color:#071710;border:0;border-radius:8px;padding:10px;cursor:pointer">Accept</button><button class="connection-action" data-request="${escapeHTML(a.request_id)}" data-decision="rejected" style="background:#243542;color:white;border:0;border-radius:8px;padding:10px;cursor:pointer">Reject</button></div></div>`).join(''):'<p style="padding:16px">No pending requests.</p>');
 badge.textContent=pending.length;
 requests.querySelectorAll('.connection-action').forEach(button=>button.addEventListener('click',async()=>{
  if(busy)return;busy=true;requests.querySelectorAll('button').forEach(b=>b.disabled=true);
  try {await coaching('respond',button.dataset.request,button.dataset.decision);await refresh();}
  catch(error){status.textContent=error.message;}
  finally{busy=false;requests.querySelectorAll('button').forEach(b=>b.disabled=false);}
 }));
}
async function refresh(){
 const version=++refreshVersion;const p=await requireProfile('trainer');
 if(coachOwner&&p.id!==coachOwner){clearDashboard();throw new Error('Account changed. Reload this page.');}coachOwner=p.id;
 const records=await coaching('inbox');if(version!==refreshVersion)return;
 athletes=records.filter(a=>a.status==='accepted');pending=records.filter(a=>a.status==='pending');dashboard=null;resetStats();updateAthletes();renderRequests();
 try{const {data,error}=await sb.rpc('momentum_dashboard');if(version!==refreshVersion)return;if(error)throw error;
 dashboard=data;renderStats();updateAthletes();status.textContent='';}
 catch(error){if(version!==refreshVersion)return;dashboard=null;resetStats();updateAthletes();status.textContent='Activity unavailable: '+error.message+' Run momentum_dashboard.sql. Connections remain available.';}
}
const ready=requireProfile('trainer');
ready.then(async p=>{
 coachOwner=p.id;
 $('coachName').textContent=p.full_name||'Trainer';$('topCoachName').textContent=$('sidebarCoachName').textContent='Coach '+(p.full_name||'Trainer');
 $('coachAge').textContent=p.age??'—';$('coachId').textContent=p.id;$('coachId').style.overflowWrap='anywhere';
 $('coachId').title='Click to copy your full Trainer ID';$('coachId').style.cursor='pointer';
 $('coachId').addEventListener('click',async()=>{try{await navigator.clipboard.writeText(p.id);status.textContent='Trainer ID copied.';}catch(_){status.textContent='Select and copy the Trainer ID shown above.';}});
 localStorage.setItem('userID',p.id);localStorage.setItem('userRole',p.role);localStorage.setItem('userName',p.full_name||'');
 await refresh();
}).catch(error=>{clearDashboard();status.textContent=error.message;});
search.addEventListener('input',updateAthletes);$('sortAthletes').addEventListener('change',updateAthletes);
$('notificationBtn').addEventListener('click',async()=>{if(busy)return;try{await ready;await refresh();requests.scrollIntoView({behavior:'smooth'});}catch(e){status.textContent=e.message;}});
window.addEventListener('focus',async()=>{if(busy)return;try{await ready;await refresh();}catch(e){status.textContent=e.message;}});
$('logoutBtn').addEventListener('click',async e=>{
 e.preventDefault();if(!confirm('Are you sure you want to log out?'))return;
 try{if(!sb)throw new Error('Supabase is unavailable.');const {error}=await sb.auth.signOut();if(error)throw error;
 for(const key of ['isLoggedIn','userRole','userID','athleteId','myTrainer','momentumSelectedAthleteId','selectedAthleteId'])localStorage.removeItem(key);
 ++refreshVersion;clearDashboard();window.location.href='test.html';}catch(error){status.textContent=error.message;}
});
sb?.auth.onAuthStateChange?.((event,session)=>{if(coachOwner&&session?.user?.id!==coachOwner){++refreshVersion;clearDashboard();status.textContent='Account changed. Reload or sign in again.';}});
