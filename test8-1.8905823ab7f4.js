

const sb=window.supabase?.createClient('https://xcgbxurbnsytecrdupct.supabase.co','sb_publishable_PAd7gf0Q-N9H4PqgqqaVNg_EfE583xO');
async function planAccount(requiredRole=null){
 if(!sb)throw new Error('Supabase could not load. Check your connection and reload.');
 const {data,error}=await sb.auth.getUser();
 if(error||!data.user){location.replace('test.html');throw new Error('Please sign in again.');}
 const result=await sb.from('profiles').select('id,role,full_name').eq('id',data.user.id).single();
 if(result.error)throw result.error;
 if(requiredRole&&result.data.role!==requiredRole){location.replace(result.data.role==='trainer'?'test4.html':'test3.html');throw new Error('Wrong account type.');}
 return result.data;
}
async function planAPI(action,target=null,payload=null,expected_revision=null){
 const {data,error}=await sb.rpc('momentum_plans',{action,target,payload,expected_revision});
 if(error)throw new Error(error.message);
 return data;
}
async function planLogout(e){
 e.preventDefault();if(!confirm('Log out?'))return;
 try{const {error}=await sb.auth.signOut();if(error)throw error;['isLoggedIn','userRole','userID','athleteId','momentumSelectedAthleteId','selectedAthleteId','momentumPlanPreviewMode','myTrainer'].forEach(k=>localStorage.removeItem(k));location.href='test.html';}
 catch(error){alert(error.message);}
}

const $=id=>document.getElementById(id);
const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let athletes=[];
$('athleteGrid').innerHTML='';$('resultCount').textContent='Loading...';
// Actual adherence is not connected; do not use the former demo progress filters.
$('statusFilter').innerHTML='<option value="all">All Account Statuses</option><option value="Active">Active</option><option value="Paused">Paused</option><option value="Expired">Expired</option>';
$('sortFilter').innerHTML='<option value="default">Sort: Default</option><option value="name">Name: A–Z</option><option value="age">Age: Low to High</option>';
function filterAthletes(){
 const term=$('searchInput').value.trim().toLowerCase(),status=$('statusFilter').value,sort=$('sortFilter').value;
 const shown=athletes.filter(a=>(a.name+' '+a.id).toLowerCase().includes(term)&&(status==='all'||a.status===status));
 shown.sort((a,b)=>sort==='age'?(a.age||0)-(b.age||0):(a.name||'').localeCompare(b.name||''));
 $('athleteGrid').innerHTML=shown.map(a=>`<article class="panel athlete-card"><div class="card-top"><div class="athlete-identity"><div class="athlete-photo" data-momentum-avatar="${esc(a.id)}" style="display:grid;place-items:center;color:#39d98a"><i class="fa-solid fa-user"></i></div><div><h3 class="athlete-name">${esc(a.name||'Athlete')}</h3><p class="athlete-id" style="overflow-wrap:anywhere">ID: ${esc(a.id)}</p></div></div><span class="status">${esc(a.status)}</span></div><div class="athlete-details"><div class="detail-box"><strong>${esc(a.age??'—')}</strong><span>Age</span></div><div class="detail-box"><strong>${esc(a.weight??'—')} kg</strong><span>Weight</span></div><div class="detail-box"><strong>${esc(a.height??'—')} cm</strong><span>Height</span></div></div><div class="progress-header"><span>Open Progress for daily activity</span><span class="progress-value">—</span></div><div class="progress-track"><div class="progress-fill" style="width:0%"></div></div><div class="card-footer"><span class="last-active">${a.visibility==='published'?'Plans published':'Draft plans'}</span><button class="view-button" data-athlete-id="${esc(a.id)}">View Profile <i class="fa-solid fa-arrow-right"></i></button></div></article>`).join('');
 $('resultCount').textContent=shown.length+' Athletes';$('emptyState').style.display=shown.length?'none':'block';$('athleteGrid').style.display=shown.length?'grid':'none';
 $('emptyState').textContent=athletes.length?'No matching athletes.':'No connected athletes. Accept a connection request first.';
 document.querySelectorAll('.view-button').forEach(b=>b.addEventListener('click',()=>{localStorage.setItem('momentumSelectedAthleteId',b.dataset.athleteId);localStorage.setItem('selectedAthleteId',b.dataset.athleteId);location.href='test9.html?athlete='+encodeURIComponent(b.dataset.athleteId);}));
}
async function loadAthletes(){
 try{const coach=await planAccount('trainer');$('sidebarCoachName').textContent=$('topCoachName').textContent=coach.full_name||'Trainer';athletes=await planAPI('list');filterAthletes();}
 catch(error){$('resultCount').textContent='Could not load athletes';$('emptyState').style.display='block';$('emptyState').textContent=error.message;}
}
$('searchInput').addEventListener('input',filterAthletes);$('statusFilter').addEventListener('change',filterAthletes);$('sortFilter').addEventListener('change',filterAthletes);
$('logoutBtn').addEventListener('click',planLogout);loadAthletes();window.addEventListener('focus',loadAthletes);

