
const sb=window.supabase?.createClient('https://xcgbxurbnsytecrdupct.supabase.co','sb_publishable_PAd7gf0Q-N9H4PqgqqaVNg_EfE583xO');
const $=id=>document.getElementById(id);
const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let record=null,history=[],selectedExerciseIndex=0,busy=false,loading=false;
const banner=document.createElement('p');banner.id='trackingMessage';banner.setAttribute('role','status');banner.style.cssText='color:#39d98a;overflow-wrap:anywhere;margin:12px 0';
document.querySelector('.page-title').appendChild(banner);
const daySelect=document.createElement('select');daySelect.id='planDay';daySelect.setAttribute('aria-label','Assigned plan day');
daySelect.style.cssText='background:#10252e;color:#f4f8fb;border:1px solid #24e3a3;border-radius:8px;padding:7px;margin:8px';
daySelect.innerHTML=Array.from({length:7},(_,i)=>`<option value="${i+1}">Day ${i+1}</option>`).join('');$('todayDate').after(daySelect);
const restButton=document.createElement('button');restButton.id='markRest';restButton.className='rest-button';restButton.textContent='Rest Day';$('workoutStatus').after(restButton);
$('exerciseWeight').innerHTML='<input id="actualExerciseWeight" type="number" min="0" max="2000" step="0.5" aria-label="Actual exercise weight in kg" style="width:100px;background:transparent;border:0;color:inherit;font:inherit;text-align:center" placeholder="Not logged"> <span>kg</span>';
document.querySelector('.history-title').innerHTML='<i class="fa-solid fa-chart-simple"></i> Previous logged sessions';
function message(text,error=false){banner.textContent=text;banner.style.color=error?'#ff6b6b':'#39d98a';}
async function api(action,payload=null,extra={}){
 const {data,error}=await sb.rpc('momentum_tracking',{action,log_date:null,payload,expected_revision:null,target:null,date_from:null,date_to:null,...extra});
 if(error)throw new Error(error.message);return data;
}
function lock(locked){
 document.querySelectorAll('button,input').forEach(el=>el.disabled=locked);
 daySelect.disabled=locked||!record||record.revision>0;
 if(!locked&&record){
  const rest=record.snapshot.prescribed_rest||record.state.rest_override;
  ['plusWeight','minusWeight','actualExerciseWeight','markWorkout','saveWorkout'].forEach(id=>$(id).disabled=rest||!exercises().length);
  $('completeAllMeals').disabled=!record.snapshot.meals.length;
  $('undoRest').disabled=record.snapshot.prescribed_rest;
  restButton.disabled=record.snapshot.prescribed_rest||!exercises().length;
 }
}
function exercises(){return record?.snapshot.work?.exercises||[];}
function percent(done,total){return total?Math.min(100,Math.round(100*done/total)):0;}
function chosenExercise(){return exercises()[selectedExerciseIndex];}
function exerciseKey(ex){return ((ex?.name||'')+'|'+(ex?.muscle||'')).trim().toLowerCase();}
function renderExerciseHistory(){
 const root=document.querySelector('.mini-chart'),key=exerciseKey(chosenExercise());
 const sessions=history.filter(h=>h.date<record.date).map(h=>{
  const found=(h.snapshot.work?.exercises||[]).map((ex,i)=>({ex,i})).filter(x=>exerciseKey(x.ex)===key);
  if(found.length!==1)return null;const weight=h.state.exercise_weights[found[0].i];
  return typeof weight==='number'?{date:h.date,weight}:null;
 }).filter(Boolean).slice(0,4).reverse();
 if(!sessions.length){root.innerHTML='<span style="font-size:12px;color:#8ba5b6">No earlier weights logged for this exercise.</span>';return;}
 const max=Math.max(1,...sessions.map(s=>s.weight));
 root.innerHTML=sessions.map(s=>`<div class="chart-column" title="${esc(s.date)}: ${s.weight} kg"><div class="chart-bar" style="height:${Math.max(3,70*s.weight/max)}px"></div><span>${esc(s.date.slice(5))}<br>${s.weight} kg</span></div>`).join('');
}
function selectExercise(index){
 selectedExerciseIndex=index;const ex=chosenExercise();
 $('selectedExercise').textContent=ex?(ex.name||'Exercise')+' · Target '+(ex.weight??0)+' kg':'No exercise assigned';
 $('actualExerciseWeight').value=ex?(record.state.exercise_weights[index]??''):'';
 $('actualExerciseWeight').placeholder=ex?'Target '+(ex.weight??0):'Not logged';
 if(record)renderExerciseHistory();
}
function renderWorkout(){
 const snap=record.snapshot,rest=snap.prescribed_rest||record.state.rest_override,list=$('exerciseList');
 $('workoutTitle').textContent=rest?'Rest Day':(snap.work?.focus||'No workout assigned');
 $('workoutSubtitle').textContent=snap.prescribed_rest?'Rest assigned by your coach':record.state.rest_override?'Workout skipped for today; meal and water logs stay active':'Day '+record.day_index+' · Log actual weights; targets are a guide';
 $('workoutBody').style.display=rest?'none':'grid';$('restMessage').style.display=rest?'block':'none';
 $('undoRest').style.display=snap.prescribed_rest?'none':'';
 restButton.textContent=record.state.rest_override?'Rest Day Selected':'Rest Day';
 list.innerHTML=exercises().map((ex,i)=>`<div class="exercise-row ${record.state.exercise_completed[i]?'completed':''}" data-exercise="${i}"><div class="exercise-image" style="display:grid;place-items:center;color:#24e3a3"><i class="fa-solid fa-dumbbell"></i></div><div><div class="exercise-name">${i+1}. ${esc(ex.name||'Exercise')}</div><div class="exercise-details">${esc(ex.sets)} × ${esc(ex.reps)} · Rest ${esc(ex.rest)} sec<br>Target ${esc(ex.weight??0)} kg · Actual ${record.state.exercise_weights[i]===null?'—':esc(record.state.exercise_weights[i])+' kg'}${ex.notes?'<br>'+esc(ex.notes):''}</div></div><button class="check-button" data-complete="${i}" aria-label="Toggle completion for ${esc(ex.name||'exercise')}" aria-pressed="${record.state.exercise_completed[i]}">${record.state.exercise_completed[i]?'✓':''}</button></div>`).join('')||'<p>No exercises assigned for this day.</p>';
 list.querySelectorAll('[data-exercise]').forEach(row=>row.addEventListener('click',event=>{if(event.target.closest('button'))return;selectExercise(Number(row.dataset.exercise));}));
 list.querySelectorAll('[data-complete]').forEach(button=>button.addEventListener('click',()=>change(state=>{const i=Number(button.dataset.complete);state.exercise_completed[i]=!state.exercise_completed[i];state.workout_saved=false;})));
 selectedExerciseIndex=Math.min(selectedExerciseIndex,Math.max(0,exercises().length-1));selectExercise(selectedExerciseIndex);
}
function renderMeals(){
 const meals=record.snapshot.meals;
 $('mealList').innerHTML=meals.map((meal,i)=>`<div class="meal-row ${record.state.meal_completed[i]?'completed':''}"><div class="meal-image" style="display:grid;place-items:center;color:#24e3a3"><i class="fa-solid fa-utensils"></i></div><div><div class="meal-name">${esc(meal.name||'Meal')} (${esc(meal.time||'Time not set')})</div><div class="meal-details">${(meal.foods||[]).map(f=>esc(f.name||'Food')+' — '+esc(f.quantity??'')+' '+esc(f.unit||'g')).join('<br>')}${meal.notes?'<br>'+esc(meal.notes):''}</div></div><button class="meal-check" data-meal="${i}" aria-label="Toggle completion for ${esc(meal.name||'meal')}" aria-pressed="${record.state.meal_completed[i]}">${record.state.meal_completed[i]?'✓':''}</button></div>`).join('')||'<p>No meals assigned for this day.</p>';
 $('mealList').querySelectorAll('[data-meal]').forEach(button=>button.addEventListener('click',()=>change(state=>{const i=Number(button.dataset.meal);state.meal_completed[i]=!state.meal_completed[i];})));
}
function renderWeightHistory(){
 const items=history.filter(h=>typeof h.state.body_weight==='number').slice(0,4).reverse(),root=document.querySelector('.weight-line');
 if(!items.length){root.innerHTML='<span style="font-size:12px;color:#8ba5b6">No body weights saved yet.</span>';return;}
 const values=items.map(h=>h.state.body_weight),min=Math.min(...values),range=Math.max(1,Math.max(...values)-min);
 root.innerHTML=items.map((h,i)=>`<div class="weight-point" style="left:${items.length===1?45:5+i*85/(items.length-1)}%;bottom:${8+30*(h.state.body_weight-min)/range}px" title="${esc(h.date)}"><span>${h.state.body_weight}<br><small>${esc(h.date.slice(5))}</small></span></div>`).join('');
}
function renderProgress(){
 const m=record.metrics,s=record.state,target=record.snapshot.water_target,liters=s.water_ml/1000,goal=target/1000;
 $('mealCount').textContent=m.meals_done+' / '+m.meals_total;
 $('mealProgress').style.width=m.meal_percent+'%';$('mealStat').textContent=$('goalMeals').textContent=m.meals_done+'/'+m.meals_total;$('goalMealsBar').style.width=m.meal_percent+'%';
 $('workoutStat').textContent=$('goalWorkout').textContent=m.prescribed_rest?'Rest assigned':m.rest_override?'Skipped':m.exercises_done+'/'+m.exercises_total;$('goalWorkoutBar').style.width=m.workout_percent+'%';
 $('waterAmount').textContent=$('waterText').textContent=liters+' / '+goal+' L';$('waterStat').textContent=$('goalWater').textContent=liters+'/'+goal+' L';
 $('waterPercent').textContent=m.water_percent+'%';$('waterFill').style.width=$('goalWaterBar').style.width=m.water_percent+'%';
 $('progressCircle').style.background=`conic-gradient(#24e3a3 ${m.overall_percent}%,#263842 ${m.overall_percent}%)`;$('progressCircle').setAttribute('data-progress',m.overall_percent+'%');
 $('todayWeight').value=s.body_weight??'';
 $('workoutStatus').textContent=s.workout_saved?'✓ Workout saved':'Daily activity';
}
function render(){
 daySelect.value=record.day_index;
 $('todayDate').textContent=record.date+' · Cairo';
 $('dayMessage').textContent='Day '+record.day_index+(record.revision>0?' · Today’s logged plan is kept for your history.':' · Choose the matching plan day before your first entry. Day 1 defaults to Monday.');
 renderWorkout();renderMeals();renderWeightHistory();renderProgress();lock(false);
}
async function change(update){
 if(busy||loading||!record)return false;
 busy=true;lock(true);message('Saving...');
 const prior=record,next=JSON.parse(JSON.stringify(record.state));
 try{
  update(next);
  const saved=await api('save',{day:record.day_index,plan_revision:record.snapshot.plan_revision,state:next},{log_date:record.date,expected_revision:record.revision});
  if(saved.athlete_id!==record.athlete_id)throw new Error('The signed-in account changed. Reload the page.');
  record=saved;history=[saved,...history.filter(h=>h.date!==saved.date)];render();message('Saved to Supabase · '+record.date);
  return true;
 }catch(error){record=prior;render();message('Not saved: '+error.message,true);return false;}
 finally{busy=false;lock(false);}
}
async function loadDay(day=null){
 if(busy||loading)return;loading=true;lock(true);message('Loading your published plan...');
 try{
  if(!sb)throw new Error('Supabase could not load. Check your connection and reload.');
  const auth=await sb.auth.getUser();if(auth.error||!auth.data.user){location.replace('test.html?role=athlete');throw new Error('Please sign in again.');}
  if(record&&record.athlete_id!==auth.data.user.id){record=null;history=[];resetViews();}
  const profile=await sb.from('profiles').select('id,full_name,role').eq('id',auth.data.user.id).single();if(profile.error)throw profile.error;
  if(profile.data.role!=='athlete'){location.replace('test4.html');throw new Error('Use an athlete account.');}
  const loaded=await api('load',day?{day}:null);
  if(!loaded||loaded.athlete_id!==profile.data.id)throw new Error('The signed-in account changed. Reload the page.');
  history=await api('history');record=loaded;$('headerName').textContent=profile.data.full_name||'Athlete';render();
  message(record.revision?'Loaded your saved activity.':'Ready · No activity has been recorded yet.');
 }catch(error){
  message(error.message+' If tracking is not installed, run momentum_tracking.sql.',true);
  if(!record){$('headerName').textContent='Athlete';$('workoutTitle').textContent='Plan unavailable';$('workoutSubtitle').textContent='Your saved plans and account remain unchanged.';$('exerciseList').innerHTML='';$('mealList').innerHTML='';}
 }finally{loading=false;lock(!record);}
}
$('plusWeight').addEventListener('click',()=>{const ex=chosenExercise();if(!ex)return;change(state=>{const previous=state.exercise_weights[selectedExerciseIndex]??(Number(ex.weight)||0);state.exercise_weights[selectedExerciseIndex]=Math.min(2000,previous+2.5);});});
$('minusWeight').addEventListener('click',()=>{const ex=chosenExercise();if(!ex)return;change(state=>{const previous=state.exercise_weights[selectedExerciseIndex]??(Number(ex.weight)||0);state.exercise_weights[selectedExerciseIndex]=Math.max(0,previous-2.5);});});
$('actualExerciseWeight').addEventListener('change',event=>{
 const raw=event.target.value,value=raw===''?null:Number(raw);
 if(value!==null&&(!Number.isFinite(value)||value<0||value>2000)){message('Enter a valid actual exercise weight.',true);selectExercise(selectedExerciseIndex);return;}
 change(state=>{state.exercise_weights[selectedExerciseIndex]=value;});
});
$('saveWorkout').addEventListener('click',()=>change(state=>{state.workout_saved=true;}));
$('markWorkout').addEventListener('click',()=>change(state=>{state.exercise_completed=state.exercise_completed.map(()=>true);state.workout_saved=true;}));
restButton.addEventListener('click',()=>{if(!record)return;if(!confirm('Mark today as a rest day? Your exercise entries are kept, but this does not count as completing an assigned workout.'))return;change(state=>{state.rest_override=true;});});
$('undoRest').addEventListener('click',()=>change(state=>{state.rest_override=false;}));
$('completeAllMeals').addEventListener('click',()=>change(state=>{state.meal_completed=state.meal_completed.map(()=>true);}));
document.querySelectorAll('.water-option').forEach(button=>{button.title='Set today’s total to '+button.dataset.water+' L';button.addEventListener('click',()=>change(state=>{state.water_ml=Math.round(Number(button.dataset.water)*1000);}));});
$('quickWater').addEventListener('click',()=>change(state=>{state.water_ml=Math.min(20000,state.water_ml+500);}));
$('quickWeight').addEventListener('click',()=>{$('todayWeight').focus();$('todayWeight').scrollIntoView({behavior:'smooth',block:'center'});} );
$('saveWeight').addEventListener('click',()=>{
 const weight=Number($('todayWeight').value);
 if(!Number.isFinite(weight)||weight<20||weight>300){message('Enter a body weight between 20 and 300 kg.',true);return;}
 change(state=>{state.body_weight=weight;});
});
daySelect.addEventListener('change',()=>loadDay(Number(daySelect.value)));
window.addEventListener('focus',()=>loadDay());
function resetViews(){
// Empty defaults while the account is being verified; never display fabricated progress.
$('headerName').textContent='Loading...';document.querySelector('.mini-chart').innerHTML='';document.querySelector('.weight-line').innerHTML='';
$('progressCircle').setAttribute('data-progress','0%');$('progressCircle').style.background='#263842';
for(const id of ['mealProgress','goalMealsBar','goalWorkoutBar','goalWaterBar','waterFill'])$(id).style.width='0%';
for(const id of ['workoutStat','mealStat','waterStat','goalWorkout','goalMeals','goalWater','waterText','waterAmount','waterPercent'])$(id).textContent='—';

$('exerciseList').innerHTML='';$('mealList').innerHTML='';$('todayWeight').value='';
}
resetViews();lock(true);loadDay();

