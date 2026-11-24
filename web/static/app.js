'use strict';
const $ = (q, root = document) => root.querySelector(q);
const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const paths = {
  eye:'M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0',
  grid:'M3 3h7v7H3z M14 3h7v7h-7z M3 14h7v7H3z M14 14h7v7h-7z',
  server:'M4 3h16v7H4z M4 14h16v7H4z M7 6h.01 M7 17h.01 M11 6h6 M11 17h6',
  cluster:'M9 3h6v5H9z M2 16h6v5H2z M16 16h6v5h-6z M12 8v4 M5 16v-4h14v4',
  users:'M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2 M9 3a4 4 0 1 0 0 8 4 4 0 0 0 0-8 M20 21v-2a4 4 0 0 0-3-3.87 M16 3.13a4 4 0 0 1 0 7.75',
  backup:'M4 7h16v14H4z M3 3h18v4H3z M9 11h6 M12 14v4 M10 16l2 2 2-2',
  settings:'M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8 M12 2v3 M12 19v3 M2 12h3 M19 12h3 M5 5l2 2 M17 17l2 2 M5 19l2-2 M17 7l2-2',
  pulse:'M2 12h5l3-8 4 16 3-8h5',
  arrow:'M12 19V5 M5 12l7-7 7 7',
  clock:'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18 M12 7v5l3 2',
  plus:'M12 5v14 M5 12h14',
  refresh:'M20 7a9 9 0 0 0-15-1L2 9 M2 3v6h6 M4 17a9 9 0 0 0 15 1l3-3 M22 21v-6h-6',
  check:'M5 12l4 4L19 6',
  shield:'M12 2l8 4v6c0 5-8 10-8 10S4 17 4 12V6z M8 12l3 3 5-6',
  db:'M20 5c0 2-3.6 3-8 3S4 7 4 5s3.6-3 8-3 8 1 8 3 M4 5v14c0 2 3.6 3 8 3s8-1 8-3V5 M4 12c0 2 3.6 3 8 3s8-1 8-3',
  terminal:'M3 4h18v16H3z M6 8l3 3-3 3 M12 15h5',
  external:'M14 3h7v7 M21 3l-9 9 M10 3H3v18h18v-7',
  bolt:'M13 2L3 14h8l-1 8 11-13h-8z',
  book:'M12 5c-3-2-7-2-10-1v15c4-1 7-1 10 1 3-2 6-2 10-1V4c-3-1-7-1-10 1z M12 5v15',
  trash:'M3 6h18 M9 6V3h6v3 M5 6l1 15h12l1-15 M10 10v7 M14 10v7',
};
const icon = name => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${paths[name] || paths.grid}"/></svg>`;
const nav = [
  ['overview',uiText("Tổng quan"),'grid',uiText("QUẢN LÝ")],['clusters',uiText("Các cụm MongoDB"),'cluster'],['machines',uiText("Máy chủ"),'server'],['replica','Replica Set','cluster'],['users',uiText("User & phân quyền"),'users'],
  ['backup','Backup & restore','backup',uiText("VẬN HÀNH")],['data',uiText("Dữ liệu"),'db'],['settings',uiText("Cấu hình"),'settings'],['diagnostics',uiText("Chẩn đoán"),'pulse'],['upgrade',uiText("Phiên bản & nâng cấp"),'arrow'],['jobs',uiText("Lịch sử tác vụ"),'clock'],
];
let state = {profiles:[],machines:[],jobs:[]};
let demo = localStorage.getItem('mongo-manager-demo') === 'true';
let selected = localStorage.getItem('mongo-manager-profile') || '';
let currentRoute = 'overview', currentStatus = null, statusError = '', renderId = 0, pollTimer = null;
let topologyBusy=false, topologyChecked=0;
let actionContext = null, recordContext = null, previewPlan = null, jobId = null, backupItems = [], backupListedHost = null;
const demoProfiles = [{id:'demo-production',name:'Production',seeds:['203.0.113.10:27017','203.0.113.11:27017','203.0.113.12:27017'],replica_set:'rs0',username:'admin',auth_db:'admin',tls:false,has_password:true}];
const demoMachines = [10,11,12].map((n,i)=>({id:`demo-${n}`,name:`mongo-${String(i+1).padStart(2,'0')}`,mode:'ssh',host:`203.0.113.${n}`,port:22,user:'root',service:'mongod',identity:'',profile_id:'demo-production',mongo_endpoint:`203.0.113.${n}:27017`}));
const demoStatus = {connected:true,version:'9.0.4',fcv:'9.0',replica_set:'rs0',primary:'203.0.113.10:27017',voters:3,healthy_voters:3,majority:2,quorum:true,warnings:[],members:[
  {id:0,host:'203.0.113.10:27017',state:'PRIMARY',health:1,uptime:86400*12,lag:0,priority:1,votes:1},
  {id:1,host:'203.0.113.11:27017',state:'SECONDARY',health:1,uptime:86400*12,lag:0.2,priority:1,votes:1},
  {id:2,host:'203.0.113.12:27017',state:'SECONDARY',health:1,uptime:86400*12,lag:0.1,priority:1,votes:1}]};
const demoJobs = [
 {id:'demo-backup',action:'backup',label:uiText("Backup toàn bộ replica set"),target:'Production',status:'succeeded',created_at:new Date(Date.now()-3600000).toISOString(),events:[{time:new Date().toISOString(),message:uiText("Bản backup minh họa đã hoàn tất.")}],result:{size:'2.4 GB',sha256:uiText("Dữ liệu minh họa")}},
 {id:'demo-health',action:'preflight',label:uiText("Kiểm tra môi trường"),target:'mongo-01',status:'succeeded',created_at:new Date(Date.now()-7200000).toISOString(),events:[],result:{os:'Ubuntu 26.04 LTS',architecture:'x86_64',service_state:'active'}},
 {id:'demo-add',action:'add_member',label:uiText("Thêm Secondary mongo-03"),target:'Production',status:'succeeded',created_at:new Date(Date.now()-86400000).toISOString(),events:[],result:{ready:true}}
];
const profiles = () => demo ? demoProfiles : state.profiles;
const machines = () => demo ? demoMachines : state.machines;
const jobs = () => {
  const cluster=profile(),all=demo?demoJobs:state.jobs;
  if(!cluster)return all.filter(j=>!j.profile_id);
  const names=new Set(machines().filter(m=>m.profile_id===cluster.id).map(m=>m.name));
  return all.filter(j=>j.profile_id?j.profile_id===cluster.id:
    j.target===cluster.name||j.target.endsWith(' → '+cluster.name)||names.has(j.target));
};
const profile = () => profiles().find(p=>p.id===selected) || profiles()[0];
const badge = (text, tone='') => `<span class="badge ${tone}">${esc(text)}</span>`;
const memberTones = new Map([
  ['PRIMARY','role-primary'], ['SECONDARY','role-secondary'], ['ARBITER','role-arbiter'],
  ['STARTUP','role-sync'], ['STARTUP2','role-sync'], ['RECOVERING','role-sync'],
  ['ROLLBACK','error'], ['DOWN','error'], ['REMOVED','error']
]);
const memberBadge = state => badge(state,memberTones.get(state)||'');
const actionColors = {
  'backup-preview':'info', 'member-edit':'info', 'machine-edit':'info', 'machine-hostname':'info', preflight:'info',
  'prepared-node':'info', 'backup-repeat':'create', 'backup-new':'create', 'node-add':'create',
  'join-fresh':'create', 'add-member':'create', 'add-arbiter':'configure', 'write-concern':'configure',
  'step-down':'warning', restore:'warning', 'backup-delete':'remove',
  'member-remove':'remove', 'machine-delete':'remove', 'user-drop':'remove', 'database-drop':'remove',
  'record-delete':'remove', 'profile-delete':'remove', 'cluster-ssh-remove':'remove',
  'user-new':'create', 'machine-new':'create', 'profile-new':'create', 'cluster-ssh-add':'create', provision:'create',
  'profile-open':'info', 'profile-edit':'info', 'job-open':'info', logs:'info', diagnose:'info',
  refresh:'info', collections:'info', 'upgrade-check':'info', 'ubuntu-open':'warning', 'compatibility-refresh':'info', 'mongo-upgrade-open':'create', 'both-upgrade-open':'info',
  'member-ssh':'configure', 'ssh-bulk':'configure', 'user-password':'configure', service:'configure',
  'remember-user':'configure', 'backup-schedule':'configure', 'backup-sync':'warning'
};
const button = (label, act, glyph='', tone='', attrs='') => `<button type="button" class="button ${tone}" ${actionColors[act]&&!tone.includes('vote-label')?'data-tone="'+actionColors[act]+'"':''} data-act="${act}" ${attrs}>${glyph?icon(glyph):''}${label}</button>`;
const formatDate = s => s ? new Date(s).toLocaleString(uiLanguage==='en'?'en-US':'vi-VN',{day:'2-digit',month:'2-digit',hour:'2-digit',minute:'2-digit'}) : '—';
const bytes = n => !Number.isFinite(n) ? '—' : n>=1024**3?`${(n/1024**3).toFixed(1)} GB`:n>=1024**2?`${(n/1024**2).toFixed(1)} MB`:`${(n/1024).toFixed(1)} KB`;
const statusNames = {queued:uiText("Đang chờ"),running:uiText("Đang chạy"),succeeded:uiText("Hoàn tất"),failed:uiText("Thất bại"),interrupted:uiText("Bị gián đoạn")};
const jobBadge = j => badge(statusNames[j.status]||j.status, j.status==='succeeded'?'success':j.status==='failed'||j.status==='interrupted'?'error':'warn');
let csrfToken='';
async function api(path, options={}) {
  const response = await fetch('/api'+path,{...options,headers:{'X-MongoDB-Manager':'1','Content-Type':'application/json',...(csrfToken?{'X-CSRF-Token':csrfToken}:{}),...options.headers}});
  if(response.status===401&&path!=='/auth/login')showLogin(uiText("Phiên đăng nhập đã hết hạn. Đăng nhập lại để tiếp tục."));
  if(response.ok && response.headers.get("content-type")?.includes("application/x-ndjson"))return response.body;
  let data;
  try { data=await response.json(); }
  catch(error){
    if(!(error instanceof SyntaxError))throw error;
    const message=dataLabel('API trả về nội dung không hợp lệ. Kiểm tra đường dẫn /api trên máy chủ web.','Invalid API response. Check the web server route for /api.');
    throw Object.assign(new Error(message+' (HTTP '+response.status+')'),{invalidResponse:true,status:response.status});
  }
  if(!response.ok){
    const message=typeof data.detail==='string'?data.detail:Array.isArray(data.detail)?data.detail.map(x=>x.msg).join('; '):uiText("Yêu cầu thất bại.");
    const error=new Error(message);
    if(response.status===409){
      error.activeJob=response.headers.get('X-Active-Job');
      error.busy=!!error.activeJob||/^(Đang có tác vụ chạy|Chờ tác vụ)/.test(message);
    }
    throw error;
  }
  return data;
}
function toast(message,error=false){const el=document.createElement('div');el.className='toast'+(error?' error':'');el.textContent=message;$('#toasts').append(el);setTimeout(()=>el.remove(),5500);}
function errorBox(message){return `<div class="callout error">${esc(message)}</div>`;}
function empty(title,message,action='profile-new',label=uiText("Kết nối cụm MongoDB"),glyph='cluster'){return `<div class="empty"><span class="empty-icon">${icon(glyph)}</span><h2>${title}</h2><p>${message}</p>${action?button(label,action,'plus','primary'):''}</div>`;}
function heading(title,desc,actions=''){return `<div class="page-heading"><div><h1>${title}</h1><p>${desc}</p></div><div class="actions">${actions}</div></div>`;}
function panel(title,body,subtitle='',actions=''){return `<section class="panel"><div class="panel-head"><div><h2>${title}</h2>${subtitle?`<p>${subtitle}</p>`:''}</div>${actions}</div>${body}</section>`;}
function metric(label,value,note,glyph,good=false,route){return `<${route?'a href="#'+route+'"':'article'} class="metric"><div class="metric-head">${label}<span class="metric-icon">${icon(glyph)}</span></div><div class="metric-value">${value}</div><div class="metric-note ${good?'good':''}">${good?'<span class="dot green"></span>':''}${note}</div></${route?'a':'article'}>`;}
function table(headers,rows){return `<div class="table-wrap"><table><thead><tr>${headers.map(h=>`<th>${h}</th>`).join('')}</tr></thead><tbody>${rows.join('')}</tbody></table></div>`;}
const narrowSidebar=matchMedia('(max-width:680px)');
document.body.classList.toggle('sidebar-hidden',localStorage.getItem('mongo-sidebar-hidden')==='1');
function syncSidebarToggle(){
  const open=narrowSidebar.matches?document.body.classList.contains('nav-open'):!document.body.classList.contains('sidebar-hidden');
  for(const toggle of document.querySelectorAll('[data-act="sidebar"]')){
    toggle.textContent=open?'«':toggle.classList.contains('panel-bottom-toggle')?'»':'☰';
    toggle.setAttribute('aria-expanded',String(open));
    toggle.title=toggle.ariaLabel=open?uiText("Thu gọn menu"):uiText("Mở menu");
  }
}
narrowSidebar.addEventListener('change',syncSidebarToggle);
function updateChrome(){
  $('#navigation').innerHTML=nav.map(([id,title,glyph,group])=>`${group?`<div class="nav-label">${group}</div>`:''}<a class="nav-link ${currentRoute===id?'active':''}" href="#${id}" aria-label="${esc(title)}" title="${esc(title)}">${icon(glyph)}<span>${title}</span>${id==='jobs'&&jobs().some(j=>j.status==='running')?'<span class="nav-count">LIVE</span>':''}</a>`).join('');
  $('#profile-select').innerHTML=profiles().length?profiles().map(p=>`<option value="${esc(p.id)}" ${profile()?.id===p.id?'selected':''}>${esc(p.name)}</option>`).join(''):("<option>"+uiText("Chưa có cụm")+"</option>");
  $('#breadcrumb').textContent=nav.find(n=>n[0]===currentRoute)?.[1]||uiText("Tổng quan");
  $('#demo-toggle').textContent=demo?uiText("● Đang xem thử"):uiText("Xem thử giao diện");
  $('#demo-banner').hidden=!demo;
  $('#footer-time').textContent=demo?uiText("Chế độ minh họa"):'127.0.0.1 · Local workspace';
}
async function refreshState(){if(!demo)state=await api('/state');updateChrome();}
function nextMachineName(profileId, reserved=[]){
  const used=new Set([...machines().filter(m=>m.profile_id===profileId).map(m=>m.name),...reserved]);
  for(let n=1;;n++){
    const name='mongo-'+String(n).padStart(2,'0');
    if(!used.has(name))return name;
  }
}
function memberLabel(member, fallback){
  const key=JSON.stringify(['mongo-manager-member',demo,profile()?.id,member.id,member.host]);
  const cluster=profile();
  const saved=machines().find(m=>m.profile_id===cluster?.id&&m.mongo_endpoint===member.host);
  if(saved)fallback=saved.name;
  else if(cluster?.member_hostnames?.[member.host])fallback=cluster.member_hostnames[member.host];
  else if(cluster){
    const reserved=[];
    for(const endpoint of new Set([...cluster.seeds,member.host])){
      if(machines().some(m=>m.profile_id===cluster.id&&m.mongo_endpoint===endpoint))continue;
      const name=nextMachineName(cluster.id,reserved);
      if(endpoint===member.host){fallback=name;break;}
      reserved.push(name);
    }
  }
  const name=saved?.name||localStorage.getItem(key)||fallback;
  return `<button type="button" class="member-label" data-machine-id="${esc(saved?.id)}" data-member-key="${esc(key)}" data-fallback="${esc(fallback)}" title="${uiText("Nhấp đúp để đổi tên member")}">${esc(name)}</button>`;
}
function renameMember(event){
  const label=event.target.closest('.member-label');
  if(!label)return;
  const input=document.createElement('input');
  input.className='member-name-input';
  input.setAttribute('aria-label',uiText("Tên hiển thị của member"));
  input.maxLength=80;
  input.value=label.textContent;
  label.replaceWith(input);
  input.focus();
  input.select();
  async function finish(save,restoreFocus){
    if(!input.isConnected)return;
    const key=label.dataset.memberKey;
    const name=input.value.trim();
    input.removeEventListener('blur',onBlur);
    input.disabled=true;
    try{
      if(save && name!==label.textContent){
        const machine=machines().find(m=>m.id===label.dataset.machineId);
        if(machine){
          if(name){
            if(!demo)await api('/profiles/'+machine.profile_id+'/machines/'+machine.id+'/name',{method:'PATCH',body:JSON.stringify({name})});
            machine.name=name;
            machine.auto_name=false;
          }
          localStorage.removeItem(key);
        }else if(name)localStorage.setItem(key,name);
        else localStorage.removeItem(key);
        input.replaceWith(label);
        for(const item of document.querySelectorAll('.member-label')){
          if(item.dataset.memberKey===key)item.textContent=machine?.name||name||item.dataset.fallback;
        }
      }
    }catch(error){toast(error.message,true);}
    if(input.isConnected)input.replaceWith(label);
    if(restoreFocus)label.focus();
  }
  const onBlur=()=>finish(true,false);
  input.addEventListener('blur',onBlur);
  input.addEventListener('keydown',e=>{
    if(e.isComposing||!['Enter','Escape'].includes(e.key))return;
    e.preventDefault();
    e.stopPropagation();
    finish(e.key==='Enter',true);
  });
}
document.addEventListener('dblclick',renameMember);
document.addEventListener('keydown',event=>{
  if(event.key==='Enter' && event.target.matches('.member-label')){
    event.preventDefault();
    renameMember(event);
  }
});
function nodeLink(member){
  const href='#machines?'+new URLSearchParams({member:member.host});
  return `<a class="node-link" href="${esc(href)}" aria-label="${uiText("Quản lý VPS")} ${esc(member.host)}"></a>`;
}
let nodeClickTimer;
document.addEventListener('click',event=>{
  const name=event.target.closest('.topology .member-label');
  if(!name)return;
  clearTimeout(nodeClickTimer);
  if(event.detail===1){
    const link=name.closest('.topo-main,.topo-child').querySelector('.node-link');
    nodeClickTimer=setTimeout(()=>{if(name.isConnected)link.click();},450);
  }
});
function topology(s){
  const primary=s?.members.find(m=>m.state==='PRIMARY');
  const others=s?.members.filter(m=>m!==primary)||[];
  if(!primary)return `<div class="topology">${empty(uiText("Chưa có topology"),uiText("Kết nối cụm để xem các thành viên."),'','')}</div>`;
  return `<div class="topology"><div class="topology-tree"><div class="topo-main">${nodeLink(primary)}<span class="node-icon">${icon('db')}</span><div class="node-name">${memberLabel(primary,demo?'mongo-01':'Primary')}</div>${memberBadge('PRIMARY')}<div class="node-address">${esc(primary.host)}</div></div>${others.length?`<div class="branches${others.length>4?' many-members':''}">${others.map((m,i)=>`<div class="topo-child">${nodeLink(m)}<div class="node-name">${memberLabel(m,demo?`mongo-0${i+2}`:`Member ${m.id}`)}</div>${memberBadge(m.state)}<div class="node-address">${esc(m.host)}</div></div>`).join('')}</div>`:("<div class=\"topology-empty\">"+uiText("Thêm secondary để tạo bản sao dữ liệu.")+"</div>")}</div></div><div class="panel-foot"><span class="legend"><span class="dot green"></span> ${s.members.filter(m=>m.health).length} ${uiText("member đang hoạt động")}</span><span>${esc(s.replica_set)}</span></div>`;
}
function replicaMemberActions(member){
  const hostAttrs=`data-host="${esc(member.host)}"`;
  const election=member.votes!=null&&['PRIMARY','SECONDARY'].includes(member.state)
    ?button(dataLabel('Votes / Ưu tiên','Votes / Priority'),'member-edit','','small',hostAttrs):'';
  const remove=member.state==='PRIMARY'?'':button(uiText('Gỡ'),'member-remove','trash','small danger',hostAttrs);
  const role=member.state==='ARBITER'?'SECONDARY':member.state==='SECONDARY'?'ARBITER':'';
  const roleTone=role==='SECONDARY'?'info':'configure';
  const convert=role?button(dataLabel('Chuyển sang ','Convert to ')+role,'member-convert','','small',hostAttrs+` data-role="${role}" data-tone="${roleTone}"`):'';
  return `<div class="actions">${election}${convert}${remove}</div>`;
}
function memberTable(s,full=false){
  if(!s?.members.length)return empty(uiText("Chưa đọc được thành viên"),uiText("Kiểm tra kết nối và quyền xem replica set."),'','');
  return table([uiText("THÀNH VIÊN"),uiText("VAI TRÒ"),uiText("TRẠNG THÁI"),uiText("ĐỘ TRỄ"),'VOTES / PRIORITY',full?uiText("THAO TÁC"):'UPTIME'],s.members.map((m,i)=>`<tr><td><div class="host-cell"><span class="server-icon">${icon('server')}</span><div><strong>${memberLabel(m,demo?`mongo-0${i+1}`:`Member ${m.id}`)}</strong><small class="mongo-address"><a href="#machines?member=${encodeURIComponent(m.host)}">${esc(m.host)}</a></small></div></div></td><td>${memberBadge(m.state)}</td><td><span class="legend"><span class="dot ${m.health?'green':''}"></span>${m.health?'Healthy':uiText("Không reachable")}</span></td><td class="mono">${m.lag==null?'—':`${m.lag} s`}</td><td class="mono">${m.votes} / ${m.priority}</td><td>${full?replicaMemberActions(m):`${Math.floor(m.uptime/86400)} ${uiText("ngày")}`}</td></tr>`));
}
function overview(){
  const p=profile(),s=currentStatus;
  let html=heading(uiText("Tổng quan cụm"),uiText("Theo dõi hệ thống và quản lý MongoDB của bạn."),button(uiText("Làm mới"),'refresh','refresh')+button(uiText("Thêm node"),'node-add','plus','primary'));
  if(!p){
    html+=`<div class="welcome"><div><div class="eyebrow">${uiText("CHÀO MỪNG ĐẾN WORKSPACE")}</div><h2>${uiText("Một nơi để quản lý")}<br>${uiText("mọi node MongoDB.")}</h2><p>${uiText("Kết nối cụm đang chạy hoặc cài MongoDB trên VPS mới. Bắt đầu từ một node và mở rộng khi bạn cần.")}</p><div class="actions">${button(uiText("Kết nối cụm"),'profile-new','plus','primary')}${button(uiText("Cài đặt VPS mới"),'provision','server')}</div></div><div class="welcome-art">${icon('cluster')}</div></div>`;
    html+=`<div class="metrics">${metric(uiText("Cụm đã kết nối"),'0',uiText("Thêm hồ sơ để bắt đầu"),'cluster',false,'clusters')}${metric(uiText("Máy chủ"),String(machines().length),uiText("Local hoặc SSH"),'server',false,'machines')}${metric(uiText("Tác vụ"),String(jobs().length),uiText("Lịch sử được lưu trên máy này"),'clock',false,'jobs')}${metric(uiText("Phiên bản hỗ trợ"),'8 / 9','Ubuntu 22.04 · 24.04 · 26.04','db',false,'upgrade')}</div>`;
    html+=quickActions();
    html+=`<div class="callout neutral" style="">${uiText("Chưa có kết nối thật. Bạn có thể chọn “Xem thử giao diện” ở góc trên để khám phá với dữ liệu minh họa.")}</div>`;
    return html;
  }
  if(statusError)html+=errorBox(statusError);
  const healthy=s?.members.filter(m=>m.health===1).length||0;
  const lags=s?.members.filter(m=>m.state==='SECONDARY').map(m=>m.lag).filter(v=>v!=null)||[];
  const backup=jobs().find(j=>j.action==='backup'&&j.status==='succeeded');
  html+=`<div class="metrics">${metric(uiText("Trạng thái cụm"),s?.connected?uiText("Đã kết nối"):uiText("Chưa rõ"),s?.quorum?uiText("Đủ số phiếu cho majority"):uiText("Chưa xác minh quorum"),'pulse',!!s?.quorum,'diagnostics')}${metric(uiText("Thành viên"),`${s?.members.length??'—'} <small>nodes</small>`,`${healthy} healthy · ${Math.max(0,(s?.members.length||0)-healthy)} ${uiText("cần kiểm tra")}`,'server',!!healthy,'machines')}${metric('Replication lag',lags.length?`${Math.max(...lags)} <small>${uiText("giây")}</small>`:'—',lags.length?uiText("Độ trễ lớn nhất trên secondary"):uiText("Chưa có dữ liệu secondary"),'clock',lags.length>0,'replica')}${metric(uiText("Backup gần nhất"),backup?formatDate(backup.created_at).split(' ')[0]:'—',backup?uiText("Tác vụ backup đã hoàn tất"):uiText("Chưa ghi nhận backup"),'backup',!!backup,'backup')}</div>`;
  html+=`<div class="layout-two">${panel(`<a href="#replica">${uiText("Sơ đồ replica set")}</a>`,topology(s),uiText("Cấu trúc và vai trò của các thành viên"),badge(s?.replica_set||p.replica_set,'dark'))}${panel(`<a href="#diagnostics">${uiText("Sức khỏe hệ thống")}</a>`,`<div class="health-list"><a class="health-row" href="#upgrade"><span>MongoDB Community</span><strong>${esc(s?.version||'—')}</strong></a><a class="health-row" href="#upgrade"><span>Feature Compatibility</span><strong>${esc(s?.fcv||'—')}</strong></a><a class="health-row" href="#replica"><span>${uiText("Phiếu đang hoạt động")}</span><strong>${s?.healthy_voters??'—'} / ${s?.voters??'—'}</strong></a><a class="health-row" href="#settings"><span>${uiText("Xác thực")}</span><strong>${p.username?'Username / password':uiText("Không có user")}</strong></a><a class="health-row" href="#settings"><span>${uiText("Mã hóa TLS")}</span><strong>${p.tls?uiText("Đã bật"):uiText("Tắt")}</strong></a></div><div class="health-summary">${icon('shield')}<span>${s?.warnings?.length?esc(s.warnings[0]):s?.connected?(demo?uiText("Thông số minh họa để xem trước giao diện."):uiText("Các thông số được đọc trực tiếp từ MongoDB.")):uiText("Kết nối MongoDB để kiểm tra trạng thái.")}</span></div>`,(uiText("Tự cập nhật mỗi 10 giây ·")+" ")+(s?.checked_at?formatDate(s.checked_at):uiText("Chưa có kiểm tra thật")))}</div>`;
  html+=panel(`<a href="#replica">${uiText("Thành viên trong cụm")}</a>`,memberTable(s),uiText("Danh sách các node đã tham gia replica set"),`<a class="text-button" href="#replica">${uiText("Quản lý thành viên →")}</a>`);
  html+=quickActions();
  if(jobs().length)html+=panel(`<a href="#jobs">${uiText("Hoạt động gần đây")}</a>`,activityList(jobs().slice(0,3)),'',`<a class="text-button" href="#jobs">${uiText("Xem tất cả →")}</a>`);
  return html;
}
function quickActions(){if(profile())return `<div class="section-title"><h2>${uiText("Thao tác trong cụm")}</h2></div><div class="button-row cluster-actions">${button(uiText("Thêm Secondary"),'node-add','plus')}${button(uiText("Tạo backup"),'backup-new','backup')}${button(uiText("Kiểm tra kết nối"),'diagnose','pulse')}${button(uiText("Nhật ký VPS"),'logs','terminal')}</div>`;return `<div class="section-title"><h2>${uiText("Thao tác nhanh")}</h2><span class="page-number">WORKSPACE TOOLS</span></div><div class="quick-grid"><button class="quick-card" data-act="provision"><span class="quick-icon">${icon('server')}</span><span><strong>${uiText("Cài đặt MongoDB")}</strong><small>${uiText("Chuẩn bị VPS và tạo replica set")}</small></span><span class="quick-arrow">↗</span></button><button class="quick-card" data-act="backup-new"><span class="quick-icon">${icon('backup')}</span><span><strong>${uiText("Tạo bản backup")}</strong><small>${uiText("Lưu lại dữ liệu của cụm")}</small></span><span class="quick-arrow">↗</span></button><button class="quick-card" data-act="diagnose"><span class="quick-icon">${icon('pulse')}</span><span><strong>${uiText("Kiểm tra kết nối")}</strong><small>${uiText("Chẩn đoán các node từ máy quản trị")}</small></span><span class="quick-arrow">↗</span></button></div><div class="section-title"></div>`;}
function activityList(list){return `<div class="activity">${list.map(j=>`<div class="activity-row"><span class="activity-icon">${icon(j.status==='succeeded'?'check':'clock')}</span><div class="activity-text"><button class="text-button" data-act="job-open" data-id="${esc(j.id)}">${esc(j.label)}</button><small>${esc(j.target)}</small></div><span class="activity-time">${formatDate(j.created_at)}</span>${jobBadge(j)}</div>`).join('')}</div>`;}
function clustersPage(){
 return heading(uiText("Các cụm MongoDB"),uiText("Thêm, sửa kết nối hoặc xóa hồ sơ cụm khỏi ứng dụng."),button(uiText("SSH cho tất cả các cụm"),'ssh-bulk')+button(uiText("Thêm cụm"),'profile-new','plus','primary'))+onboardingCards()+panel(uiText("Danh sách cụm"),profiles().length?table([uiText("TÊN CỤM"),'REPLICA SET','SEED / MEMBER',uiText("THAO TÁC")],profiles().map(p=>`<tr><td><strong>${esc(p.name)}</strong></td><td>${esc(p.replica_set||'Standalone')}</td><td class="mono">${p.seeds.map(esc).join('<br>')}</td><td><div class="actions">${button(uiText("Mở"),'profile-open','','small',`data-id="${esc(p.id)}"`)}${button(uiText("Sửa"),'profile-edit','','small',`data-id="${esc(p.id)}"`)}${button(uiText("Xóa"),'profile-delete','trash','small danger',`data-id="${esc(p.id)}"`)}</div></td></tr>`)):empty(uiText("Chưa có cụm"),uiText("Bấm Thêm cụm rồi nhập seed và tài khoản MongoDB.")))+`<div class="callout neutral">${uiText("Xóa hồ sơ chỉ bỏ kết nối khỏi ứng dụng. Dữ liệu, user MongoDB và replica set trên VPS vẫn giữ nguyên.")}</div>`;
}
const hostnameBatches=new Set();
function workspaceSSHHosts(){return machines().filter(m=>m.mode==='ssh'&&(m.profile_id||'')===(profile()?.id||''));}
function machinePage(){
 let html=heading(uiText("Máy chủ"),uiText("Quản lý kết nối SSH, cài đặt và dịch vụ trên từng máy."),button(uiText("Thêm máy chủ"),'machine-new','plus'));
 if(!profile())html+=onboardingCards();
 const linked=machines().filter(m=>!profile()||m.profile_id===profile().id);
 const members=profile()?(currentStatus?.members||profile().seeds.map(host=>({host}))):[];
 const memberByHost=new Map(members.map(member=>[member.host,member]));
 linked.sort((a,b)=>Number(memberByHost.has(b.mongo_endpoint))-Number(memberByHost.has(a.mongo_endpoint)));
 const rows=linked.map((m,index)=>{
   const member=memberByHost.get(m.mongo_endpoint);
   return `<tr data-node="${esc(m.mongo_endpoint)}" tabindex="-1"><td class="row-number">${index+1}</td><td><div class="host-cell"><span class="server-icon">${icon('server')}</span><div><strong>${member?.id!=null?memberLabel(member,m.name):esc(m.name)}</strong>${m.mongo_endpoint?`<small class="mongo-address">${esc(m.mongo_endpoint)}</small>`:''}${member?.state?memberBadge(member.state):''}</div></div></td><td>${badge(m.mode==='ssh'?'SSH':'LOCAL','dark')} ${m.mode==='ssh'?`<span class="mono ssh-address">${esc(m.user)}@${esc(m.host.includes(':')?'['+m.host+']':m.host)}:${esc(m.port)}</span>`:''}</td><td class="mono">${esc(m.service)}<small>${esc(profiles().find(p=>p.id===m.profile_id)?.name||uiText("Chưa liên kết cụm"))}</small></td><td><div class="actions">${!member&&profile()&&currentStatus&&m.mode==='ssh'?button(uiText("Thêm làm Secondary"),'join-fresh','plus','small',`data-id="${esc(m.id)}"`):''}${button(uiText("Kiểm tra"),'preflight','pulse','small',`data-id="${esc(m.id)}"`)}${button(uiText("Dịch vụ"),'service','','small',`data-id="${esc(m.id)}"`)}${button(dataLabel('Nhật ký','Logs'),'logs','terminal','small',`data-id="${esc(m.id)}"`)}${button(uiText("Sửa"),'machine-edit','','small',`data-id="${esc(m.id)}"`)}${button(uiText("Xoá"),'machine-delete','trash','small danger',`data-id="${esc(m.id)}"`)}</div></td></tr>`;
 });
 const discovered=[];
 for(const member of members){
   if(linked.some(m=>m.mongo_endpoint===member.host))continue;
   const label=member.id!=null?memberLabel(member,'Member '+member.id):esc(profile()?.member_hostnames?.[member.host]||member.host);
   discovered.push(`<tr data-node="${esc(member.host)}" tabindex="-1"><td class="row-number">${discovered.length+1}</td><td><strong>${label}</strong><small class="mongo-address">${esc(member.host)}</small>${member.state?memberBadge(member.state):''}</td><td>${uiText("Chưa cấu hình SSH")}</td><td>—</td><td><div class="actions">${button(uiText("Cấu hình SSH"),'member-ssh','','small',`data-host="${esc(member.host)}"`)}</div></td></tr>`);
 }
 const headers=[uiText("STT"),uiText("MÁY CHỦ"),uiText("KẾT NỐI"),'SERVICE',uiText("THAO TÁC")];
 const fetching=hostnameBatches.has(profile()?.id||'');
 const hostnameAction=workspaceSSHHosts().length?button(fetching?dataLabel('Đang lấy tên…','Reading hostnames…'):dataLabel('Lấy tên từ VPS','Get VPS hostnames'),'machine-hostname','refresh','small',fetching?'disabled':''):'';

 html+=panel(uiText("Máy chủ của bạn"),rows.length?table(headers,rows):empty(uiText("Thêm máy chủ đầu tiên"),uiText("Kết nối bằng mật khẩu SSH hoặc key/agent."),'machine-new',uiText("Thêm máy chủ"),'server'), '', `<div class="actions">${hostnameAction}</div>`);
 if(discovered.length)html+=panel(uiText("Thành viên chưa lưu hồ sơ máy"),table(headers,discovered));

 if(!profile())html+=`<div class="cards">${feature(uiText("Cài MongoDB Server"),uiText("Kiểm tra repository và cài package Community 8.0 hoặc 9.0 đúng phiên bản Ubuntu."),'server','install',uiText("Cài package"))}${feature(uiText("Tạo replica set"),uiText("Tạo instance mới với service riêng, keyfile và tài khoản quản trị."),'cluster','setup',uiText("Bắt đầu setup"))}${feature(uiText("Xem nhật ký dịch vụ"),uiText("Đọc 100 dòng journal gần nhất của service đã cấu hình."),'terminal','logs',uiText("Mở nhật ký"))}</div>`;
 return html;
}

function onboardingCards(){return `<div class="cards onboarding">${feature(uiText("Cụm đã có primary / secondary"),uiText("Nhập endpoint bất kỳ và tài khoản MongoDB. Tự nhận diện replica set và toàn bộ member; tiếp nhận để quản lý."),'cluster','profile-new',uiText("Tiếp nhận cụm đang chạy"))}${feature(uiText("VPS mới → Cụm mới"),uiText("Thêm hồ sơ SSH, kiểm tra môi trường, cài package và tạo replica set một node cùng tài khoản quản trị."),'server','provision',uiText("Cài và tạo cụm mới"))}${feature(uiText("VPS mới → Secondary"),uiText("Chọn cụm đích và một member nguồn (primary hoặc secondary). Đọc keyfile qua SSH, cấu hình node trống, thêm và chờ đồng bộ."),'plus','join-fresh',uiText("Thêm VPS vào cụm"))}</div>`;}
function profileFormData(form){
 const raw=Object.fromEntries(new FormData(form));
 const data=Object.fromEntries(['name','seeds','replica_set','auth_db','username','password','tls_ca'].map(k=>[k,raw[k]??'']));
 data.seeds=data.seeds.split(/[\n,]+/).map(v=>v.trim()).filter(Boolean);data.tls=form.elements.tls.checked;
 if(recordContext.id&&!data.password)data.password=null;
 return data;
}
async function probeProfileForm(){
 const form=$('#record-form');
 // Only MongoDB fields belong to this read-only probe; optional SSH is saved later.
 const data=profileFormData(form);const output=$('#probe-result');
 output.innerHTML=("<div class=\"callout neutral\">"+uiText("Đang đăng nhập và đọc trạng thái cụm…")+"</div>");$('#form-error').replaceChildren();
 try{
 const result=demo?{profile:demoProfiles[0],status:demoStatus}:await api('/profiles/probe',{method:'POST',body:JSON.stringify({...data,record_id:recordContext.id||''})});
 if(!form.isConnected)return;
 form.elements.replica_set.value=result.profile.replica_set;form.elements.seeds.value=result.profile.seeds.join('\n');
 output.innerHTML=`<div class="callout">${demo?uiText("Minh họa"):uiText("Đã xác minh")}: ${esc(result.status.replica_set)} · ${result.status.members.length} member · Primary: ${esc(result.status.primary)}.</div>`;
 }catch(error){if(form.isConnected){output.replaceChildren();formError(error);}}
}
function hostnameField(input,record){
  input.required=false;
  input.dataset.fallback=input.value;
  input.placeholder=dataLabel('Tự đọc hostname','Detect hostname');
  input.title=dataLabel('Để trống để dùng hostname của máy chủ','Leave blank to use the server hostname');
  if(!record || record.auto_name)input.value='';
}
function addClusterSSH(record=null){
 const container=$('#cluster-ssh-list');if(!container)return;
 const index=recordContext.sshIndex++;const prefix='cluster_ssh_'+index+'_';
 const firstSeed=$('[name="seeds"]',$('#record-form')).value.split(/[\n,]+/)[0].trim();
 const host=firstSeed.startsWith('[')?firstSeed.slice(1,firstSeed.indexOf(']')):firstSeed.split(':')[0];
 const row=document.createElement('section');row.className='cluster-ssh-row';row.dataset.recordId=record?.id||'';row.dataset.prefix=prefix;row.dataset.hasPassword=record?.has_ssh_password?'1':'';
 const f=(name,...args)=>field(prefix+name,...args);
 row.innerHTML=`<div class="ssh-row-heading"><strong>${uiText("SSH cho một VPS")}</strong>${button(uiText("Bỏ khỏi lần lưu"),'cluster-ssh-remove','','small')}</div><div class="form-grid">${f('name',uiText("Tên VPS"),record?.name||nextMachineName(recordContext.id||'',Array.from(container.querySelectorAll('input[name$="_name"]'),el=>el.value||el.dataset.fallback)),'text',dataLabel('Để trống để tự đọc hostname. Có thể nhập tên riêng.','Leave blank to detect the hostname, or enter a custom name.'))}${f('mongo_endpoint',uiText("Endpoint MongoDB trên VPS"),record?.mongo_endpoint||firstSeed,'text',uiText("IP:port của member tương ứng; IP trống port dùng 27017."))}${f('host',uiText("Địa chỉ SSH"),record?.host||host)}${f('port','Port SSH',record?.port||22,'number')}${f('user','User SSH',record?.user||'root')}${f('ssh_auth',uiText("Xác thực SSH"),record?.ssh_auth||'password','select','',false,[{value:'password',label:uiText("Mật khẩu SSH")},{value:'key',label:'SSH key / Agent'}])}${f('ssh_password',uiText("Mật khẩu SSH"),'','password',record?.has_ssh_password?uiText("Để trống để giữ mật khẩu đã lưu."):uiText("Mật khẩu của tài khoản hệ điều hành trên VPS."),true)}${f('identity','SSH private key',record?.identity||'','text',uiText("Để trống để dùng agent."),true)}${f('service','Service MongoDB',record?.service||'mongod','text',uiText("Tên systemd service đang chạy."),true)}</div>`;
 if(record?.has_ssh_password)markSavedPassword(row.querySelector('.password-control input'),'/machines/'+record.id+'/reveal-password');
 hostnameField(row.querySelector(`[name="${prefix}name"]`),record);
 container.append(row);
 const sync=()=>{
 const password=row.querySelector(`[name="${prefix}ssh_auth"]`).value==='password';
 for(const key of ['ssh_password','identity']){const input=row.querySelector(`[name="${prefix+key}"]`);const show=key==='ssh_password'?password:!password;input.closest('.field').hidden=!show;input.disabled=!show;}
 };
 row.addEventListener('change',sync);sync();
}
function clusterSSHData(){
 return [...document.querySelectorAll('.cluster-ssh-row')].map(row=>{
 const value=key=>row.querySelector(`[name="${row.dataset.prefix+key}"]`).value.trim();
 const secret=row.querySelector(`[name="${row.dataset.prefix}ssh_password"]`).value;
 const auth=value('ssh_auth');if(!value('host')||!value('mongo_endpoint'))throw new Error(uiText("SSH: nhập tên VPS, địa chỉ SSH và endpoint MongoDB tương ứng."));
 if(auth==='password'&&!secret&&!row.dataset.hasPassword)throw new Error((uiText("Nhập mật khẩu SSH cho VPS")+" ")+value('name')+'.');
 return {record_id:row.dataset.recordId,machine:{auto_name:!value('name'),name:value('name')||row.querySelector(`[name="${row.dataset.prefix}name"]`).dataset.fallback,mode:'ssh',host:value('host'),port:Number(value('port')),user:value('user'),ssh_auth:auth,ssh_password:auth==='password'?(secret||null):'',identity:auth==='key'?value('identity'):'',service:value('service'),mongo_endpoint:value('mongo_endpoint')}};
 });
}

function feature(title,desc,glyph,act,label){return `<article class="feature-card"><span class="quick-icon">${icon(glyph)}</span><h2>${title}</h2><p>${desc}</p>${button(label,act,'','')}</article>`;}
function replicaPage(){return heading('Replica Set',uiText("Quản lý thành viên, vai trò và cấu hình bầu chọn."),button(uiText("Thêm Arbiter"),'add-arbiter','plus')+button(uiText("Node đã chuẩn bị"),'prepared-node','plus')+button(uiText("Thêm Secondary"),'node-add','plus','primary'))+(statusError?errorBox(statusError):'')+panel(uiText("Thành viên"),memberTable(currentStatus,true),'',currentStatus?.members.some(m=>m.state==='PRIMARY')?button(uiText("Đổi primary"),'step-down','','small change-primary'):'')+`<div class="cards">${feature('Step down Primary',uiText("Chuyển quyền primary qua cơ chế bầu chọn. Cần secondary sẵn sàng và đủ quorum."),'cluster','step-down',uiText("Xem trước"))}${feature('Write Concern',uiText("Xem và đặt mức xác nhận ghi cho replica set."),'shield','write-concern',uiText("Cấu hình"))}</div>`;}
function archiveHosts(){return machines().filter(m=>m.profile_id===profile()?.id);}
function archiveHostKey(){return 'mongo-backup-host:'+demo+':'+profile()?.id;}
function selectedArchiveHost(){
  const hosts=archiveHosts(),saved=localStorage.getItem(archiveHostKey());
  const recent=jobs().find(j=>['backup','backups'].includes(j.action)&&hosts.some(m=>m.id===j.machine_id||m.name===j.target));
  return hosts.find(m=>m.id===saved)||hosts.find(m=>m.id===recent?.machine_id||m.name===recent?.target)||hosts[0];
}
const deletedDemoBackups=new Set();
let catalogLoading=false,catalogError='';
async function readBackupCatalog(pid,machineId,id){
  try{return await api('/profiles/'+pid+'/machines/'+machineId+'/backups');}
  catch(error){
    if(!error.invalidResponse||[401,403].includes(error.status)||id!==renderId)throw error;
  }
  // Some proxies return their own HTML page for slow SSH requests.
  const post=(path,body)=>api(path,{method:'POST',body:JSON.stringify(body)});
  const plan=await post('/plans',{action:'backups',profile_id:pid,machine_id:machineId});
  if(id!==renderId)return [];
  let job=await post('/jobs',{plan_id:plan.id,confirmation:plan.confirmation});
  while(['queued','running'].includes(job.status)){
    await new Promise(resolve=>setTimeout(resolve,1000));
    if(id!==renderId)return [];
    job=await api('/jobs/'+job.id);
  }
  if(job.status!=='succeeded')throw new Error(job.error||uiText("Yêu cầu thất bại."));
  return job.result;
}
async function loadArchiveCatalog(id){
  const host=selectedArchiveHost(),pid=profile()?.id;
  backupItems=[];backupListedHost=host;catalogError='';catalogLoading=!!host;
  $('#content').innerHTML=backupPage();
  if(!host)return;
  try{
    const items=demo?[{id:'a'.repeat(32),time:new Date().toISOString(),machine_id:host.id,source:profile().name,source_id:pid,database:'application',size:2048}]:
      await readBackupCatalog(pid,host.id,id);
    if(id!==renderId||currentRoute!=='backup')return;
    backupItems=demo?items.filter(b=>!deletedDemoBackups.has(host.id+'/'+b.id)):items;
  }catch(e){
    if(id!==renderId||currentRoute!=='backup')return;
    catalogError=host.name+' · '+e.message;
  }
  catalogLoading=false;$('#content').innerHTML=backupPage();
}
function backupCatalog(){
  if(catalogLoading)return `<div class="loading"><span class="spinner"></span>${uiText("Đang tải…")} ${esc(backupListedHost?.name||'')}</div>`;
  if(catalogError){
    const verify=backupListedHost?.ssh_auth==='password'&&catalogError.includes('Chưa có khóa của');
    return errorBox(catalogError)+(verify?sshKeyButton(backupListedHost.id):'');
  }
  if(!backupItems.length && backupListedHost)return empty(dataLabel("Chưa có bản backup","No backups found"),esc(backupListedHost.name)+" · /var/backups/mongodb-manager","backup-new",uiText("Tạo backup"),"backup");
  if(!backupItems.length)return empty(dataLabel("Chưa có máy lưu backup","No archive host"),uiText("Thêm máy thực thi trước khi thực hiện."),'machine-new',uiText("Thêm máy chủ"),'server');
  const rows=backupItems.map((b,index)=>{
    const target=`data-backup="${esc(b.id)}" data-id="${esc(b.machine_id||backupListedHost?.id||'')}"`;
    const actions=button(dataLabel('Xem dữ liệu','View data'),'backup-preview','db','small',target)
      +(b.source_id===profile()?.id?button(dataLabel('Backup lại','Back up again'),'backup-repeat','refresh','small',target):'')
      +button('Restore','restore','','small',target)+button(dataLabel('Xóa','Delete'),'backup-delete','','small danger',target);
    const counts=Object.entries(b.restore_counts||{});
    const restored=counts.length?counts.map(([name,n])=>badge(dataLabel(`Đã restore ${n} lần vào ${name}`,`Restored ${n} time(s) to ${name}`),'success')).join('<br>'):badge(dataLabel('Chưa restore','Not restored'),'warn');
    const scope=b.collections?.length?b.collections.join(', '):b.collection;
    return `<tr><td>${formatDate(b.time)} ${index===0?badge(dataLabel('Mới nhất','Latest'),'success'):''}</td><td><code class="archive-id">${esc(b.id)}</code></td>
      <td><strong>${esc(b.source)}</strong><br>${esc(b.database)}${scope?' / '+esc(scope):''}</td><td>${bytes(b.size)}</td>
      <td>${badge(uiText("Có checksum"),'success')} ${restored}</td><td><div class="archive-actions">${actions}</div></td></tr>`;
  });
  return table([uiText("THỜI GIAN"),'ID BACKUP',uiText("NGUỒN / DATABASE"),uiText("DUNG LƯỢNG"),uiText("KIỂM CHỨNG"),''],rows);

}
const demoSchedules = new Map();
function currentSchedule(){
  const id=profile()?.id;
  return demo?demoSchedules.get(id):state.backup_schedules?.find(s=>s.id===id);
}
function scheduleSummary(){
  const schedule=currentSchedule();
  if(!schedule?.enabled)return dataLabel('Lịch backup đang tắt','Backup schedule is off');
  const next=schedule.next_run && new Date(schedule.next_run).toLocaleString(uiLanguage==='en'?'en-GB':'vi-VN',{timeZone:'Asia/Ho_Chi_Minh',dateStyle:'short',timeStyle:'short'});
  return [dataLabel('Lịch đang bật','Schedule enabled'),schedule.cron,next && dataLabel('Lần tới ','Next ')+next+' (UTC+7)'].filter(Boolean).join(' · ');
}
function backupPage(){return heading('Backup & restore',dataLabel('Sao lưu theo database, đồng bộ dữ liệu mới hoặc khôi phục sang cụm khác.','Back up databases, sync current data or restore to another cluster.'),button(dataLabel('Đồng bộ ngay','Sync now'),'backup-sync','refresh')+button(uiText("Làm mới"),'refresh','refresh')+button(uiText("Tạo backup"),'backup-new','plus','primary'))+`<div class="callout">${uiText("Backup được lưu trên máy thực thi tại")} <code>/var/backups/mongodb-manager</code>${dataLabel('. Backup toàn replica set có oplog. Các database được chọn được sao lưu tuần tự.','. Full replica set backups include the oplog. Selected databases are backed up sequentially.')}</div>`+panel(uiText("Các bản backup"),(archiveHosts().length?`<label class="field panel-body">${dataLabel('Máy lưu backup','Archive host')}<select id="archive-host">${archiveHosts().map(m=>`<option value="${esc(m.id)}" ${m.id===selectedArchiveHost()?.id?'selected':''}>${esc(m.name)}</option>`).join('')}</select></label>`:'')+backupCatalog(),esc(scheduleSummary()),button(dataLabel('Lịch backup','Backup schedule'),'backup-schedule','clock'))+`<div class="cards compact-cards">${feature(uiText("Backup toàn cụm hoặc một phần"),dataLabel('Chọn một, nhiều database hoặc toàn cụm.','Select one or more databases or the entire cluster.'),'backup','backup-new',uiText("Tạo bản sao"))}${feature(uiText("Restore từ bản backup"),uiText("Chọn đúng máy chứa backup và cụm đích. Xem lại toàn bộ thông tin trước khi ghi dữ liệu."),'db','restore',uiText("Khôi phục dữ liệu"))}</div>`;}
function sshSettingsPanel(){return panel(uiText(currentRoute==='clusters'?"SSH cho tất cả các cụm":"SSH cho cụm hiện tại"),`<div class="panel-body"><p>${uiText("Mỗi VPS giữ thông tin SSH riêng, không phụ thuộc vai trò primary/secondary. Có thể áp dụng cùng tài khoản cho các node được chọn, sau đó sửa riêng từng VPS khi cần.")}</p>${button(uiText("Cấu hình SSH nhiều VPS"),'ssh-bulk','server','primary')}</div>`);}
let pendingJoin=false,pendingJoinOptions={};
function showNodeAdd(arbiter=false){
  const role=arbiter?'Arbiter':'Secondary';
  modal((uiText("Thêm")+" ")+role,`<div class="modal-body"><div class="cards compact-cards">${feature(uiText("Node đã chạy MongoDB"),uiText("Nhập endpoint của node đã cấu hình cùng replica set và keyfile. Dùng tài khoản MongoDB của cụm."),'cluster',arbiter?'mongo-arbiter':'add-member',uiText("Thêm qua MongoDB"))}${feature(uiText("VPS cần cài hoặc cấu hình"),uiText("Dùng SSH để kiểm tra phiên bản, cài MongoDB và chuẩn bị keyfile trước khi thêm node."),'server',arbiter?'ssh-arbiter':'join-fresh',uiText("Chuẩn bị qua SSH"))}</div></div>`,button(uiText("Đóng"),'modal-close'));
}
let sshBulkTargets=[];
function openBulkSSH(){
 sshBulkTargets=[];
 for(const p of (currentRoute==='clusters'?profiles():[profile()].filter(Boolean)))for(const endpoint of p.seeds){
   const existing=machines().find(m=>m.mode==='ssh'&&m.profile_id===p.id&&m.mongo_endpoint===endpoint);
   const host=endpoint.startsWith('[')?endpoint.slice(1,endpoint.indexOf(']')):endpoint.slice(0,endpoint.lastIndexOf(':'));
   sshBulkTargets.push({profile:p,endpoint,host,existing});
 }
 if(!sshBulkTargets.length){toast(uiText("Thêm cụm MongoDB trước để cấu hình SSH cho các member."));return;}
 const rows=sshBulkTargets.map((t,i)=>`<tr><td><input type="checkbox" name="targets" value="${i}" checked aria-label="${uiText("Chọn ")}${esc(t.profile.name+' '+t.endpoint)}"></td><td>${esc(t.profile.name)}</td><td class="mono">${esc(t.endpoint)}</td><td>${t.existing?.has_ssh_password?savedPasswordControl('/machines/'+t.existing.id+'/reveal-password'):badge(t.existing?'Key / Agent':uiText("Chưa có SSH"))}</td></tr>`);
 modal(uiText(currentRoute==='clusters'?"SSH cho tất cả các cụm":"SSH cho cụm hiện tại"),`<form id="ssh-bulk-form"><div class="modal-body"><div class="callout neutral">${uiText("Chọn các VPS thực sự dùng cùng thông tin SSH. Lưu chỉ cập nhật hồ sơ trên ứng dụng, không đổi mật khẩu trên VPS. Node thêm về sau cần được cấu hình riêng.")}</div>${table([uiText("CHỌN"),uiText("CỤM"),'MEMBER','SSH'],rows)}<div class="section-title"></div><div class="form-grid">${field('user','User SSH','root')}${field('port','Port SSH',22,'number')}${field('ssh_auth',uiText("Xác thực SSH"),'password','select','',true,[{value:'password',label:uiText("Mật khẩu SSH")},{value:'key',label:'SSH key / Agent'}])}${field('ssh_password',uiText("Mật khẩu SSH"),'','password',uiText("Nhập để áp dụng cho các VPS đã chọn. Để trống chỉ giữ mật khẩu đã lưu; VPS chưa có cần nhập."),true)}${field('identity',uiText("SSH private key (tùy chọn)"),'','text',uiText("Chỉ dùng khi chọn Key / Agent."),true)}</div><div id="form-error"></div></div><div class="modal-footer">${button(uiText("Hủy"),'modal-close')}<button class="button primary" type="submit">${uiText("Lưu cho các VPS đã chọn")}</button></div></form>`);
}
document.addEventListener('submit',async event=>{
 if(event.target.id!=='ssh-bulk-form')return;event.preventDefault();const form=event.target,submit=form.querySelector('button[type="submit"]');submit.disabled=true;
 try{
 const fields=Object.fromEntries(new FormData(form));const chosen=new FormData(form).getAll('targets');if(!chosen.length)throw new Error(uiText("Chọn ít nhất một VPS."));if(chosen.length>50)throw new Error(uiText("Chọn tối đa 50 VPS mỗi lần lưu."));
 const reserved=new Map();
 const records=chosen.map(index=>{const t=sshBulkTargets[Number(index)],old=t.existing;
 if(fields.ssh_auth==='password'&&!fields.ssh_password&&!old?.has_ssh_password)throw new Error('VPS '+t.endpoint+(" "+uiText("chưa có mật khẩu SSH.")));
 const names=reserved.get(t.profile.id)||[];
 const name=old?.name||nextMachineName(t.profile.id,names);names.push(name);reserved.set(t.profile.id,names);
 return {record_id:old?.id||'',machine:{name,auto_name:old?!!old.auto_name:true,mode:'ssh',host:old?.host||t.host,port:Number(fields.port),user:fields.user,ssh_auth:fields.ssh_auth,ssh_password:fields.ssh_auth==='password'?(fields.ssh_password||null):'',identity:fields.ssh_auth==='key'?fields.identity:'',profile_id:t.profile.id,mongo_endpoint:t.endpoint,service:old?.service||'mongod'}};
 });
 if(demo){toast(uiText("Chế độ minh họa không lưu thông tin SSH."));return;}
 await api('/machines/batch',{method:'POST',body:JSON.stringify(records)});form.elements.ssh_password.value='';$('#modal').close();await refreshState();await render();toast((uiText("Đã lưu SSH cho")+" ")+records.length+' VPS.');
 }catch(error){formError(error);}finally{submit.disabled=false;}
});
function settingsPage(){const p=profile();return heading(uiText("Cấu hình workspace"),uiText("Thông tin kết nối và các thiết lập của cụm đang chọn."),button(uiText("Chỉnh kết nối"),'profile-edit','settings','primary'))+(demo?'':panel(dataLabel('Quản trị MongoDB Manager','Manager administrator'),'',dataLabel('Tài khoản đăng nhập giao diện web.','Login for the web interface.'),button(dataLabel('Sửa tài khoản quản trị','Edit administrator account'),'manager-admin','settings')))+sshSettingsPanel()+panel(uiText("Hồ sơ MongoDB"),p?`<div class="panel-body">${[[uiText("Tên cụm"),p.name],['Seed list',p.seeds.join(', ')],['Replica set',p.replica_set||'Standalone'],['Username',p.username||uiText("Không dùng")],['Auth database',p.auth_db],['TLS',p.tls?uiText("Bật"):uiText("Tắt")]].map(([k,v])=>`<div class="key-value"><span>${k}</span><strong>${esc(v)}</strong></div>`).join('')}<div class="section-title"></div><div class="actions">${button(uiText("Chỉnh kết nối"),'profile-edit','settings','primary')}${button(uiText("Chuỗi kết nối"),'connection','external')}${button(uiText("Xóa hồ sơ"),'profile-delete','trash','danger')}</div></div>`:empty(uiText("Chưa chọn cụm"),uiText("Tạo hồ sơ kết nối trước khi cấu hình.")))+`<div class="callout neutral">${uiText("Hồ sơ và mật khẩu được mã hóa trên máy quản trị. Khóa mã hóa nằm cùng thư mục dữ liệu, chỉ tài khoản hệ điều hành hiện tại có quyền đọc. SSH hỗ trợ mật khẩu hoặc key/agent của tài khoản chạy ứng dụng.")}</div>`;}
function diagnosticsPage(){return heading(uiText("Chẩn đoán"),uiText("Kiểm tra kết nối MongoDB và môi trường máy chủ."),button(uiText("Kiểm tra kết nối"),'diagnose','pulse','primary'))+`<div class="cards">${feature(uiText("Kết nối các node"),uiText("Kết nối trực tiếp từng seed, xác thực và đọc vai trò từ máy quản trị."),'cluster','diagnose',uiText("Chạy chẩn đoán"))}${feature(uiText("Môi trường VPS"),uiText("Kiểm tra Ubuntu, CPU, kernel, đĩa, package và service qua SSH."),'server','preflight',uiText("Kiểm tra máy"))}${feature(uiText("Nhật ký MongoDB"),uiText("Xem journal của service để xác định lỗi startup, quyền hoặc port."),'terminal','logs',uiText("Đọc nhật ký"))}</div><div class="section-title"><h2>${uiText("Kết quả kiểm tra")}</h2></div><div id="query-result">${empty(uiText("Sẵn sàng kiểm tra"),uiText("Chọn một phép kiểm tra phía trên. Các bước chẩn đoán chỉ đọc thông tin."),'','','pulse')}</div>`;}
function hostCompatibilityPanel(){
  const hosts=machines().filter(m=>(m.profile_id||'')===(profile()?.id||''));
  if(!hosts.length)return panel('Ubuntu',empty(dataLabel('Chưa có máy để kiểm tra','No hosts to inspect'),'', 'machine-new',uiText('Thêm máy')));
  const requested=new URLSearchParams(location.hash.split('?')[1]).get('machine');
  const host=hosts.find(m=>m.id===requested)||hosts[0];
  const options=hosts.map(m=>({value:m.id,label:m.name+' · '+(m.host||'Local')}));
  const selector=field('compatibility_host',dataLabel('Máy cần kiểm tra','Host to inspect'),host.id,'select','',false,options);
  const upgrades=`${button(dataLabel('Nâng cấp Ubuntu','Upgrade Ubuntu'),'ubuntu-open','server')}${button(dataLabel('Nâng cấp MongoDB','Upgrade MongoDB'),'mongo-upgrade-open','db')}${button(dataLabel('Nâng cả hai','Upgrade both'),'both-upgrade-open','arrow')}`;
  return panel(dataLabel('Ubuntu và MongoDB trên máy','Ubuntu and MongoDB on this host'),
    `<div class="panel-body host-compatibility"><div class="compatibility-controls">${selector}<div id="compatibility-branch" hidden></div>${button(dataLabel('Kiểm tra lại','Check again'),'compatibility-refresh','pulse')}${upgrades}</div><div id="compatibility-report" aria-live="polite"></div></div>`,
    dataLabel('Đọc phiên bản trên máy và đối chiếu gói từ kho MongoDB chính thức.','Read host versions and check packages in the official MongoDB repository.'));
}
function compatibilityReport(r,series,machineId){
  const t=dataLabel;
  const statuses={compatible:t('Ubuntu hiện tại phù hợp','Current Ubuntu is compatible'),upgrade:t('Cần nâng Ubuntu','Ubuntu upgrade required'),unsupported:t('Cấu hình chưa được hỗ trợ','Unsupported configuration'),unknown:t('Chưa xác minh được','Verification incomplete')};
  statuses.mongo_upgrade=t('Giữ Ubuntu 26.04 · Cần nâng MongoDB','Keep Ubuntu 26.04 · MongoDB upgrade needed');
  statuses.change_series=t('Giữ Ubuntu 26.04 · Chọn MongoDB 9.0','Keep Ubuntu 26.04 · Select MongoDB 9.0');
  const outcome=['mongo_upgrade','change_series'].includes(r.status)
    ?t(`Kho chính thức có MongoDB Community ${r.package} cho ${r.arch}.`,`The official repository provides MongoDB Community ${r.package} for ${r.arch}.`)
    :r.reason;
  const role=({stopped:t('Đã dừng','Stopped'),uninitialized:t('Replica set chưa khởi tạo','Replica set uninitialized'),other:t('Vai trò khác','Other member role')})[r.role]||r.role||t('Chưa xác minh','Unverified');
  const notes=[];
  if(r.processes>1)notes.push(t(`Có ${r.processes} tiến trình mongod trên máy. Trình nâng Ubuntu tự động yêu cầu một instance duy nhất.`,`This host has ${r.processes} mongod processes. Automated Ubuntu upgrades require a single instance.`));
  if(r.arbiter_version_restricted)notes.push(t('Đã xác nhận ARBITER. Endpoint giới hạn quyền đọc phiên bản MongoDB.', 'ARBITER confirmed. The endpoint restricts access to the MongoDB version.'));
  else if(r.endpoint&&!r.live&&r.role!=='stopped')notes.push(r.endpoint_error||t('Chưa đọc được phiên bản trực tiếp từ endpoint.','The endpoint version could not be verified directly.'));
  const resources=r.resources||{};
  const gib=value=>Number.isFinite(value)?(value/1024**3).toFixed(2)+' GiB':'—';
  const capacity=(used,total)=>gib(used)+' / '+gib(total);
  const rows=[
    ['Ubuntu',r.os,r.hostname], [t('Kiến trúc CPU','CPU architecture'),r.arch,r.current],
    ['CPU',Number.isFinite(resources.cpu_percent)?resources.cpu_percent+'%':'—',resources.cpu_count?resources.cpu_count+' vCPU':'—'],
    ['RAM',capacity(resources.ram_total-resources.ram_available,resources.ram_total),t('Khả dụng','Available')+' · '+gib(resources.ram_available)],
    [t('Ổ đĩa /','Root disk /'),capacity(resources.disk_used,resources.disk_total),t('Còn trống','Free')+' · '+gib(resources.disk_free)+' · '+(resources.disk_medium||t('Chưa rõ loại ổ','Unknown drive type'))],
    ['MongoDB',r.version||r.series,r.live?t('Đọc trực tiếp từ endpoint','Reported by the endpoint'):r.version?t('Đọc từ mongod trên máy','Reported by host binary'):t('Nhánh dự định cài','Planned series')],
    [t('Gói trong kho chính thức','Official repository package'),r.package||'—',r.target?'Ubuntu '+r.target:''],
    [t('Dịch vụ','Service'),r.service,r.service_state], [t('Vai trò MongoDB','MongoDB role'),role,r.endpoint||'—']
  ];
  if(r.pending){
    const visible=rows.filter((_,i)=>i===8?r.endpointReady:i===6?false:i===5?r.version:r.hostReady);
    return table([t('Hạng mục','Item'),t('Kết quả','Result'),t('Chi tiết','Details')],visible.map(row=>'<tr>'+row.map(cell=>'<td>'+esc(cell||'—')+'</td>').join('')+'</tr>'));
  }

  const detail=outcome||r.path.join(' → ');
  return `<div class="compatibility-summary"><div class="compatibility-outcome">${badge(statuses[r.status],r.status==='compatible'?'success':'warn')}${detail?`<span>${esc(detail)}</span>`:''}</div></div>`+
    table([t('Hạng mục','Item'),t('Kết quả','Result'),t('Chi tiết','Details')],rows.map(row=>'<tr>'+row.map(cell=>'<td>'+esc(cell||'—')+'</td>').join('')+'</tr>'))+
    notes.map(note=>`<div class="callout">${esc(note)}</div>`).join('');
}
async function loadCompatibility(){
  const output=$('#compatibility-report'),selector=$('[name="compatibility_host"]');
  if(!output||!selector)return;
  const id=selector.value;
  const branch=$('#compatibility-branch');
  if(branch.dataset.host!==id){branch.hidden=true;branch.replaceChildren();branch.dataset.host=id;}
  try{await loadReleaseOptions();}catch(error){output.innerHTML=errorBox(error.message);return;}
  if(!output.isConnected||selector.value!==id)return;
  const series=output.dataset.series||releaseOptions.series[0];
  const view=document.createElement('div');
  output.replaceChildren(view);
  function finish(report){
    if(!view.isConnected)return;
    branch.hidden=!!report.version;
    branch.innerHTML=!report.version?field('compatibility_series',dataLabel('Nhánh MongoDB dự định cài','Planned MongoDB series'),series,'select','',false,releaseOptions.series):'';
    view.compatibility=report;
    view.innerHTML=compatibilityReport(report,series,id);
  }
  const m=machines().find(host=>host.id===id);
  if(demo){
    finish({os:'Ubuntu 26.04 LTS',arch:'arm64',current:'resolute',hostname:m.name,version:'9.0.4',series:'9.0',package:'9.0.4',target:'26.04',status:'compatible',path:[],live:true,role:demoStatus.members.find(node=>node.host===m.mongo_endpoint)?.state,service:m.service,service_state:'active',endpoint:m.mongo_endpoint,processes:1});
    return;
  }
  const parts={},errors=[];
  function draw(){
    if(!view.isConnected)return;
    const report={...parts.host,...parts.endpoint,version:parts.endpoint?.live_version||parts.host?.version,
      pending:true,hostReady:!!parts.host,endpointReady:!!parts.endpoint};
    const waiting=[];
    if(!parts.host)waiting.push('SSH');
    if(!parts.endpoint)waiting.push('MongoDB');
    if(!waiting.length)waiting.push(dataLabel('kho gói','package repository'));
    view.innerHTML=compatibilityReport(report,series,id)+errors.map(errorBox).join('')+
      (errors.length?'':'<p role="status">'+esc(dataLabel('Đang kiểm tra ','Checking ')+waiting.join(' · ')+'…')+'</p>');
  }
  draw();
  try{
    const body=await api('/machines/'+encodeURIComponent(id)+'/compatibility?stream=true&series='+encodeURIComponent(series));
    if(!body.getReader){finish(body);return;}
    const reader=body.pipeThrough(new TextDecoderStream()).getReader();
    let buffer='',complete=false;
    while(true){
      const {value,done}=await reader.read();
      if(!view.isConnected){await reader.cancel();return;}
      if(done)break;
      buffer+=value;
      let newline;
      while((newline=buffer.indexOf('\n'))>=0){
        const update=JSON.parse(buffer.slice(0,newline));
        buffer=buffer.slice(newline+1);
        if(update.stage==='complete'){complete=true;finish(update.value);}
        else{
          if(update.stage==='error')errors.push(update.value);
          else parts[update.stage]=update.value;
          draw();
        }
      }
    }
    if(!complete&&!errors.length)throw new Error(dataLabel('Kết nối bị ngắt. Bấm Kiểm tra lại.','Connection interrupted. Check again.'));
  }catch(error){errors.push(error.message);draw();}
}

function upgradePage(){return heading(uiText("Phiên bản & nâng cấp"),uiText("Kiểm tra tương thích trước khi thay đổi phiên bản MongoDB."),button(uiText("Kiểm tra điều kiện"),'upgrade-check','pulse','primary'))+`${hostCompatibilityPanel()}<div class="layout-two">${panel(uiText("Quy trình nâng 8.0 → 9.0"),`<div class="panel-body"><ol class="step-list"><li><strong>${uiText("Kiểm tra và backup")}</strong>${uiText("Xác minh driver, FCV và sức khỏe tất cả member. Restore thử trước khi thay phiên bản.")}</li><li><strong>${uiText("Nâng secondary tuần tự")}</strong>${uiText("Đợi từng member quay lại SECONDARY rồi mới chuyển sang node tiếp theo.")}</li><li><strong>${uiText("Chuyển primary")}</strong>${uiText("Step down, chờ primary mới rồi nâng node còn lại.")}</li><li><strong>${uiText("Kiểm chứng ứng dụng")}</strong>${uiText("Giữ FCV cũ trong thời gian kiểm tra. Nâng FCV bằng bước riêng sau đó.")}</li></ol></div>`)}${panel(uiText("Phạm vi tự động hóa"),`<div class="panel-body"><div class="callout">${uiText("Arbiter 8.0 trên Ubuntu 26.04 có thể nâng binary ngay trong bảng trên. Với node chứa dữ liệu và bước nâng FCV, xem quy trình nâng cụm.")}</div><p class="help-links"><a href="https://www.mongodb.com/docs/manual/tutorial/install-mongodb-on-ubuntu/" target="_blank" rel="noopener noreferrer">${dataLabel('Cài MongoDB Community trên Ubuntu ↗','Install MongoDB Community on Ubuntu ↗')}</a></p><p class="help-links"><a href="https://www.mongodb.com/docs/manual/release-notes/9.0-upgrade-from-8.0-replica-set/" target="_blank" rel="noopener noreferrer">${uiText("Mở hướng dẫn MongoDB chính thức ↗")}</a></p>${button(uiText("Xem kết quả kiểm tra"),'upgrade-check','pulse')}</div>`)}</div>`;}
function jobsPage(){return heading(uiText("Lịch sử tác vụ"),uiText("Theo dõi tiến độ, kết quả và những thao tác cần kiểm tra."),button(uiText("Làm mới"),'refresh','refresh'))+panel(uiText("Tác vụ"),jobs().length?table([uiText("TÁC VỤ"),uiText("ĐÍCH"),uiText("THỜI GIAN"),uiText("TRẠNG THÁI"),''],jobs().map(j=>`<tr><td><strong>${esc(j.label)}</strong></td><td>${esc(j.target)}</td><td>${formatDate(j.created_at)}</td><td>${jobBadge(j)}</td><td>${button(uiText("Chi tiết"),'job-open','','small',`data-id="${esc(j.id)}"`)}</td></tr>`)):empty(uiText("Chưa có tác vụ"),uiText("Các thao tác thực hiện từ web sẽ xuất hiện tại đây."),'','','clock'));}
async function render(){
  documentTailObserver?.disconnect();
  const id=++renderId; currentRoute=location.hash.slice(1).split('?')[0]||'overview';
  if(currentRoute==='upgrade'){
    const requested=new URLSearchParams(location.hash.split('?')[1]).get('machine');
    const linked=machines().find(m=>m.id===requested);
    if(linked?.profile_id&&linked.profile_id!==selected){
      selected=linked.profile_id;currentStatus=null;
      if(!demo)localStorage.setItem('mongo-manager-profile',selected);
    }
  }
  if(!nav.some(n=>n[0]===currentRoute))currentRoute='overview';
  updateChrome();document.body.classList.remove('nav-open');syncSidebarToggle();
  const needsStatus=['overview','machines','replica'].includes(currentRoute);
  if(demo){currentStatus=profile()?structuredClone(demoStatus):null;statusError='';}
  else if(needsStatus&&profile()){
    $('#content').innerHTML=heading(nav.find(n=>n[0]===currentRoute)[1],uiText("Đang đọc dữ liệu từ MongoDB…"))+("<div class=\"loading\"><span class=\"spinner\"></span>"+uiText("Đang kết nối cụm")+"</div>");
    try{const data=await api(`/profiles/${profile().id}/status`);if(id!==renderId)return;currentStatus=data;statusError='';topologyChecked=Date.now();const saved=state.profiles.find(p=>p.id===profile()?.id);if(saved&&data.seeds)saved.seeds=data.seeds;}
    catch(e){if(id!==renderId)return;currentStatus=null;statusError=e.message;}
  }else if(!profile()){currentStatus=null;statusError='';}
  if(id!==renderId)return;
  const pages={overview,clusters:clustersPage, machines:machinePage, replica:replicaPage,backup:backupPage,settings:settingsPage,diagnostics:diagnosticsPage,upgrade:upgradePage,jobs:jobsPage};
  if(currentRoute==='backup'){await loadArchiveCatalog(id);return;}
  if(pages[currentRoute]){
    $('#content').innerHTML=pages[currentRoute]();
    if(currentRoute==='jobs'){
      const requested=new URLSearchParams(location.hash.split('?')[1]).get('job');
      if(requested){
        history.replaceState(null,'','#jobs');
        try{await openJob(requested);}catch(error){toast(error.message,true);}
      }
    }
    if(currentRoute==='upgrade')loadCompatibility();
    if(currentRoute==='machines'){
      const endpoint=new URLSearchParams(location.hash.split('?')[1]).get('member');
      const row=Array.from(document.querySelectorAll('tr[data-node]')).find(r=>r.dataset.node===endpoint);
      if(row){
        row.classList.add('selected-node');
        row.focus({preventScroll:true});
        row.scrollIntoView({block:'center'});
      }
    }
  }
  else {
    const users=currentRoute==='users';
    const pageHeader=users
      ? heading(uiText("User & phân quyền"),uiText("Quản lý quyền truy cập vào các database."),button(uiText("Tạo user"),'user-new','plus','primary'))
      : heading(uiText("Dữ liệu"),uiText("Duyệt database, chọn collection để xem và chỉnh sửa document."),button(uiText("Làm mới"),'refresh','refresh','primary'));
    $('#content').innerHTML=pageHeader+`<div id="query-result"><div class="loading"><span class="spinner"></span>${uiText("Đang tải…")}</div></div>`;
    if(!profile()){$('#query-result').innerHTML=empty(uiText("Chưa có kết nối"),uiText("Thêm hồ sơ MongoDB để đọc dữ liệu."));return;}
    const position=users?null:currentExplorerPosition();
    if(position){await openDataExplorer(position.database,position);return;}
    try{const data=demo?(users?[{user:'admin',db:'admin',roles:[{role:'root',db:'admin'}]},{user:'app_service',db:'app',roles:[{role:'readWrite',db:'app'}]},{user:'backup_agent',db:'admin',roles:[{role:'backup',db:'admin'}]}]:[{name:'admin',sizeOnDisk:2*1024**2},{name:'application',sizeOnDisk:2.4*1024**3},{name:'analytics',sizeOnDisk:640*1024**2},{name:'local',sizeOnDisk:256*1024**2}]):await api(`/profiles/${profile().id}/query/${users?'users':'databases'}`);
      if(id!==renderId)return;
      $('#query-result').innerHTML=users?panel(uiText("Tài khoản"),table(['USERNAME','DATABASE',uiText("VAI TRÒ"),uiText('Mật khẩu'),''],data.map(u=>`<tr><td><strong>${esc(u.user)}</strong></td><td>${esc(u.db)}</td><td>${u.roles.map(r=>badge(r.role,'dark')).join(' ')}</td><td>${u.has_password?savedPasswordControl(userPasswordPath(u.db,u.user)):button(dataLabel('Lưu mật khẩu','Save password'),'remember-user','','small',`data-db="${esc(u.db)}" data-user="${esc(u.user)}"` )}</td><td>${button(dataLabel('Đổi mật khẩu','Change password'),'user-password','','small',`data-user="${esc(u.user)}" data-db="${esc(u.db)}"`)} ${button(uiText("Xóa"),'user-drop','','small',`data-user="${esc(u.user)}" data-db="${esc(u.db)}"`)}</td></tr>`))):panel('Databases',table(['DATABASE',uiText("DUNG LƯỢNG"),uiText("LOẠI"),''],data.map(d=>`<tr><td><div class="host-cell"><span class="server-icon">${icon('db')}</span><strong>${esc(d.name)}</strong></div></td><td>${bytes(d.sizeOnDisk)}</td><td>${badge(['admin','local','config'].includes(d.name)?uiText("Hệ thống"):uiText("Ứng dụng"))}</td><td>${button('Collections','collections','','small',`data-db="${esc(d.name)}"`)} ${!['admin','local','config'].includes(d.name)?button(uiText("Xóa"),'database-drop','','small',`data-db="${esc(d.name)}"`):''}</td></tr>`)));
    }catch(e){if(id===renderId)$('#query-result').innerHTML=errorBox(e.message);}
  }
}

function modal(title,body,footer='',subtitle=''){
  $('#modal-content').innerHTML=`<div class="modal-header"><div><div class="eyebrow">${demo?uiText("CHẾ ĐỘ XEM THỬ"):'MONGODB MANAGER'}</div><h2>${title}</h2>${subtitle?`<p>${subtitle}</p>`:''}</div><button class="icon-button" data-act="modal-close" aria-label="${uiText("Đóng")}">×</button></div>${body}${footer?`<div class="modal-footer">${footer}</div>`:''}`;
  if(!$('#modal').open)$('#modal').showModal();
  const scrollBody=$('.modal-body',$('#modal'));if(scrollBody)scrollBody.scrollTop=0;
}
function confirmProfileDeletion(name,machineId){
  const dialog=document.createElement('dialog');
  dialog.className='delete-confirmation';
  dialog.setAttribute('aria-labelledby','delete-confirmation-title');
  dialog.innerHTML=`<form method="dialog"><div class="modal-header"><h2 id="delete-confirmation-title">${uiText("Xóa hồ sơ")}</h2></div><div class="modal-body"><p><strong>${esc(name)}</strong> · ${uiText("Hồ sơ sẽ được xóa khỏi ứng dụng. Dữ liệu và dịch vụ trên VPS vẫn giữ nguyên.")}</p></div><div class="modal-footer"><button class="button" value="cancel" autofocus>${uiText("Hủy")}</button><button class="button danger" value="delete">${uiText("Xoá")}</button></div></form>`;
  if(machineId){
    const status=dialog.querySelector('.modal-body p');
    const submit=dialog.querySelector('[value="delete"]');
    submit.disabled=true;
    status.textContent=dataLabel('Đang kiểm tra dịch vụ trên ','Checking service on ')+name+'…';
    api('/machines/'+machineId+'/delete-check').then(result=>{
      status.textContent=name+' · '+result.service+' · '+dataLabel('Đã dừng. Manager sẽ kiểm tra lại khi xác nhận xóa.','Stopped. Manager will check again on confirmation.');
      if(dialog.open)submit.disabled=false;
    }).catch(error=>{status.textContent=error.message;status.setAttribute('role','alert');});
  }
  document.body.append(dialog);
  return new Promise(resolve=>{
    dialog.addEventListener('close',()=>{
      const accepted=dialog.returnValue==='delete';
      dialog.remove();
      resolve(accepted);
    },{once:true});
    dialog.showModal();
  });
}
function markSavedPassword(input,path){
  input.dataset.savedPassword=path;input.placeholder='••••••••';
}
function savedPasswordControl(path){
  return passwordControl(`<input type="password" readonly placeholder="••••••••" aria-label="${uiText('Mật khẩu')}" data-saved-password="${esc(path)}">`);
}
function userPasswordPath(db,user){
  return '/profiles/'+profile().id+'/user-password?'+new URLSearchParams({database:db,username:user});
}
function passwordControl(input){
  const label=uiText("Hiện mật khẩu");
  return `<span class="password-control">${input}<button type="button" data-act="password-toggle" aria-pressed="false" aria-label="${label}" title="${label}">${icon('eye')}</button></span>`;
}
async function togglePassword(button){
  const input=button.previousElementSibling;
  const reveal=input.type==='password';
  if(reveal && !input.value && input.dataset.savedPassword && !demo){
    button.disabled=true;
    const result=await api(input.dataset.savedPassword,{method:'POST'});
    if(!input.isConnected || button.closest('dialog')?.open===false)return;
    if(!input.value)input.value=result.password;
  }
  if(!reveal&&input.readOnly)input.value='';
  input.type=reveal?'text':'password';
  button.setAttribute('aria-pressed',String(reveal));
  button.title=uiText(reveal?'Ẩn mật khẩu':'Hiện mật khẩu');
  button.setAttribute('aria-label',button.title);
}
function field(name,label,value='',type='text',help='',wide=false,options=[]){
  let input;
  if(type==='select')input=`<select name="${name}">${options.map(o=>`<option value="${esc(o.value??o)}" ${(o.value??o)===value?'selected':''}>${esc(o.label??o)}</option>`).join('')}</select>`;
  else if(type==='checkbox')input=`<input type="checkbox" name="${name}" ${value?'checked':''}>`;
  else if(type==='textarea')input=`<textarea name="${name}" ${name==='seeds'?'required':''}>${esc(value)}</textarea>`;
  else input=`<input name="${name}" type="${type}" value="${esc(value)}" ${type==='password'?'autocomplete="new-password"':''} ${['name','username','host','instance','advertise','replica_set','port','backup_id'].includes(name)?'required':''} ${type==='number'?'step="any"':''}>`;
  if(type==='password')input=passwordControl(input);
  return `<label class="field ${wide?'wide':''} ${type==='checkbox'?'checkbox':''}">${type==='checkbox'?input:''}<span>${label}</span>${type!=='checkbox'?input:''}${help?`<small>${help}</small>`:''}</label>`;
}
function showRecord(kind,record=null,draft={}){
  recordContext={kind,profileId:record?.profile_id||profile()?.id||'',id:record?.id,hasSSHPassword:!!record?.has_ssh_password,sshIndex:0};jobId=null;
  let fields='';
  if(kind==='profiles'){
    fields=field('name',uiText("Tên hiển thị"),record?.name||'','text',uiText("Ví dụ: Production hoặc Staging"),true)+field('seeds','Seed list',record?.seeds.join('\n')||'','textarea',uiText("Nhập IP hoặc hostname của member; bỏ trống port sẽ dùng 27017. Ví dụ: 203.0.113.10 hoặc 203.0.113.10:27018."),true)+field('replica_set',uiText("Tên replica set"),record?.replica_set??'','text',uiText("Để trống để tự nhận diện từ primary hoặc secondary."))+field('auth_db','Auth database',record?.auth_db||'admin')+field('username','Username MongoDB',record?.username||'')+field('password',uiText("Mật khẩu MongoDB"), '', 'password',record?uiText("Để trống để giữ mật khẩu đã lưu."):uiText("Được mã hóa trên máy quản trị."))+field('tls',uiText("Bật TLS"),record?.tls||false,'checkbox','',true)+field('tls_ca',uiText("Đường dẫn CA (nếu dùng)"),record?.tls_ca||'','text',uiText("Đường dẫn trên máy quản trị. Để trống để dùng CA hệ thống."),true);
  }else{
    const mode=record?.mode==='local'?'local':'ssh';
    const endpoint=record?.mongo_endpoint||draft.mongo_endpoint||'';
    const [,mongoHost='',mongoPort='27017']=endpoint.match(/^(\[[^\]]+\]|[^:]+)(?::(\d+))?$/)||[];
    const address=mongoHost.replace(/^\[|\]$/g,'');
    const sshOverride=record?.host&&record.host!==address?record.host:'';
    const t=dataLabel;
    const arbiter=pendingJoin&&pendingJoinOptions.arbiter===true;
    fields=field('name',uiText("Tên máy chủ"),record?.name||nextMachineName(recordContext.profileId),'text',t('Để trống để tự đọc hostname.','Leave blank to detect the hostname.'))
      +field('service',uiText("Tên service"),record?.service||'mongod')
      +field('mongo_host',mode==='ssh'?t('Địa chỉ IP public','Public IP address'):t('Địa chỉ MongoDB','MongoDB address'),address)
      +field('mongo_port',t('Cổng MongoDB','MongoDB port'),mongoPort,'number')
      +field('votes','Votes',arbiter?1:Number(record?.votes??pendingJoinOptions?.votes??1),'select','',false,[0,1])
      +field('priority',uiText('Ưu tiên bầu primary'),arbiter?0:record?.priority??pendingJoinOptions?.priority??1,'number',arbiter?t('Arbiter chỉ bỏ phiếu.','An arbiter only votes.'):t('Áp dụng khi thêm Secondary.','Used when adding a secondary.'))
      +`<input type="hidden" name="mode" value="${mode}">`
      +field('user','User SSH',record?.user||'root')
      +field('port','Port SSH',record?.port||22,'number')
      +field('ssh_auth',uiText("Xác thực SSH"),record?.ssh_auth||draft.ssh_auth||'password','select','',false,[{value:'password',label:uiText("Mật khẩu SSH")},{value:'key',label:'SSH key / Agent'}])
      +field('ssh_password',uiText("Mật khẩu SSH"),'','password',record?.has_ssh_password?uiText("Đã lưu mật khẩu. Để trống để giữ nguyên."):'')
      +field('identity',uiText("SSH private key (tùy chọn)"),record?.identity||'','text',uiText("Để trống để dùng SSH agent hoặc ~/.ssh/config."))
      +`<details class="field wide" ${mode==='local'?'hidden':''} ${sshOverride?'open':''}><summary>${t('Địa chỉ SSH riêng','Separate SSH address')}</summary>
          ${field('host',t('Địa chỉ SSH (nếu khác)','SSH address (if different)'),sshOverride,'text',t('Để trống để dùng địa chỉ IP public ở trên.','Leave blank to use the public address above.'))}</details>`;
  }
  modal(record?uiText("Chỉnh sửa hồ sơ"):kind==='profiles'?uiText("Kết nối cụm MongoDB"):uiText("Thêm máy chủ"),`<form id="record-form"><div class="modal-body"><div class="form-grid">${fields}</div>${kind==='profiles'?("<div id=\"probe-result\"></div><details class=\"cluster-ssh\"><summary>"+uiText("SSH cho các VPS trong cụm (tùy chọn)")+"</summary><p>"+uiText("Tài khoản SSH dùng để đọc log, điều khiển service, cài đặt và xử lý trên VPS. Mỗi VPS có thông tin SSH riêng; tài khoản này khác tài khoản MongoDB ở trên. Lưu hồ sơ không tự chạy lệnh trên VPS.")+"</p><div id=\"cluster-ssh-list\"></div>")+button(uiText("Thêm VPS bằng SSH"),'cluster-ssh-add','plus')+' '+button(uiText("Lưu SSH"),'cluster-ssh-save')+("<p>"+uiText("Có thể lưu SSH trước để kiểm tra VPS khi MongoDB chưa kết nối được. Sau đó tiếp nhận cụm khi đã xử lý xong.")+"</p></details>"):''}<div id="form-error"></div></div><div class="modal-footer">${kind==='profiles'?button(uiText("Kiểm tra kết nối"),'profile-probe'):''}${kind==='machines'&&record?.mode==='ssh'&&record.ssh_auth==='password'&&!demo?sshKeyButton(record.id):''}${record?button(uiText("Xóa hồ sơ"),'record-delete','trash','danger'):''}${button(uiText("Hủy"),'modal-close')}<button class="button primary" type="submit">${icon('check')}${kind==='profiles'?uiText("Kiểm tra & lưu cụm"):uiText("Lưu hồ sơ")}</button></div></form>`,'',kind==='profiles'?uiText("Tiếp nhận cụm đang chạy: chỉ đọc và kiểm tra kết nối, không cài đặt hay khởi tạo lại."):uiText("Với mật khẩu SSH, Manager tự lưu khóa VPS ở lần kết nối đầu tiên. Với key/agent, cần thêm VPS vào known_hosts trước."));
  if(record?.has_password || record?.has_ssh_password){
    markSavedPassword($('#record-form .password-control input'),'/'+kind+'/'+record.id+'/reveal-password');
  }
  if(kind==='machines'){
    const {votes,priority}=$('#record-form').elements;
    priority.min=0;
    priority.max=1000;
    votes.disabled=pendingJoin&&pendingJoinOptions.arbiter===true;
    const syncPriority=()=>{priority.readOnly=votes.disabled||votes.value==='0';if(priority.readOnly)priority.value=0;};
    votes.addEventListener('change',syncPriority);
    syncPriority();
    hostnameField($('#record-form').elements.name,record);syncSSHFields();$('#record-form').addEventListener('change',syncSSHFields);}
  // Anonymous MongoDB connections are valid.
  if(kind==='profiles'){
    const linked=machines().filter(m=>record?.id&&m.profile_id===record.id&&m.mode==='ssh');linked.forEach(addClusterSSH);if(linked.length)$('.cluster-ssh').open=true;
    $('[name="username"]', $('#record-form')).removeAttribute('required');
    $('[name="replica_set"]', $('#record-form')).removeAttribute('required');
  }
}
function syncSSHFields(){
  const form=$('#record-form'); if(!form?.elements.ssh_auth)return;
  const remote=form.elements.mode.value==='ssh';
  const password=remote&&form.elements.ssh_auth.value==='password';
  for(const name of ['host','port','user','ssh_auth','identity','ssh_password']){
    const input=form.elements[name];
    const shown=remote&&(name==='identity'?!password:name==='ssh_password'?password:true);
    input.closest('.field').hidden=!shown; input.disabled=!shown;
    if(name==='host')input.required=false;
    if(name==='ssh_password')input.required=password&&!recordContext.hasSSHPassword;
  }
}
const schemas={
  mongo_upgrade:{title:dataLabel('Nâng cấp MongoDB','Upgrade MongoDB'),host:true,profile:true,note:dataLabel('Manager sẽ tìm bản mới nhất trong nhánh đã chọn và kiểm tra máy trước khi xác nhận.','Manager checks the latest package in the chosen series and verifies the host before confirmation.'),fields:[['series',uiText('Nhánh MongoDB'),'','select','',false,[]]]},
  arbiter_upgrade:{title:dataLabel("Nâng MongoDB trên arbiter","Upgrade arbiter MongoDB"),host:true,profile:true,fields:[]},
  preflight:{title:uiText("Kiểm tra môi trường"),host:true,fields:[]},
  logs:{title:uiText("Xem nhật ký dịch vụ"),host:true,fields:[]},
  install:{title:uiText("Cài MongoDB Community"),host:true,note:uiText("Cài mới bằng package chính thức. Nếu đã có mongod, tác vụ sẽ dừng và giữ nguyên phiên bản hiện tại."),fields:[['series',uiText("Nhánh MongoDB"),'','select','',false,[]]]},
  setup:{title:uiText("Tạo replica set một node"),host:true,note:uiText("Cần cài mongod và mongosh trước. Tạo service và đường dẫn riêng theo tên instance. Cụm mới dùng keyfile và mật khẩu, TLS tắt."),fields:[['instance',uiText("Tên instance"),'production','text',uiText("Chữ thường, số, dấu gạch ngang.")],['replica_set',uiText("Tên replica set"),'rs0'],['port','Port MongoDB',27017,'number'],['advertise',uiText("Địa chỉ quảng bá"),'', 'text',uiText("Nhập IP public hoặc DNS của VPS kèm port MongoDB, ví dụ mongo.example.com:27017.")],['bind_ip','Bind address','0.0.0.0','text',uiText("0.0.0.0 hoặc danh sách IP có 127.0.0.1. Firewall quản lý riêng."),true],['username',uiText("User quản trị"),'admin'],['password',uiText("Mật khẩu quản trị"),'','password',uiText("Ít nhất 12 ký tự.")]]},
  service:{
    title:dataLabel('Dịch vụ MongoDB trên máy chủ','MongoDB service on the host'),
    host:true,
    hostLabel:dataLabel('Máy chủ chạy MongoDB','MongoDB host'),
    note:dataLabel('Manager điều khiển dịch vụ MongoDB được ghi sau tên máy, ví dụ mongod. Dừng hoặc khởi động lại MongoDB có thể làm gián đoạn truy cập dữ liệu.', 'Manager controls the MongoDB service listed after the host name, for example mongod. Stopping or restarting MongoDB can interrupt data access.'),
    fields:[['operation','MongoDB','diagnose','select','',true,[
      {value:'diagnose',label:dataLabel('Chẩn đoán dịch vụ','Diagnose service')},
      {value:'repair_keyfile',label:dataLabel('Sửa quyền keyfile và khởi động instance Manager','Repair keyfile permissions and start Manager instance')},
      {value:'start',label:dataLabel('Khởi động MongoDB','Start MongoDB')},
      {value:'stop',label:dataLabel('Dừng MongoDB','Stop MongoDB')},
      {value:'restart',label:dataLabel('Khởi động lại MongoDB','Restart MongoDB')},
      {value:'enable',label:dataLabel('Bật tự chạy MongoDB khi máy chủ khởi động','Enable MongoDB at host boot')},
      {value:'disable',label:dataLabel('Tắt tự chạy MongoDB khi máy chủ khởi động','Disable MongoDB at host boot')}
    ]]]
  },
  add_member:{title:uiText("Thêm thành viên"),profile:true,note:uiText("Node đích phải chạy mongod với cùng replSetName và keyfile. Web thêm membership; không ghi đè cấu hình node đích. Chọn Votes và Ưu tiên khi thêm secondary."),fields:[['host',uiText("Địa chỉ node"),'','text',uiText("IP hoặc hostname:port"),true],['arbiter',uiText("Thêm dưới vai trò Arbiter"),false,'checkbox','',true]]},
  convert_role:{title:dataLabel('Đổi vai trò thành viên','Convert member role'),profile:true,note:dataLabel('Dừng mongod trên VPS đã chọn và thêm lại với thư mục dữ liệu mới.','Stop mongod on this VPS and rejoin with a fresh data directory.'),fields:[['host','Endpoint'],['role',dataLabel('Vai trò mới','New role')]]},
  remove_member:{title:uiText("Gỡ node khỏi cụm"),profile:true,note:uiText("Giữ nguyên dữ liệu trên máy đích. Gỡ bằng reconfig thông thường và kiểm tra quorum trước khi áp dụng."),fields:[['host',uiText("Node cần gỡ"),'','text','',true]]},
  member_options:{title:uiText("Sửa cấu hình member"),profile:true,fields:[['host',uiText("Địa chỉ node"),'','text','',true],['priority',uiText("Ưu tiên bầu primary"),1,'number',uiText("Giá trị cao hơn được ưu tiên. Đặt 0 để node không thể làm primary.")],['votes','Votes',1,'select','',false,[0,1]],['hidden','Hidden member',false,'checkbox',uiText("Hidden hoặc votes=0 cần priority=0."),true]]},
  step_down:{title:'Step down Primary',profile:true,note:uiText("Cần secondary sẵn sàng. Thao tác chờ primary mới, không force bầu chọn."),fields:[]},
  create_user:{title:uiText("Tạo user MongoDB"),profile:true,fields:[['username','Username',''],['database','Database','app'],['password',uiText("Mật khẩu"),'','password',uiText("Ít nhất 12 ký tự."),true],['role',uiText("Quyền"),'readWrite','select',uiText("Root / backup / clusterMonitor phải dùng database admin."),true,['readWrite','read','dbAdmin','backup','clusterMonitor','root']]]},
  password:{title:uiText("Đổi mật khẩu user"),profile:true,fields:[['username','Username',''],['database',uiText("Database xác thực"),'admin'],['password',uiText("Mật khẩu mới"),'','password',dataLabel('Hồ sơ kết nối được cập nhật khi đổi mật khẩu thành công.','The connection profile is updated after a successful password change.'),true]]},
  drop_user:{title:uiText("Xóa user"),profile:true,fields:[['username','Username',''],['database',uiText("Database xác thực"),'admin']]},
  write_concern:{title:uiText("Cấu hình Write Concern"),profile:true,note:uiText("w=1 chỉ yêu cầu primary xác nhận. Với Primary-Secondary-Arbiter, majority cần cả hai node dữ liệu để xác nhận ghi."),fields:[['w',uiText("Mức xác nhận ghi"),'majority','select','',true,[{value:'majority',label:'majority'},{value:'1',label:'w = 1'}]]]},
  backup:{title:uiText("Tạo bản backup"),host:true,profile:true,note:dataLabel('Chọn phạm vi dữ liệu của cụm đang mở.','Choose the data to copy from the current cluster.'),fields:[]},
  backups:{title:uiText("Danh sách backup trên máy"),host:true,fields:[]},
  restore:{title:uiText("Restore bản backup"),host:true,profile:true,note:dataLabel('Chọn máy chứa bản sao và cụm nhận dữ liệu.','Choose the archive host and the destination cluster.'),fields:[['backup_id',uiText("ID bản backup"),'','text',uiText("Lấy từ danh sách backup trên máy."),true],['drop',uiText("Xóa collection đích trước khi restore"),false,'checkbox',uiText("Mặc định tắt. Bật có thể mất dữ liệu hiện tại."),true]]},
  drop_database:{title:uiText("Xóa database"),profile:true,note:uiText("Xóa dữ liệu vĩnh viễn trên cụm được chọn. Không áp dụng cho admin, local hoặc config."),fields:[['database',uiText("Tên database"),'','text','',true]]},
  upgrade_check:{title:uiText("Kiểm tra nâng cấp lên 9.0"),profile:true,note:uiText("Chỉ đọc phiên bản, FCV và trạng thái cụm. Không thay binary hoặc nâng FCV."),fields:[]},
};
schemas.sync_backup={...schemas.backup,title:dataLabel('Đồng bộ ngay','Sync now'),note:dataLabel('Tạo backup mới từ nguồn, sau đó restore một lần sang cụm đích.','Create a fresh source backup, then restore it once to the destination.'),fields:[...schemas.backup.fields,schemas.restore.fields[1]]};
schemas.backup_schedule={...schemas.backup,title:dataLabel('Lịch backup','Backup schedule'),note:dataLabel('Lịch chạy theo giờ Việt Nam (UTC+7) khi dịch vụ MongoDB Manager hoạt động.','Runs on Vietnam time (UTC+7) while MongoDB Manager is running.')};
function backupScope(form,cluster,overrides){
  const picker=form.querySelector('[data-database-list]'),scope=form.elements.scope;
  const collections=form.querySelector('[data-collection-list]');
  const initial=overrides.collections||(overrides.collection?[overrides.collection]:[]);
  let names=[],request=0;
  function chooseDatabase(){
    const single=scope.value==='collections';
    picker.hidden=!single&&scope.value!=='selected';
    collections.hidden=!single;
    if(!single)request++;
    picker.innerHTML=single?field('collection_database','Database',overrides.databases?.[0]||'','select','',true,[{value:'',label:dataLabel('Chọn database','Choose a database')},...names]):
      names.map(name=>`<label><input type="checkbox" name="selected_database" value="${esc(name)}" ${overrides.databases?.includes(name)?'checked':''}> ${esc(name)}</label>`).join('');
    if(single)loadCollections();
  }
  async function loadCollections(){
    const db=form.elements.collection_database.value,seq=++request;
    collections.textContent=db?uiText('Đang tải…'):'';
    if(!db)return;
    try{
      const rows=demo?[{name:'users'},{name:'events'}]:await api('/profiles/'+cluster.id+'/query/namespaces?database='+encodeURIComponent(db));
      if(seq!==request||!form.isConnected)return;
      collections.innerHTML=rows.map(({name})=>`<label><input type="checkbox" name="selected_collection" value="${esc(name)}" ${db===overrides.databases?.[0]&&initial.includes(name)?'checked':''}> ${esc(name)}</label>`).join('')||dataLabel('Database chưa có collection.','No collections in this database.');
    }catch(e){if(seq===request)collections.textContent=e.message;}
  }
  scope.value=initial.length?'collections':overrides.application_only?'apps':overrides.databases?.length?'selected':overrides.application_only===false?'all':'apps';
  scope.onchange=chooseDatabase;
  picker.onchange=e=>{if(e.target.name==='collection_database')loadCollections();};
  chooseDatabase();
  const source=demo?Promise.resolve(['application','analytics','admin'].map(name=>({name}))):api('/profiles/'+cluster.id+'/query/databases');
  source.then(rows=>{names=rows.map(row=>row.name);chooseDatabase();}).catch(e=>{picker.textContent=e.message;});

}
schemas.ubuntu_upgrade={title:dataLabel('Nâng cấp Ubuntu','Upgrade Ubuntu'),host:true,
  note:dataLabel('Máy đã cài MongoDB sẽ dùng phiên bản đang chạy để kiểm tra kho gói.','For existing installations, package checks use the running MongoDB version.'),
  fields:[['target',dataLabel('Ubuntu đích','Target Ubuntu'),'auto','select','',false,
      []]]};
schemas.provision={...schemas.setup,title:uiText("Cài và tạo cụm mới"),note:uiText("Dành cho VPS chưa có cụm ở port này. Kiểm tra đích, cài package nếu thiếu, tạo keyfile và replica set, lưu hồ sơ và xác minh kết nối."),fields:[['series',uiText("Nhánh MongoDB"),'','select','',true,[]],...schemas.setup.fields]};
schemas.join_fresh={title:uiText("Kiểm tra VPS và thêm member"),host:true,profile:true,note:uiText("Mọi chế độ đều kiểm tra SSH, phiên bản và keyfile. Chế độ cài mới cần port/thư mục trống hoặc instance manager khớp cấu hình để tái sử dụng. Manager dùng SSH của primary hiện tại để đọc keyfile. Tài khoản MongoDB cần quyền getCmdLineOpts và quản lý cụm. Không tạo replica set/user riêng trên Secondary. Cụm TLS cần chuẩn bị node riêng."),fields:[['mode',uiText("Cách xử lý VPS"),'prepare','select',uiText("Cài khi thiếu; instance manager khớp cấu hình được tái sử dụng. Không tự cài đè dữ liệu."),true,[{value:'prepare',label:uiText("Kiểm tra và cài/cấu hình instance manager")},{value:'prepared',label:uiText("Kiểm tra node đã cấu hình sẵn (giữ nguyên)")},{value:'replace_empty',label:dataLabel('Dừng standalone trống để dùng lại cổng (giữ dữ liệu cũ)','Stop empty standalone to reuse its port (preserve old data)')}]],['arbiter',uiText("Thêm dưới vai trò Arbiter"),false,'checkbox',uiText("Bỏ chọn để thêm Secondary."),true],['target_keyfile',uiText("Keyfile trên node đã chuẩn bị"),'','text',uiText("Chỉ bắt buộc với chế độ node đã chuẩn bị; nhập đường dẫn thực tế để đối chiếu nguồn."),true],['instance',uiText("Tên instance mới"),'secondary'],['port','Port MongoDB',27017,'number'],['advertise',uiText("Địa chỉ MongoDB của VPS mới (tùy chọn)"),'','text',uiText("Để trống để dùng địa chỉ MongoDB đã lưu hoặc IP public của VPS cùng cổng đã chọn."),true],['bind_ip','Bind address','0.0.0.0','text',uiText("Kiểm tra firewall giữa các VPS trước khi chạy."),true]]};
for(const schema of [schemas.add_member,schemas.join_fresh]){
  schema.fields.push(['votes','Votes',1,'select','',false,[0,1]],
    ['priority',uiText("Ưu tiên bầu primary"),1,'number',uiText("Giá trị cao hơn được ưu tiên. Đặt 0 để node không thể làm primary.")]);
}
let releaseOptions, releaseTime=0;
async function loadReleaseOptions(){
  if(releaseOptions&&Date.now()-releaseTime<3600000)return;
  const data=await api('/releases');
  const series=Object.keys(data.supported).sort((a,b)=>b.localeCompare(a,undefined,{numeric:true}));
  releaseOptions={...data,series};releaseTime=Date.now()-(data.cached?3540000:0);
}
async function openAction(action,overrides={}){
  if(['mongo_upgrade','ubuntu_upgrade','install','provision'].includes(action)){
    try{await loadReleaseOptions();}catch(error){toast(error.message,true);return;}
    const branch=schemas[action].fields.find(f=>f[0]==='series');
    if(branch){branch[6]=releaseOptions.series;branch[2]=releaseOptions.series[0];}
    if(action==='ubuntu_upgrade'){
      const targets=Object.keys(releaseOptions.lts);
      schemas[action].fields.find(f=>f[0]==='target')[6]=[
        {value:'auto',label:overrides.series?dataLabel('Tự chọn LTS tương thích','Compatible LTS'):dataLabel('Bản LTS kế tiếp','Next LTS release')},
        ...Object.entries(releaseOptions.lts).filter(([code])=>targets.includes(code)).map(([value,v])=>({value,label:'Ubuntu '+v+' LTS'}))];
    }
  }
  jobId=null;const schema=schemas[action];
  if(schema.profile&&!profile()){toast(uiText("Thêm hồ sơ MongoDB trước khi thực hiện."));showRecord('profiles');return;}
  const cluster=profile();
  const joining=action==='join_fresh';
  if(joining&&!overrides.machine_id){
    pendingJoinOptions=overrides;
    pendingJoin=true;
    showRecord('machines',null,{ssh_auth:'password'});
    return;
  }
  const memberEndpoints=new Set(currentStatus?.members?.length?currentStatus.members.map(m=>m.host):cluster?.seeds||[]);
  const hosts=machines().filter(m=>joining
    ?m.mode==='ssh'&&(!m.profile_id||m.profile_id===cluster.id)&&!memberEndpoints.has(m.mongo_endpoint)
    :cluster?m.profile_id===cluster.id:!m.profile_id);
  const selectedHost=joining&&hosts.find(m=>m.id===overrides.machine_id);
  if(selectedHost)overrides={votes:selectedHost.votes??1,priority:selectedHost.priority??1,...overrides};
  if(joining&&overrides.machine_id&&!selectedHost){
    toast(dataLabel('VPS đã chọn không còn đủ điều kiện để thêm. Kiểm tra danh sách thành viên và hồ sơ SSH.','The selected VPS is no longer eligible. Check replica set membership and its SSH profile.'),true);
    return;
  }
  if(overrides.combined&&!hosts.some(m=>m.id===overrides.machine_id)){
    toast(dataLabel('Máy đã chọn không thuộc hồ sơ hiện tại. Chọn lại máy để nâng.','The selected server is outside the current profile. Select the server again.'),true);return;
  }
  if(schema.host&&!hosts.length){toast(uiText("Thêm máy thực thi trước khi thực hiện."));showRecord('machines');return;}
  actionContext={action,overrides,profileId:schema.profile?cluster.id:''};
  let fields='';
  const upgrade=['ubuntu_upgrade','mongo_upgrade'].includes(action);
  const upgradeHost=upgrade&&hosts.find(m=>m.id===overrides.machine_id);
  if(upgradeHost){
    fields+=`<input type="hidden" name="machine_id" value="${esc(upgradeHost.id)}"><div class="upgrade-host"><strong>${esc(upgradeHost.name)}</strong><span>${esc(upgradeHost.mongo_endpoint||upgradeHost.host||'localhost')}</span></div>`;
  }else if(selectedHost){
    fields+=`<input type="hidden" name="machine_id" value="${esc(selectedHost.id)}"><div class="field wide"><span>${dataLabel('VPS sẽ thêm vào cụm','VPS to add')}</span><strong>${esc(selectedHost.name)} · ${esc(selectedHost.host)}</strong></div>`;
  }else if(schema.host){
    fields+=field('machine_id',schema.hostLabel||uiText("Máy thực thi"),
      overrides.machine_id||hosts[0].id,'select','',true,
      hosts.map(m=>({value:m.id,label:`${m.name} · ${m.mode==='local'?'Local':`${m.user}@${m.host}`} · ${m.service}`})));
  }
  if(action==='backup_schedule'){
    const presets=[{value:'0 * * * *',label:dataLabel('Mỗi giờ','Hourly')},
      {value:'0 2 * * *',label:dataLabel('Hằng ngày lúc 02:00','Daily at 02:00')},
      {value:'0 2 * * 1',label:dataLabel('Thứ Hai lúc 02:00','Mondays at 02:00')}];
    const expression=overrides.cron||'0 2 * * *';
    fields+=field('frequency',dataLabel('Tần suất','Frequency'),presets.some(p=>p.value===expression)?expression:'custom','select','',false,
      [...presets,{value:'custom',label:dataLabel('Tùy chỉnh','Custom')}]);
    fields+=field('cron',dataLabel('Biểu thức cron','Cron expression'),overrides.cron||'0 2 * * *','text',dataLabel('0 2 * * * chạy hằng ngày lúc 02:00. */30 * * * * chạy mỗi 30 phút.','0 2 * * * runs daily at 02:00. */30 * * * * runs every 30 minutes.'),true);
  }
  if(['backup','sync_backup','backup_schedule'].includes(action)){
    fields+=field('scope',dataLabel('Phạm vi backup','Backup scope'),'all','select','',true,[
      {value:'apps',label:dataLabel('Tất cả database ứng dụng','All application databases')},{value:'all',label:dataLabel('Toàn bộ cụm','Entire cluster')},{value:'selected',label:dataLabel('Chọn database','Select databases')},{value:'collections',label:dataLabel('Chọn collection trong database','Select collections in a database')}]);
    fields+='<div class="backup-database-list wide" data-database-list></div><div class="backup-database-list wide" data-collection-list hidden></div>';
  }
  if(action==='restore'||action==='sync_backup'){
    const targets=profiles().filter(p=>action==='restore'||p.id!==cluster.id);
    if(!targets.length){
      modal(dataLabel('Đồng bộ sang cụm khác','Sync to another cluster'),`<div class="modal-body">${dataLabel('Đồng bộ tạo backup mới rồi khôi phục sang một cụm MongoDB độc lập. Các node primary và secondary trong cùng replica set đã tự đồng bộ với nhau. Thêm kết nối tới cụm nhận dữ liệu để tiếp tục.','Sync creates a new backup and restores it to a separate MongoDB cluster. Members of one replica set already replicate automatically. Add the receiving cluster to continue.')}</div>`,button(uiText('Đóng'),'modal-close')+button(dataLabel('Thêm cụm đích','Add destination cluster'),'profile-new','','primary'));return;
    }
    const options=targets.map(p=>({label:p.name,value:p.id}));
    if(action==='restore'){
      for(const m of machines().filter(m=>m.mongo_endpoint&&targets.some(p=>p.id===m.profile_id))){
        options.push({value:'machine:'+m.id,label:m.name+' · '+m.mongo_endpoint});
      }
      options.unshift({value:'',label:dataLabel('Chọn cụm hoặc máy nhận dữ liệu','Choose a destination cluster or server')});
    }
    fields+=field('destination_id',action==='restore'?dataLabel('Restore vào','Restore to'):dataLabel('Cụm đích','Destination cluster'),overrides.destination_id||(action==='restore'?'':targets[0].id),'select',action==='restore'?dataLabel('Chọn cụm để tự tìm primary, hoặc chọn máy để ghi trực tiếp vào MongoDB trên máy đó. Primary sẽ sao chép thay đổi sang các secondary.','Choose a cluster for primary discovery or a server for a direct write. A primary replicates changes to its secondaries.'):'',true,options);
  }
  for(const entry of schema.fields){const f=[...entry];if(overrides[f[0]]!==undefined)f[2]=overrides[f[0]];fields+=field(...f);}
  const heading=overrides.combined?(action==='ubuntu_upgrade'?dataLabel('Nâng cả hai · 1/2 · Ubuntu','Upgrade both · 1/2 · Ubuntu'):dataLabel('Nâng cả hai · 2/2 · MongoDB','Upgrade both · 2/2 · MongoDB')):schema.title;
  modal(heading,`<form id="action-form" class="${upgrade?'upgrade-form':''}"><div class="modal-body">${schema.fields.some(f=>f[0]==='series')&&releaseOptions?.cached?`<div class="callout">${dataLabel('Đang dùng danh mục đã lưu do nguồn phát hành tạm thời không truy cập được.','Showing saved releases because the official feed is unavailable.')}</div>`:''}${schema.note&&!upgrade?`<div class="callout">${schema.note}</div>`:''}<div class="form-grid">${fields}</div><div id="form-error"></div></div><div class="modal-footer">${['add_member','join_fresh'].includes(action)?button(dataLabel('Cấu hình SSH cho VPS','Configure VPS SSH'),'node-ssh-new','server'):''}${action==='add_member'?button(dataLabel('Tự lấy keyfile từ Primary','Copy keyfile from Primary'),'node-auto-keyfile','key'):''}${action==='install'?button(dataLabel('Kiểm tra Ubuntu','Check Ubuntu'),'ubuntu-from-install'):''}${action==='backup_schedule'&&currentSchedule()?.enabled?button(dataLabel('Tạm dừng lịch','Pause schedule'),'schedule-pause'):''}${button(uiText("Hủy"),'modal-close')}<button class="button primary" type="submit">${upgrade?dataLabel('Xem kế hoạch nâng','Preview upgrade') : action==='backup_schedule'?dataLabel('Lưu và bật lịch','Save and enable'):uiText("Xem lại thao tác →")}</button></div></form>`);
  const form=$('#action-form');
  if(form.elements.frequency){
    const {frequency,cron}=form.elements;
    frequency.onchange=()=>{if(frequency.value==='custom')cron.focus();else cron.value=frequency.value;};
    cron.oninput=()=>{frequency.value=Array.from(frequency.options).some(o=>o.value===cron.value)?cron.value:'custom';};
  }
  if(action==='restore'){
    form.elements.destination_id.required=true;
    const machine=form.elements.machine_id;
    for(const option of Array.from(machine.options))if(option.value!==machine.value)option.remove();
    machine.closest('label').querySelector('span').textContent=dataLabel('Máy đang lưu bản backup','Backup storage host');
    const id=form.elements.backup_id;
    if(overrides.backup_id)id.readOnly=true;
    else{
      const picker=document.createElement('select');picker.name='backup_id';picker.required=true;
      picker.add(new Option(dataLabel('Chọn bản backup','Select a backup'),''));
      for(const b of backupItems)picker.add(new Option(formatDate(b.time)+' · '+b.id,b.id));
      id.replaceWith(picker);
    }
  }
  if(form.elements.scope)backupScope(form,cluster,overrides);
  if(joining){
    const {machine_id,advertise,port}=form.elements;
    advertise.required=false;
    let previous=null;
    const fillEndpoint=()=>{
      const endpoint=hosts.find(m=>m.id===machine_id.value)?.mongo_endpoint||'';
      if(!advertise.value||advertise.value===previous){
        advertise.value=endpoint;
        const savedPort=endpoint.match(/:(\d+)$/)?.[1];
        if(savedPort)port.value=savedPort;
      }
      previous=endpoint;
    };
    fillEndpoint();
    machine_id.addEventListener('change',fillEndpoint);
  }
  const fill=()=>{
    if(form.elements.arbiter && form.elements.votes){
      const {arbiter,votes,priority}=form.elements;
      if(arbiter.checked)votes.value='1';
      votes.disabled=arbiter.checked;
      priority.readOnly=arbiter.checked||votes.value==='0';
      if(priority.readOnly)priority.value='0';
      priority.min=0;priority.max=1000;
    }
    if(form.elements.target_keyfile){const prepared=form.elements.mode?.value==='prepared';form.elements.target_keyfile.closest('.field').hidden=!prepared;form.elements.target_keyfile.disabled=!prepared;form.elements.target_keyfile.required=prepared;}
  };fill();form.addEventListener('change',fill);
}
function formError(error){const target=$('#form-error');if(target)target.innerHTML=`<div class="form-error">${esc(error.message||error)}</div>`;else toast(error.message||error,true);}
async function followBusyJob(error){
  if(!error.busy)return false;
  let id=error.activeJob;
  if(!id){
    const latest=await api('/state');
    id=latest.jobs.find(j=>['queued','running'].includes(j.status))?.id;
  }
  if(!id)return false;
  await openJob(id);
  return true;
}
function activeUpgrade(id,action){
  if(!demo)return api('/machines/'+encodeURIComponent(id)+'/active-upgrade?action='+action);
  const kinds=action==='mongo_upgrade'?['mongo_upgrade','arbiter_upgrade']:['ubuntu_upgrade'];
  return demoJobs.find(j=>j.machine_id===id&&kinds.includes(j.action)&&['running','queued'].includes(j.status));
}
function combinedKey(machineId){return 'upgrade-both:'+demo+':'+machineId;}
function rememberCombinedJob(job){
  if(actionContext?.overrides.combined && job.action==='mongo_upgrade')localStorage.removeItem(combinedKey(actionContext.overrides.machine_id));
  if(actionContext?.overrides.combined && job.action==='ubuntu_upgrade')
    localStorage.setItem(combinedKey(job.machine_id),job.id);
}
function nextMongoButton(machineId){
  return button(dataLabel('Tiếp tục nâng MongoDB','Continue to MongoDB'),'combined-mongo','db','primary',`data-id="${esc(machineId)}"`);
}
async function runPlan(action,plan,confirmation){
  if(demo){
    const result=action==='backups'?[{id:'a'.repeat(32),time:new Date().toISOString(),source:'Production',database:uiText("Tất cả"),size:2.4*1024**3,verified_restore:false}]:{demo:true,message:uiText("Mô phỏng hoàn tất. Không thay đổi máy chủ.")};
    if(action==='ubuntu_upgrade')Object.assign(result,{series:plan.ubuntu.series,version:plan.ubuntu.version});
    if(action==='backups')for(const item of result)Object.assign(item,{source_id:profile()?.id,machine_id:actionContext.overrides.machine_id,databases:[]});
    const job={id:'demo-'+Date.now(),action:action,label:plan.label,target:plan.target,status:'succeeded',created_at:new Date().toISOString(),events:[{time:new Date().toISOString(),message:uiText("Đây là tác vụ minh họa, không thực thi lệnh.")}],result};
    if(action==='ubuntu_upgrade')Object.assign(job,{machine_id:actionContext.overrides.machine_id,series:plan.ubuntu.series});
    rememberCombinedJob(job);demoJobs.unshift(job);if(job.action==='backups')backupItems=result;showJob(job);updateChrome();return;
  }
  const payload={plan_id:plan.id,confirmation};
  if(['mongo_upgrade','ubuntu_upgrade'].includes(action))payload.backup_confirmed=!!$('#modal [name=backup_confirmed]')?.checked;
  try{const job=await api('/jobs',{method:'POST',body:JSON.stringify(payload)});rememberCombinedJob(job);showJob(job);}
  catch(error){if(await followBusyJob(error))return;throw error;}
  await refreshState();
}
async function runMachineRead(machineId, action){
  const machine=machines().find(item=>item.id===machineId);
  if(!machine)return;
  const plan=demo?{label:schemas[action].title,target:machine.name,params:{},notices:[],confirmation:''}:
    await api('/plans',{method:'POST',body:JSON.stringify({action,machine_id:machineId,profile_id:'',params:{}})});
  await runPlan(action,plan,'');
}
async function followPackageActivity(plan,id=actionContext.overrides.machine_id,initial=null){
  if(!plan.package_wait)return;
  const panel=document.createElement('div');
  panel.className='callout';
  panel.setAttribute('role','status');
  $('#modal .modal-body').append(panel);
  while(panel.isConnected&&$('#modal').open){
    try{
      const state=initial||await api('/machines/'+encodeURIComponent(id)+'/package-activity');
      initial=null;
      panel.textContent=[state.processes.join(', ')||dataLabel('APT đang rảnh','APT idle'),
        state.pending?dataLabel('Còn gói chờ cấu hình','Package configuration pending'):'',
        state.detail].filter(Boolean).join(' · ');
      if(!state.pending&&!state.processes.length)break;
    }catch(error){panel.textContent=error.message;}
    await new Promise(resolve=>setTimeout(resolve,5000));
  }
}
function showPreview(plan){
  previewPlan=plan;
  const schema=schemas[actionContext.action];
  const labels={application_only:dataLabel('Tất cả database ứng dụng','All application databases'),databases:dataLabel('Database nguồn','Source databases'),destination_id:dataLabel('Cụm đích','Destination cluster'),...Object.fromEntries(schema.fields.map(f=>[f[0],f[1]]))};
  if(plan.already_current){
    if(actionContext.overrides.combined)localStorage.removeItem(combinedKey(actionContext.overrides.machine_id));
    modal(dataLabel('MongoDB đã cập nhật','MongoDB is up to date'),`<div class="modal-body"><strong>${esc(plan.target)}</strong><p>${esc(dataLabel('Phiên bản đã cài khớp với bản mới nhất trong kho của nhánh đã chọn.','The installed version matches the latest package in this series.'))}</p><p>${plan.notices.map(esc).join('<br>')}</p></div>`,button(uiText('Đóng'),'modal-close'));
    return;
  }
  if(plan.install_blocked){
    modal(uiText('Cài MongoDB'),`<div class="modal-body"><strong>${esc(plan.target)}</strong><p>${esc(plan.install_blocked)}</p></div>`,
      button(uiText('Quay lại'),'action-back')+button(dataLabel('Quản lý Ubuntu','Manage Ubuntu'),'ubuntu-install-plan','server','primary'));
    return;
  }
  if(plan.ubuntu){
    const i=plan.ubuntu;
    const back=button(uiText('Quay lại'),'action-back');
    const confirm=!i.blocked&&i.path.length&&i.version?field('backup_confirmed',dataLabel('Tôi đã có bản sao lưu có thể phục hồi','I have a recoverable backup'),false,'checkbox'):'';
    const rows=[
      [dataLabel('Ubuntu hiện tại','Current Ubuntu'),i.os],
      [dataLabel('Kiến trúc CPU','CPU architecture'),i.arch],
      ...(i.version||i.series?[[i.version?dataLabel('MongoDB đã cài','Installed MongoDB'):dataLabel('MongoDB dự định cài','Planned MongoDB'),i.version||i.series]]:[]),
      ...(i.service_state?[[dataLabel('Trạng thái dịch vụ','Service status'),i.service_state]]:[]),
      [dataLabel('Lộ trình Ubuntu','Ubuntu release path'),i.route||dataLabel('Chưa xác minh','Unverified')]];
    const summary=rows.map(([label,value])=>`<div class="review-row"><span>${label}</span><strong>${esc(value)}</strong></div>`).join('');
    modal(dataLabel('Ubuntu trên ','Ubuntu on ')+esc(plan.target),`<div class="modal-body"><div class="review-params">${summary}</div><div class="callout">${plan.notices.map(esc).join('<br>')}</div>${confirm}<div id="form-error"></div></div>`,
      back+(!i.blocked&&!i.path.length&&actionContext.overrides.combined?nextMongoButton(actionContext.overrides.machine_id):!i.blocked&&i.path.length?button(dataLabel('Nâng Ubuntu','Upgrade Ubuntu'),'action-apply','arrow','primary'):button(uiText('Đóng'),'modal-close')));
    followPackageActivity(plan);
    return;
  }
  if(actionContext.action==='convert_role'){
    const {host,role}=plan.params;
    const secondary=role==='SECONDARY';
    const source=secondary?'ARBITER':'SECONDARY';
    const title=dataLabel('Xác nhận chuyển sang ','Confirm conversion to ')+role;
    const details=secondary
      ?dataLabel('Secondary sẽ đồng bộ lại dữ liệu của cụm từ đầu.','The secondary will perform a full initial sync.')
      :dataLabel('Arbiter chỉ bỏ phiếu. Cụm sẽ có ít hơn một bản sao dữ liệu đang hoạt động.','The arbiter only votes. The cluster will have one fewer active data copy.');
    const note=dataLabel('Manager sẽ kiểm tra quorum, dừng mongod trên VPS này và giữ thư mục dữ liệu cũ.','Manager will check quorum, stop mongod on this VPS and retain the old data directory.');
    const submit=demo?uiText('Chạy mô phỏng'):dataLabel('Chuyển sang ','Convert to ')+role;
    modal(title,`<div class="modal-body"><div class="review-params"><div class="review-row"><span>${uiText('Endpoint')}</span><strong>${esc(host)}</strong></div><div class="review-row"><span>${esc(plan.target)}</span><strong>${source} → ${esc(role)}</strong></div></div><p>${note} ${details}</p><div id="form-error"></div></div>`,
      button(uiText('Hủy'),'modal-close')+button(submit,'action-apply','check','primary'));
    return;
  }
  let electionPicker='';
  if(actionContext.action==='step_down'){
    const options=[{value:'',label:uiText("Để MongoDB tự bầu")}];
    for(const m of currentStatus?.members||[]){
      if(m.state==='SECONDARY'&&m.health===1&&m.votes===1&&m.priority>0){
        const key=JSON.stringify(['mongo-manager-member',demo,actionContext.profileId,m.id,m.host]);
        const name=machines().find(v=>v.profile_id===actionContext.profileId&&v.mongo_endpoint===m.host)?.name||localStorage.getItem(key);
        options.push({value:m.host,label:name?name+' · '+m.host:m.host});
      }
    }
    electionPicker=field('next_primary',uiText("Primary mong muốn"),'','select',uiText("Chỉ secondary khỏe có Votes = 1 và Ưu tiên > 0 mới xuất hiện."),true,options);
  }
  const repairNotice=actionContext.action==='service'&&plan.params.operation==='repair_keyfile'
    ? '<div class="callout">'+esc(dataLabel('Manager sẽ đặt quyền keyfile thành 0400 rồi khởi động dịch vụ đang dừng.','Manager will set the keyfile mode to 0400 and start the stopped service.'))+'</div>'
    : '';
  modal(uiText("Xác nhận thao tác"),`<div class="modal-body${electionPicker?' step-down-review':''}"><div class="review-params"><div class="review-row"><span>${uiText("Tác vụ")}</span><span>${esc(plan.label)}</span></div><div class="review-row"><span>${uiText("Máy / cụm đích")}</span><span>${esc(plan.target)}</span></div>${Object.entries(plan.params).map(([k,v])=>`<div class="review-row"><span>${esc(labels[k]||k)}</span><span>${esc(k==='operation'&&actionContext.action==='service'?(schema.fields[0][6].find(option=>option.value===v)?.label||v):k==='destination_id'?(profiles().find(p=>p.id===v)?.name||v):k==='databases'?(v.join(', ')||uiText('Tất cả')):typeof v==='boolean'?(v?uiText("Bật"):uiText("Tắt")):v||'—')}</span></div>`).join('')}</div>${actionContext.action==='mongo_upgrade'?field('backup_confirmed',dataLabel('Tôi đã có bản sao lưu có thể phục hồi','I have a recoverable backup'),false,'checkbox'):''}${electionPicker}${repairNotice}${plan.notices.map(n=>`<div class="callout">${esc(n)}</div>`).join('')}${demo?("<div class=\"callout neutral\">"+uiText("Đây là mô phỏng. Không có lệnh nào được gửi đến máy chủ.")+"</div>"):''}<div id="form-error"></div></div>`,(['remove_member','step_down','arbiter_upgrade'].includes(actionContext.action)?button(uiText("Hủy"),'modal-close'):button(uiText("Quay lại"),'action-back'))+button(demo?uiText("Chạy mô phỏng"):uiText("Thực hiện"),'action-apply','check','primary'));
  followPackageActivity(plan);
}
function sshKeyButton(id){
  return button(dataLabel('Xác minh khóa SSH','Verify SSH host key'),'ssh-key','shield','',`data-id="${esc(id)}"`);
}
async function verifySSHKey(id){
  const fromCatalog=currentRoute==='backup'&&selectedArchiveHost()?.id===id;
  const path='/machines/'+id+'/ssh-key';
  const key=await api(path);
  jobId=null;
  modal(dataLabel('Xác minh khóa SSH','Verify SSH host key'),
    `<div class="modal-body"><strong>${esc(key.host)} · ${esc(key.port)}</strong><p>${dataLabel('So sánh fingerprint bên dưới với khóa cùng loại trong console VPS.','Compare this fingerprint with the same key type in the VPS console.')}</p><p><code>${esc(key.algorithm)} ${esc(key.fingerprint)}</code></p><div id="form-error"></div></div>`,
    button(uiText('Hủy'),'modal-close')+button(dataLabel('Khớp, lưu khóa','Fingerprint matches, save'),'ssh-key-save','check','primary'));
  const save=$('[data-act="ssh-key-save"]');
  save.onclick=async()=>{
    save.disabled=true;
    try{
      await api(path,{method:'POST',body:JSON.stringify({fingerprint:key.fingerprint})});
      if(save.isConnected){
        $('#modal').close();
        if(fromCatalog&&currentRoute==='backup'&&selectedArchiveHost()?.id===id)await render();
        else await runMachineRead(id,'preflight');
      }
    }
    catch(error){if(save.isConnected){formError(error);save.disabled=false;}else toast(error.message,true);}
  };
}
function showJob(job){
  const terminal=$('#modal .terminal');
  const sameJob=jobId===job.id&&terminal&&$('#modal').open;
  const top=sameJob?terminal.scrollTop:0;
  const follow=!sameJob||terminal.scrollHeight-terminal.clientHeight-top<8;
  const revision=JSON.stringify([job.id,job.status,job.events.length,job.events.at(-1),job.upgrade_progress,['ubuntu_upgrade','mongo_upgrade','arbiter_upgrade'].includes(job.action)&&job.status==='running'?Math.floor(Date.now()/10000):0]);
  if(sameJob&&terminal.dataset.revision===revision)return;
  jobId=job.id;
  if(job.status==='succeeded'&&job.action==='backup'&&job.result?.archives&&job.profile_id===profile()?.id){
    const archive=job.result;
    backupItems=[archive,...backupItems.filter(b=>b.id!==archive.id&&b.machine_id===archive.machine_id)].sort((a,b)=>b.time.localeCompare(a.time));
  }
  if(job.action==='backups'&&job.status==='succeeded'&&job.profile_id===profile()?.id&&Array.isArray(job.result)){
    catalogLoading=false;catalogError='';backupItems=job.result;
    backupListedHost={name:job.target,id:job.machine_id||job.result[0]?.machine_id};
    modal(esc(job.label),`<div class="modal-body"><p>${esc(job.target)} · ${job.result.length} backup</p>${backupCatalog()}</div>`,button(uiText('Đóng'),'modal-close'));
    return;
  }
  const running=['queued','running'].includes(job.status);
  let timing='';
  if(['ubuntu_upgrade','mongo_upgrade','arbiter_upgrade'].includes(job.action)){
    const status=job.upgrade_progress||{};
    const duration=seconds=>Math.floor(seconds/60)+'m '+Math.floor(seconds%60)+'s';
    const elapsed=Math.max(0,((Date.parse(job.finished_at)||Date.now())-Date.parse(job.started_at||job.created_at))/1000);
    const rows=[[dataLabel('Đã chạy','Elapsed'),duration(elapsed)]];
    if(running){
      const stale=status.checked_at && Date.now()/1000-status.checked_at>35;
      if(stale)rows.push([dataLabel('Trạng thái theo dõi','Monitor status'),dataLabel('Đang chờ dữ liệu mới từ VPS','Waiting for an update from the host')]);
      rows.push([dataLabel('Chặng hiện tại','Current phase'),status.phase||job.events.at(-1)?.message||'…']);
      if(status.bytes_total)rows.push([status.package||'APT',Math.floor(status.bytes_done/1000000)+' / '+Math.ceil(status.bytes_total/1000000)+' MB']);
      if(status.packages_total)rows.push([status.downloading?dataLabel('Đã tải','Downloaded'):status.configuring?dataLabel('Bước giải nén và cấu hình','Unpack and configure steps'):dataLabel('Đã cấu hình','Configured'),status.packages_done+' / '+status.packages_total]);
      rows.push([dataLabel('Còn lại (ước tính)','Estimated remaining'),!stale&&Number.isFinite(status.eta_seconds)?duration(status.eta_seconds)+' · '+(status.downloading?dataLabel('tải gói Ubuntu','Ubuntu downloads'):status.packages_total?dataLabel('cấu hình gói','package configuration'):dataLabel('gói đang tải','current package')):dataLabel('Chưa đủ dữ liệu','Not enough data')]);
      if(status.detail)rows.push([dataLabel('Mới nhất','Latest'),status.detail]);
      if(status.checked_at)rows.push([dataLabel('Kiểm tra lúc','Last checked'),new Date(status.checked_at*1000).toLocaleTimeString()]);
    }
    timing='<div class="review-params">'+rows.map(([key,val])=>`<div class="review-row"><span>${esc(key)}</span><strong>${esc(val)}</strong></div>`).join('')+'</div>';
  }
  let footer=button(uiText('Đóng'),'modal-close');
  if(job.action==='preflight'&&job.status==='failed'&&job.error?.includes('Chưa có khóa của'))footer+=sshKeyButton(job.machine_id);
  if(job.action==='ubuntu_upgrade'&&!running){
    const action=job.status==='failed'?'ubuntu-verify':'ubuntu-recheck';
    const attrs=`data-job="${esc(job.id)}" data-id="${esc(job.machine_id)}"`;
    if(job.status==='succeeded'&&localStorage.getItem(combinedKey(job.machine_id))===job.id)footer+=nextMongoButton(job.machine_id);
    footer+=button(dataLabel('Kiểm tra lại Ubuntu','Check Ubuntu again'),action,'','',attrs);
  }
  modal(esc(job.label),`${running?'<div class="progress-track"><i></i></div>':''}<div class="modal-body job-detail"><div class="actions">${jobBadge(job)}<span class="mono">${esc(job.target)}</span></div>${timing}${job.error?errorBox(job.error):''}<pre class="terminal">${job.events.map(e=>`<small>${esc(formatDate(e.time))}</small>  ${esc(e.message)}`).join('\n')||uiText("Đang chờ tác vụ…")}</pre>${job.result?`<div><div class="notice-label">${uiText("Kết quả")}</div><pre>${esc(typeof job.result==='string'?job.result:JSON.stringify(job.result,null,2))}</pre></div>`:''}</div>`,footer);
  const log=$('#modal .terminal');
  log.dataset.revision=revision;
  log.scrollTop=follow?log.scrollHeight:top;
}
async function openJob(id){
  const job=demo?demoJobs.find(j=>j.id===id):await api('/jobs/'+id);
  if(!job){toast(uiText("Không tìm thấy tác vụ."),true);return;}
  showJob(job);
}
async function runDiagnostics(){
  if(!profile()){showRecord('profiles');return;}
  const data=demo?[{host:'203.0.113.10:27017',ok:true,role:'PRIMARY'},{host:'203.0.113.11:27017',ok:true,role:'SECONDARY'},{host:'203.0.113.12:27017',ok:true,role:'SECONDARY'}]:await api(`/profiles/${profile().id}/query/diagnostics`);
  modal(uiText("Kết quả chẩn đoán"),`<div class="modal-body"><div class="callout neutral">${uiText("Kiểm tra từ máy đang chạy web. Kết quả không thay thế kiểm tra mạng hai chiều giữa các member.")}</div>${table(['ENDPOINT',uiText("KẾT QUẢ"),(uiText("VAI TRÒ")+" / GHI CHÚ")],data.map(r=>`<tr><td class="mono">${esc(r.host)}</td><td>${badge(r.ok?uiText("Kết nối được"):uiText("Thất bại"),r.ok?'success':'error')}</td><td>${esc(r.ok?r.role:r.error)}${r.note?'<br><small>'+esc(r.note)+'</small>':''}</td></tr>`))}</div>`,button(uiText("Đóng"),'modal-close'));
}
async function saveRecord(form){
  let data=Object.fromEntries(new FormData(form));const ctx=recordContext;
  if(ctx.kind==='profiles'){data=profileFormData(form);data.machines=clusterSSHData();}
  else {
    data.name=data.name.trim();
    data.votes=Number(form.elements.votes.value);
    data.priority=Number(data.priority);
    data.auto_name=!data.name;
    data.name||=form.elements.name.dataset.fallback;
    data.profile_id=ctx.profileId;
    data.port=Number(data.port||22);
    data.ssh_password||=null;
    const address=data.mongo_host.trim().replace(/^\[|\]$/g,'');
    const mongoPort=Number(data.mongo_port||27017);
    if(!Number.isInteger(mongoPort)||mongoPort<1||mongoPort>65535){
      throw new Error(dataLabel('Cổng MongoDB phải từ 1 đến 65535.','MongoDB port must be between 1 and 65535.'));
    }
    data.mongo_endpoint=address?`${address.includes(':')?'['+address+']':address}:${mongoPort}`:'';
    delete data.mongo_host;
    delete data.mongo_port;
    if(data.mode==='ssh'){
      data.host=data.host.trim()||address;
      if(!data.host)throw new Error(dataLabel('Nhập IP public hoặc địa chỉ SSH của VPS.','Enter the public IP or SSH address of the VPS.'));
    }
  }
  if(demo){toast(uiText("Hồ sơ xem thử không được lưu. Chuyển sang dữ liệu thật để kết nối."));$('#modal').close();return;}
  const adopted=ctx.kind==='profiles'?await api('/profiles/adopt',{method:'POST',body:JSON.stringify({...data,record_id:ctx.id||''})}):null;
  const saved=adopted?adopted.profile:await api('/'+ctx.kind+(ctx.id?'/'+ctx.id:''),{method:ctx.id?'PUT':'POST',body:JSON.stringify(data)});
  if(ctx.kind==='profiles'){if(!profile()){selected=saved.id;localStorage.setItem('mongo-manager-profile',selected);}currentStatus=null;}
  const next=ctx.kind==='machines'&&pendingJoin?pendingJoinOptions:null;
  if(next){pendingJoin=false;pendingJoinOptions={};}
  if(!next)$('#modal').close();
  toast(uiText("Đã lưu hồ sơ."));
  await refreshState();
  await render();
  if(next){
    const {action='join_fresh',...options}=next;
    Object.assign(options,{votes:data.votes,priority:data.priority});
    if(action==='add_member')openAction(action,{...options,host:saved.mongo_endpoint||options.host});
    else {
      if(saved.mongo_endpoint&&!options.advertise){
        const port=saved.mongo_endpoint.match(/:(\d+)$/)?.[1];
        if(port)options.port=Number(port);
      }
      openAction(action,{...options,machine_id:saved.id});
    }
  }
}
document.addEventListener('submit',async event=>{
  if(event.target.id==='manager-admin-form'){
    event.preventDefault();
    const form=event.target, submit=form.querySelector('button[type=submit]');
    const {repeat,...body}=Object.fromEntries(new FormData(form));
    submit.disabled=true;
    try{
      if(repeat!==body.password)throw new Error(dataLabel('Hai mật khẩu chưa khớp.','Passwords do not match.'));
      body.password ||= body.current_password;
      const updated=await api('/auth/admin',{method:'POST',body:JSON.stringify(body)});
      $('#modal').close();showLogin(dataLabel('Đã lưu tài khoản. Vui lòng đăng nhập lại.','Login saved. Please sign in again.'));showRecoveryCode(updated.recovery_code);
    }catch(error){form.querySelector('[role=alert]').textContent=error.message;}
    finally{submit.disabled=false;}
    return;
  }
  if(!['record-form','action-form'].includes(event.target.id))return;
  event.preventDefault();const submit=$('button[type="submit"]',event.target);submit.disabled=true;
  try{
    if(event.target.id==='record-form')await saveRecord(event.target);
    else{
      const schema=schemas[actionContext.action];const data=Object.fromEntries(new FormData(event.target));const params={};
      for(const f of schema.fields){params[f[0]]=f[3]==='checkbox'?event.target.elements[f[0]].checked:(f[3]==='number'||f[0]==='votes')?Number(event.target.elements[f[0]].value):data[f[0]];}
      if(actionContext.action==='ubuntu_upgrade'&&actionContext.overrides.series)params.series=actionContext.overrides.series;
      if(data.scope){
        params.application_only=data.scope==='apps';
        params.databases=data.scope==='selected'?new FormData(event.target).getAll('selected_database'):[];
        if(data.scope==='collections'){
          params.databases=[data.collection_database];
          params.collections=new FormData(event.target).getAll('selected_collection');
          if(!data.collection_database||!params.collections.length)throw Error(dataLabel('Chọn database và ít nhất một collection.','Choose a database and at least one collection.'));
        }
        if(data.scope==='selected'&&!params.databases.length)throw Error(dataLabel('Chọn ít nhất một database.','Select at least one database.'));
      }
      if(actionContext.action==='restore'&&data.destination_id?.startsWith('machine:'))params.destination_machine_id=data.destination_id.slice(8);
      else if(data.destination_id)params.destination_id=data.destination_id;
      actionContext.overrides={...actionContext.overrides,...params,machine_id:data.machine_id};
      if(params.collection&&!params.database&&!params.databases?.length)throw new Error(uiText("Chọn database trước khi chỉ định collection."));
      if(actionContext.action==='backup_schedule'){
        const id=actionContext.profileId;
        const body={cron:data.cron.trim(),machine_id:data.machine_id,params};
        if(!body.cron)throw Error(dataLabel('Nhập biểu thức cron.','Enter a cron expression.'));
        if(demo)demoSchedules.set(id,{...body,id,enabled:true});
        else {
          await api('/profiles/'+id+'/backup-schedule',{method:'PUT',body:JSON.stringify(body)});
          await refreshState();
        }
        $('#modal').close();await render();return;
      }
      const payload={action:actionContext.action,profile_id:actionContext.profileId,machine_id:data.machine_id||'',params};
      let plan;
      if(demo){const target=schema.host?machines().find(m=>m.id===data.machine_id).name:profile().name;plan={id:'demo',label:schema.title,target,params:{...params,...('password'in params?{password:'••••••••'}:{})},notices:[],confirmation:['preflight','logs','backups','upgrade_check'].includes(actionContext.action)?'':target};}
      else plan=await api('/plans',{method:'POST',body:JSON.stringify(payload)});
      if(!event.target.isConnected||!$('#modal').open)return;
      if(demo&&actionContext.action==='ubuntu_upgrade'){
        const route=releaseOptions.lts, releases=Object.keys(route), start=releases.indexOf('jammy');
        const end=params.target==='auto'?(params.series?start:Math.min(start+1,releases.length-1)):releases.indexOf(params.target);
        const blocked=end<start||(params.series&&!releaseOptions.supported[params.series]?.includes(releases[end]));
        const path=blocked?[]:releases.slice(start+1,end+1);
        plan.ubuntu={os:'Ubuntu 22.04 LTS',arch:'amd64',series:params.series,version:'',path,blocked,
          route:['22.04',...path.map(c=>route[c])].join(' → ')};
        plan.notices=[blocked?dataLabel('Đích không tương thích.','Incompatible target.'):uiText('Đây là tác vụ minh họa, không thực thi lệnh.')];
      }
      showPreview(plan);
    }
  }catch(error){formError(error);}finally{submit.disabled=false;}
});
document.addEventListener('click',async event=>{
  const target=event.target.closest('[data-act]');if(!target)return;
  const act=target.dataset.act;
  try{
    if(act==='copy-recovery'){
      const code=target.closest('.recovery-copy').querySelector('code');
      try{
        await navigator.clipboard.writeText(code.textContent);
        target.textContent=dataLabel('Đã sao chép','Copied');
      }catch{
        const range=document.createRange();range.selectNodeContents(code);
        const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);
        target.textContent=dataLabel('Nhấn Ctrl+C hoặc ⌘C','Press Ctrl+C or ⌘C');
      }
      return;
    }
    if(act==='recovery-help'){showRecoveryHelp();return;}
    if(act==='forgot-password'){showRecoveryForm();return;}
    if(act==='back-login'){showLogin();return;}
    if(act==='manager-admin'){
      const auth=await api('/auth/status');
      const t=dataLabel;
      const fields=field('username',t('Tên đăng nhập','Username'),auth.username||'','text','',true)
        +(auth.enabled?field('current_password',t('Mật khẩu hiện tại','Current password'),'','password','',true):'')
        +field('password',t('Mật khẩu mới','New password'),'','password',t('Để trống để giữ mật khẩu hiện tại.','Leave blank to keep the current password.'))
        +field('repeat',t('Nhập lại mật khẩu mới','Repeat new password'),'','password');
      modal(t('Sửa tài khoản quản trị','Edit administrator account'),`<form id="manager-admin-form">
        <div class="modal-body"><div class="form-grid">${fields}</div><p role="alert" class="form-error"></p></div>
        <div class="modal-footer">${button(uiText('Hủy'),'modal-close')}<button class="button primary" type="submit">${t('Lưu và đăng nhập lại','Save and sign in again')}</button></div>
      </form>`);
      return;
    }
    if(act==='arbiter-upgrade'||act==='ubuntu-upgrade-required'){
      const machine=machines().find(m=>m.id===target.dataset.id);
      if(!machine||(machine.profile_id||'')!==(profile()?.id||''))return;
      const ubuntu=act==='ubuntu-upgrade-required';
      const params=ubuntu?{series:target.dataset.series,target:target.dataset.target}:{version:target.dataset.version};
      const context={action:ubuntu?'ubuntu_upgrade':'arbiter_upgrade',profileId:machine.profile_id||'',overrides:{machine_id:machine.id,...params}};
      const label=target.textContent;
      target.disabled=true;
      target.textContent=dataLabel('Đang kiểm tra…','Checking…');
      try{
        const plan=await api('/plans',{method:'POST',body:JSON.stringify({action:context.action,profile_id:context.profileId,machine_id:machine.id,params})});
        if(target.isConnected){actionContext=context;showPreview(plan);}
      }finally{if(target.isConnected)target.textContent=label;}
      return;
    }
    if(act==='both-upgrade-open'||act==='combined-mongo'){
      const id=target.dataset.id||$('[name="compatibility_host"]').value;
      const mongo=await activeUpgrade(id,'mongo_upgrade');
      if(mongo){showJob(mongo);return;}
      const ubuntu=await activeUpgrade(id,'ubuntu_upgrade');
      if(ubuntu){localStorage.setItem(combinedKey(id),ubuntu.id);showJob(ubuntu);return;}
      if(act==='combined-mongo'){await openAction('mongo_upgrade',{machine_id:id,combined:true});return;}
      const saved=localStorage.getItem(combinedKey(id));
      if(saved){
        const job=demo?demoJobs.find(j=>j.id===saved):await api('/jobs/'+encodeURIComponent(saved));
        if(job?.machine_id===id&&job.action==='ubuntu_upgrade'){showJob(job);return;}
        localStorage.removeItem(combinedKey(id));
      }
      await openAction('ubuntu_upgrade',{machine_id:id,combined:true});return;
    }
    if(act==='mongo-upgrade-open'||act==='ubuntu-open'){
      const selector=$('[name="compatibility_host"]');
      const id=selector.value, action=act==='ubuntu-open'?'ubuntu_upgrade':'mongo_upgrade';
      let job=await activeUpgrade(id,action);
      if(!job&&action==='mongo_upgrade')job=await activeUpgrade(id,'ubuntu_upgrade');
      if(!selector.isConnected||selector.value!==id)return;
      if(job){showJob(job);return;}
      const overrides={machine_id:id};
      if(action==='mongo_upgrade'){
        const report=$('#compatibility-report').firstElementChild?.compatibility;
        overrides.series=report?.series||releaseOptions?.series[0];
      }
      if(!demo){
        const state=await api('/machines/'+encodeURIComponent(id)+'/package-activity');
        if(!selector.isConnected||selector.value!==id)return;
        if(state.pending||state.processes.length){
          modal(dataLabel('Theo dõi APT/dpkg','APT/dpkg activity'),`<div class="modal-body"><strong>${esc(machines().find(m=>m.id===id)?.name||id)}</strong></div>`,
            button(uiText('Đóng'),'modal-close')+button(dataLabel('Xem kế hoạch nâng','Preview upgrade'),'package-plan','arrow','primary'));
          $('#modal [data-act=package-plan]').onclick=()=>openAction(action,overrides);
          followPackageActivity({package_wait:true},id,state);return;
        }
      }
      await openAction(action,overrides);
      return;
    }
    if(act==='compatibility-refresh'){await loadCompatibility();return;}
    if(act==='ubuntu-install-plan'){openAction('ubuntu_upgrade',actionContext.overrides);return;}
    if(act==='ubuntu-from-install'){
      const form=$('#action-form');
      openAction('ubuntu_upgrade',{machine_id:form.elements.machine_id.value,series:form.elements.series.value});return;
    }
    if(act==='ubuntu-verify'){
      if(!demo){
        const current=await api('/machines/'+encodeURIComponent(target.dataset.id)+'/active-upgrade?action=ubuntu_upgrade');
        if(current){showJob(current);return;}
      }
      const attrs=`data-job="${esc(target.dataset.job)}" data-id="${esc(target.dataset.id)}" data-series="${esc(target.dataset.series)}"`;
      modal(dataLabel('Tiếp tục tác vụ Ubuntu','Resume Ubuntu upgrade'),
        `<div class="modal-body">${dataLabel('Manager sẽ đọc trạng thái trên VPS và tiếp tục các bước còn lại của chặng đã xác nhận. Máy có thể khởi động lại.','Manager will check the host and resume the remaining confirmed steps. The server may reboot.')}</div>`,
        button(uiText('Hủy'),'modal-close')+button(uiText('Tiếp tục'),'ubuntu-verify-apply','','primary',attrs));return;
    }
    if(act==='ubuntu-verify-apply'){
      target.disabled=true;
      try{showJob(await api('/jobs/'+target.dataset.job+'/verify-ubuntu',{method:'POST',body:'{}'}));}
      catch(error){if(await followBusyJob(error))return;toast(error.message,true);openAction('ubuntu_upgrade',{machine_id:target.dataset.id,series:target.dataset.series});}
      return;
    }
    if(act==='ubuntu-recheck'){openAction('ubuntu_upgrade',{machine_id:target.dataset.id,series:target.dataset.series});return;}
    if(act==='password-toggle'){event.preventDefault();await togglePassword(target);return;}
    if(act==='ssh-key'){await verifySSHKey(target.dataset.id);return;}
    if(['preflight','logs'].includes(act)&&target.dataset.id){target.disabled=true;await runMachineRead(target.dataset.id,act);return;}
    if(act==='ssh-bulk'){openBulkSSH();return;}
    if(act==='logout'){await api('/auth/logout',{method:'POST',body:'{}'});showLogin();return;}
    if(act==='sidebar'){
      if(narrowSidebar.matches)document.body.classList.toggle('nav-open');
      else localStorage.setItem('mongo-sidebar-hidden',document.body.classList.toggle('sidebar-hidden')?'1':'0');
      syncSidebarToggle();return;
    }
    if(act==='demo'){demo=!demo;localStorage.setItem('mongo-manager-demo',demo);currentStatus=null;statusError='';backupItems=[];backupListedHost=null;await refreshState();await render();return;}
    if(act==='refresh'){await refreshState();await render();return;}
    if(act==='modal-close'){pendingJoin=false;pendingJoinOptions={};$('#modal').close();jobId=null;return;}
    if(act==='cluster-ssh-save'){const attached=clusterSSHData();if(!attached.length)throw new Error(uiText("Thêm ít nhất một VPS SSH trước khi lưu."));if(demo){toast(uiText("Chế độ minh họa không lưu hồ sơ."));return;}if(recordContext.id)attached.forEach(a=>a.machine.profile_id=recordContext.id);await api('/machines/batch',{method:'POST',body:JSON.stringify(attached)});$('#modal').close();await refreshState();await render();toast(uiText("Đã lưu SSH. Bấm Kiểm tra ở VPS để đọc môi trường trước khi xử lý."));return;}
    if(act==='cluster-ssh-add'){addClusterSSH();return;}
    if(act==='cluster-ssh-remove'){target.closest('.cluster-ssh-row').remove();return;}
    if(act==='profile-probe'){await probeProfileForm();return;}
    if(act==='profile-new'){showRecord('profiles');return;}
    if(act==='profile-open'){backupItems=[];backupListedHost=null;jobId=null;pendingJoin=false;pendingJoinOptions={};selected=target.dataset.id;if(!demo)localStorage.setItem('mongo-manager-profile',selected);currentStatus=null;location.hash='overview';await render();return;}
    if(act==='profile-edit'){const p=profiles().find(p=>p.id===target.dataset.id)||profile();if(p)showRecord('profiles',p);return;}
    if(act==='member-ssh'){
      const endpoint=target.dataset.host;
      const host=endpoint.slice(0,endpoint.lastIndexOf(':')).replace(/^\[|\]$/g,'');
      const name=target.closest('tr').querySelector('strong').textContent;
      showRecord('machines');
      const fields=$('#record-form').elements;
      fields.name.dataset.fallback=name;
      if(!/^mongo-\d+$/.test(name))fields.name.value=name;
      fields.host.value=host;
      fields.mongo_endpoint.value=endpoint;
      fields.ssh_auth.value='password';
      syncSSHFields();
      return;
    }
    if(act==='machine-new'){showRecord('machines');return;}
    if(act==='node-add'){showNodeAdd();return;}
    if(act==='prepared-node'){openAction('add_member');return;}
    if(act==='add-arbiter'){showNodeAdd(true);return;}
    if(act==='node-ssh-new'||act==='node-auto-keyfile'){
      const form=$('#action-form');
      const action=actionContext.action;
      const options={...actionContext.overrides};
      for(const [name,,,type] of schemas[action].fields){
        const input=form.elements[name];
        if(input)options[name]=type==='checkbox'?input.checked:input.value;
      }
      const endpoint=(options.host||options.advertise||'').trim();
      const sshHost=endpoint.startsWith('[')?endpoint.slice(1,endpoint.indexOf(']')):endpoint.split(':')[0];
      const normalized=endpoint&&endpoint===sshHost?endpoint+':27017':endpoint;
      const existing=machines().find(m=>m.profile_id===profile()?.id&&m.mode==='ssh'&&
        ((normalized&&m.mongo_endpoint===normalized)||(!normalized&&m.id===form.elements.machine_id?.value)));
      if(act==='node-auto-keyfile'){
        const port=normalized.match(/:(\d+)$/)?.[1];
        pendingJoinOptions={action:'join_fresh',arbiter:options.arbiter,votes:options.votes,priority:options.priority,
          ...(port?{port:Number(port),advertise:normalized}:{})};
        if(existing){openAction('join_fresh',{...pendingJoinOptions,machine_id:existing.id});pendingJoinOptions={};return;}
        delete pendingJoinOptions.advertise;
      }else{
        pendingJoinOptions={...options,action};
      }
      pendingJoin=true;
      showRecord('machines',existing||null,{mongo_endpoint:normalized,ssh_auth:'password'});
      return;
    }
    if(act==='machine-hostname'){
      if(demo){toast(dataLabel('Chọn một VPS thật để đọc hostname qua SSH.','Select a real VPS to read its SSH hostname.'));return;}
      const pid=profile()?.id||'',hosts=workspaceSSHHosts();
      if(hostnameBatches.has(pid)||!hosts.length)return;
      hostnameBatches.add(pid);
      target.disabled=true;
      target.textContent=dataLabel('Đang lấy tên…','Reading hostnames…');
      let results;
      try{
        results=await Promise.allSettled(hosts.map(m=>api('/machines/'+m.id+'/hostname',{method:'POST'})));
      }finally{hostnameBatches.delete(pid);}
      await refreshState();
      if(currentRoute==='machines'&&(profile()?.id||'')===pid&&!demo){
        await render();
        const failures=results.flatMap((r,i)=>r.status==='rejected'?[hosts[i].host+' · '+r.reason.message]:[]);
        const summary=dataLabel('Đã cập nhật tên','Hostnames updated')+` · ${hosts.length-failures.length}/${hosts.length} VPS`;
        if(failures.length)modal(summary,`<div class="modal-body">${failures.map(errorBox).join('')}</div>`,button(uiText('Đóng'),'modal-close'));
        else toast(summary);
      }
      return;
    }
    if(act==='machine-edit'){showRecord('machines',machines().find(m=>m.id===target.dataset.id));return;}
    if(act==='record-delete'||act==='profile-delete'||act==='machine-delete'){
      const ctx=act==='profile-delete'?{kind:'profiles',id:target.dataset.id||profile()?.id}:act==='machine-delete'?{kind:'machines',id:target.dataset.id}:recordContext;
      if(!ctx.id)return;
      const label=ctx.kind==='profiles'?profiles().find(p=>p.id===ctx.id)?.name:machines().find(m=>m.id===ctx.id)?.name;
      if(demo){toast(uiText("Không xóa hồ sơ minh họa."));return;}
      if(!await confirmProfileDeletion(label||ctx.id,ctx.kind==='machines'?ctx.id:null))return;
      await api('/'+ctx.kind+'/'+ctx.id,{method:'DELETE'});$('#modal').close();currentStatus=null;await refreshState();await render();return;
    }
    if(act==='connection'){
      const p=profile();if(!p)return;
      const connection=`mongodb://${p.username?encodeURIComponent(p.username)+':<PASSWORD>@':''}${p.seeds.join(',')}/?authSource=${encodeURIComponent(p.auth_db)}${p.replica_set?'&replicaSet='+encodeURIComponent(p.replica_set):''}${p.tls?'&tls=true':''}`;
      modal(uiText("Chuỗi kết nối ứng dụng"),`<div class="modal-body"><p>Thay <code>&lt;PASSWORD&gt;</code> ${uiText("bằng mật khẩu đã URL-encode. Chuỗi này không hiển thị mật khẩu đã lưu.")}</p><pre>${esc(connection)}</pre></div>`,button(uiText("Đóng"),'modal-close'));return;
    }
    if(act==='help'){
      modal(uiText("Bắt đầu sử dụng"),`<div class="modal-body"><ol class="step-list"><li><strong>${uiText("Kết nối MongoDB đang chạy")}</strong>${uiText("Thêm hồ sơ với seed, replica set và tài khoản có đủ quyền. Không cần SSH để xem cụm hoặc quản lý user.")}</li><li><strong>${uiText("Quản lý VPS")}</strong>${uiText("Thêm máy SSH bằng mật khẩu hoặc key/agent. Kiểm tra known_hosts và sudo -n trước; chạy Kiểm tra môi trường.")}</li><li><strong>${uiText("Cài một VPS mới")}</strong>${uiText("Cài package trước, sau đó tạo replica set một node. Setup thành công sẽ tạo hồ sơ kết nối tự động.")}</li><li><strong>${uiText("Theo dõi tác vụ")}</strong>${uiText("Xem trước đích, xác nhận rồi chạy. Mở Lịch sử tác vụ để xem tiến độ và kết quả.")}</li></ol><div class="section-title"></div><div class="callout neutral">${uiText("Web lắng nghe trên localhost. Nếu chạy trên VPS, dùng SSH tunnel:")}<br><code>ssh -L 8765:127.0.0.1:8765 user@vps</code></div></div>`,button(uiText("Đã hiểu"),'modal-close'));return;
    }
    if(act==='job-open'){await openJob(target.dataset.id);return;}
    if(act==='diagnose'){target.disabled=true;await runDiagnostics();return;}
    if(act==='collections'){await openDataExplorer(target.dataset.db);return;}
    if(['member-remove','member-convert','step-down'].includes(act)){
      target.disabled=true;
      const cluster=profile();
      if(!cluster){showRecord('profiles');return;}
      const action={'step-down':'step_down','member-remove':'remove_member','member-convert':'convert_role'}[act];
      const params=action==='step_down'?{}:{host:target.dataset.host};
      if(action==='convert_role')params.role=target.dataset.role;
      const plan=demo?{label:schemas[action].title,target:cluster.name,params,notices:[schemas[action].note],confirmation:cluster.name}:
        await api('/plans',{method:'POST',body:JSON.stringify({action,profile_id:cluster.id,params})});
      actionContext={action,profileId:cluster.id,overrides:params};
      showPreview(plan);
      return;
    }
    if(act==='action-back'){openAction(actionContext.action,actionContext.overrides);return;}
    if(act==='action-apply'){
      const backup=$('#modal [name=backup_confirmed]');
      if(backup&&!backup.checked){formError(dataLabel('Xác nhận bản sao lưu trước khi nâng cấp.','Confirm the backup before upgrading.'));return;}
      target.disabled=true;
      let plan=previewPlan;
      const host=$('#modal [name="next_primary"]')?.value;
      if(actionContext.action==='step_down'&&host){
        const params={host};
        plan=demo?{...plan,params}:await api('/plans',{method:'POST',body:JSON.stringify({action:'step_down',profile_id:actionContext.profileId,params})});
      }
      await runPlan(actionContext.action,plan,plan.confirmation);return;
    }
    if(act==='remember-user'){
      const {db,user}=target.dataset,path=userPasswordPath(db,user);
      modal(dataLabel('Lưu mật khẩu','Save password'),`<form id="remember-user-form"><div class="modal-body"><p>${esc(db)} / ${esc(user)}</p>${field('password',uiText('Mật khẩu'),'','password')}<div id="form-error"></div></div><div class="modal-footer">${button(uiText('Hủy'),'modal-close')}<button class="button primary" type="submit">${dataLabel('Kiểm tra và lưu','Verify and save')}</button></div></form>`);
      const form=$('#remember-user-form');form.elements.password.required=true;
      form.onsubmit=async e=>{
        e.preventDefault();const save=form.querySelector('[type=submit]');save.disabled=true;
        try{
          if(demo)throw Error(dataLabel('Chuyển sang dữ liệu thật để lưu mật khẩu.','Switch to live data to save passwords.'));
          await api(path,{method:'PUT',body:JSON.stringify({username:user,password:form.elements.password.value})});
          if(form.isConnected){$('#modal').close();await render();}
        }catch(error){if(form.isConnected)formError(error);}finally{save.disabled=false;}
      };
      return;
    }
    if(act==='backup-schedule'){
      const s=currentSchedule();
      openAction('backup_schedule',{...s?.params,cron:s?.cron,machine_id:s?.machine_id||selectedArchiveHost()?.id});return;
    }
    if(act==='schedule-pause'){
      const id=actionContext.profileId;
      if(demo)demoSchedules.get(id).enabled=false;
      else {await api('/profiles/'+id+'/backup-schedule/pause',{method:'POST'});await refreshState();}
      $('#modal').close();await render();return;
    }
    if(act==='backup-delete'){
      const id=target.dataset.backup, machineId=target.dataset.id, pid=profile().id;
      const host=machines().find(m=>m.id===machineId && m.profile_id===pid);
      if(!host)return;
      jobId=null;
      modal(dataLabel('Xóa bản backup?','Delete backup?'),`<div class="modal-body"><p>${dataLabel('Xóa vĩnh viễn bản backup sau khỏi','Permanently delete this backup from')} <strong>${esc(host.name)}</strong>?</p><code>${esc(id)}</code><div id="form-error"></div></div>`,
        button(uiText('Hủy'),'modal-close')+'<button type="button" class="button danger" data-delete-archive>'+dataLabel('Xóa backup','Delete backup')+'</button>');
      const submit=$('[data-delete-archive]');
      submit.onclick=async()=>{
        submit.disabled=true;
        try{
          if(demo)deletedDemoBackups.add(machineId+'/'+id);
          else await api('/profiles/'+pid+'/machines/'+machineId+'/backups/'+id,{method:'DELETE'});
          backupItems=backupItems.filter(b=>!(b.id===id && (b.machine_id||machineId)===machineId));
          if(submit.isConnected)$('#modal').close();
          if(currentRoute==='backup')await render();
          toast(dataLabel('Đã xóa bản backup.','Backup deleted.'));
        }catch(e){if(submit.isConnected){formError(e);submit.disabled=false;}else toast(e.message,true);}
      };
      return;
    }
    if(act==='backup-preview'){await openBackupPreview(target.dataset.id,target.dataset.backup);return;}
    if(act==='backup-repeat'){
      const previous=backupItems.find(b=>b.id===target.dataset.backup);
      if(previous?.source_id===profile()?.id)openAction('backup',{machine_id:previous.machine_id,application_only:previous.application_only||false,databases:previous.databases,collections:previous.collections?.length?previous.collections:undefined,collection:previous.collection});
      return;
    }
    const mapping={'provision':'provision','join-fresh':'join_fresh','setup':'setup','install':'install','preflight':'preflight','logs':'logs','service':'service','add-member':'add_member','mongo-arbiter':'add_member','ssh-arbiter':'join_fresh','member-edit':'member_options','write-concern':'write_concern','user-new':'create_user','user-password':'password','user-drop':'drop_user','database-drop':'drop_database','backup-new':'backup','backup-sync':'sync_backup','backups-list':'backups','restore':'restore','upgrade-check':'upgrade_check'};
    if(mapping[act]){
      if(act==='restore'&&!target.dataset.backup&&!backupItems.length){toast(dataLabel('Chọn máy có bản backup trong danh sách phía trên.','Select a host containing backups in the catalog above.'));return;}
      const extra=['backup-new','restore'].includes(act)&&backupListedHost?.id?{machine_id:backupListedHost.id}:{};if(target.dataset.id)extra.machine_id=target.dataset.id;if(target.dataset.host)extra.host=target.dataset.host;
      if(target.dataset.db)extra.database=target.dataset.db;if(target.dataset.user)extra.username=target.dataset.user;
      if(target.dataset.backup)extra.backup_id=target.dataset.backup;
      if(act==='mongo-arbiter'||act==='ssh-arbiter')extra.arbiter=true;
      if(act==='member-edit'){const member=currentStatus?.members.find(m=>m.host===extra.host);if(member)Object.assign(extra,{priority:member.priority,votes:member.votes,hidden:!!member.hidden});}
      openAction(mapping[act],extra);
    }
  }catch(error){formError(error);}finally{target.disabled=false;}
});
document.addEventListener('change',e=>{
  if(e.target.name==='compatibility_series'){$('#compatibility-report').dataset.series=e.target.value;loadCompatibility();}
  if(e.target.name==='compatibility_host'){delete $('#compatibility-report').dataset.series;history.replaceState(null,'','#upgrade?machine='+encodeURIComponent(e.target.value));loadCompatibility();}
  if(e.target.id==='archive-host'){
    localStorage.setItem(archiveHostKey(),e.target.value);
    render();
  }
});
$('#profile-select').addEventListener('change',async event=>{backupItems=[];backupListedHost=null;jobId=null;pendingJoin=false;pendingJoinOptions={};selected=event.target.value;if(currentRoute==='upgrade')history.replaceState(null,'','#upgrade');if(!demo)localStorage.setItem('mongo-manager-profile',selected);currentStatus=null;statusError='';await render();});
$('#modal').addEventListener('close',()=>{if(!$('#modal').open)$('#modal-content').replaceChildren();jobId=null;if(currentRoute==='backup')$('#content').innerHTML=backupPage();});
window.addEventListener('hashchange',()=>{if(!document.body.classList.contains('auth-pending'))render();});
let pollBusy=false, scheduleChecked=0;
async function poll(){
  if(pollBusy)return;
  pollBusy=true;
  try{await pollWorkspace();}finally{pollBusy=false;}
}
async function pollWorkspace(){
  if(demo||document.body.classList.contains('auth-pending'))return;
  try{
    const due=currentSchedule()?.next_run;
    if(due && Date.parse(due)<=Date.now() && ['backup','jobs'].includes(currentRoute) && !document.hidden && !$('#modal').open && Date.now()-scheduleChecked>=10000){
      scheduleChecked=Date.now();await refreshState();await render();return;
    }
    if(jobId){const job=await api('/jobs/'+jobId);if($('#modal').open&&jobId===job.id){showJob(job);if(!['queued','running'].includes(job.status)){jobId=null;await refreshState();await render();return;}}}
    else {
      const pending=jobs().filter(j=>['queued','running'].includes(j.status));
      if(pending.length){
        await refreshState();
        if(jobs().some(j=>pending.some(old=>old.id===j.id)&&!['queued','running'].includes(j.status))){await render();return;}
        if(currentRoute==='jobs')$('#content').innerHTML=jobsPage();
      }
    }
  }catch(error){toast(error.message,true);}
  await refreshTopology();
}
async function refreshTopology(){
  if(topologyBusy||$('.member-name-input')||demo||document.hidden||$('#modal').open||!['overview','machines','replica'].includes(currentRoute)||!profile()||Date.now()-topologyChecked<10000||document.body.classList.contains('auth-pending'))return;
  topologyBusy=true;topologyChecked=Date.now();const requestId=renderId,pid=profile().id,route=currentRoute;
  try{const data=await api(`/profiles/${pid}/status`);if(requestId!==renderId||demo||profile()?.id!==pid||document.body.classList.contains('auth-pending'))return;currentStatus=data;statusError='';const saved=state.profiles.find(p=>p.id===pid);if(saved&&data.seeds)saved.seeds=data.seeds;}
  catch(error){if(requestId!==renderId||demo||profile()?.id!==pid||document.body.classList.contains('auth-pending'))return;currentStatus=null;statusError=error.message;}
  finally{topologyBusy=false;}
  if(requestId===renderId&&!$('.member-name-input')&&!$('#modal').open&&!document.body.classList.contains('auth-pending')){
    $('#content').innerHTML=({overview,machines:machinePage,replica:replicaPage,upgrade:upgradePage})[route]();
    if(route==='machines'){
      const endpoint=new URLSearchParams(location.hash.split('?')[1]).get('member');
      for(const row of document.querySelectorAll('tr[data-node]'))row.classList.toggle('selected-node',row.dataset.node===endpoint);
    }
  }
}
function recoveryCopy(value){
  return `<div class="recovery-copy"><code>${esc(value)}</code>${button(dataLabel('Sao chép','Copy'),'copy-recovery','','small')}</div>`;
}
function showRecoveryCode(code){
  const t=dataLabel;
  modal(t('Lưu mã khôi phục','Save your recovery code'),`<div class="modal-body"><p>${t('Lưu mã này để đặt lại mật khẩu quản trị. Mã chỉ hiển thị lần này.','Save this code to reset your administrator password. It is displayed only once.')}</p>${recoveryCopy(code)}</div>`,button(uiText('Đóng'),'modal-close'));
}
const recoveryViewKey='mongo-manager-recovery-view';
function showRecoveryHelp(savedMethod='Terminal'){
  const t=dataLabel;
  const methods={Terminal:'bash start-web.sh',PM2:'pm2 restart mongodb-manager',systemd:'sudo systemctl restart mongodb-manager'};
  modal(t('Hướng dẫn lấy lại mật khẩu','Password recovery guide'),`<div class="modal-body recovery-help">
    <div class="recovery-methods" role="group" aria-label="${t('Cách chạy Manager','Launch method')}">${Object.keys(methods).map(name=>`<button type="button" class="button small" data-method="${name}" aria-pressed="${name==='Terminal'}">${name}</button>`).join('')}</div>
    <div id="recovery-steps"></div></div>`,button(uiText('Đóng'),'modal-close'));
  function updateSteps(method){
    localStorage.setItem(recoveryViewKey,method);
    const systemd=method==='systemd';
    const command=systemd?'sudo -u mongodb-manager /opt/mongodb-manager/.venv/bin/python -m web.manage --data-dir /var/lib/mongodb-manager-web':'.venv/bin/python -m web.manage';
    const location=systemd?t('Trên VPS dùng service systemd đi kèm Manager.','On the VPS using the bundled systemd service.'):t('Mở terminal tại thư mục source của Manager.','Open a terminal in the Manager source directory.');
    $('#recovery-steps').innerHTML=`<section><h3>${t('1. Đặt mật khẩu mới','1. Set a new password')}</h3><p>${location} ${t('Thay USERNAME bằng tên đăng nhập, rồi nhập mật khẩu mới hai lần.','Replace USERNAME with your login and enter the new password twice.')}</p>
      ${recoveryCopy(command+' create-admin --username USERNAME --replace')}
      ${systemd?'':`<small>${t('Nếu dùng MONGO_MANAGER_DATA riêng, đặt biến này như khi chạy Manager.','If you use a custom MONGO_MANAGER_DATA, set it as you do when starting Manager.')}</small>`}
      </section><section><h3>${t('2. Khởi động lại Manager','2. Restart Manager')}</h3><p>${method==='Terminal'?t('Dừng Manager bằng Ctrl+C, chạy lệnh dưới đây rồi đăng nhập lại.','Stop Manager with Ctrl+C, run this command, then sign in again.'):t('Chạy lệnh sau rồi đăng nhập bằng mật khẩu mới.','Run this command, then sign in with the new password.')}</p>
      ${recoveryCopy(methods[method])}</section>`;
  }
  const buttons=document.querySelectorAll('.recovery-methods button');
  const selectMethod=method=>{
    for(const option of buttons)option.setAttribute('aria-pressed',String(option.dataset.method===method));
    updateSteps(method);
  };
  for(const item of buttons)item.onclick=()=>selectMethod(item.dataset.method);
  selectMethod(Object.hasOwn(methods,savedMethod)?savedMethod:'Terminal');
  $('#modal').addEventListener('close',()=>{
    if($('#recovery-form'))localStorage.setItem(recoveryViewKey,'form');
  },{once:true});
}
function showRecoveryForm(){
  localStorage.setItem(recoveryViewKey,'form');
  const t=dataLabel;
  $('#login-root').innerHTML=`<form id="recovery-form" class="login-card recovery-card">
    <div class="recovery-heading"><div class="brand"><span class="brandmark">m</span>MongoDB Manager</div>${languagePicker()}</div>
    <header><h1>${t('Đặt lại mật khẩu quản trị','Reset administrator password')}</h1>
    <p>${t('Dùng mã khôi phục đã lưu khi tạo hoặc sửa tài khoản. Manager không có mật khẩu mở khóa mặc định.','Use the recovery code saved when you created or edited your account. Manager has no default unlock password.')}</p></header>
    ${field('username',t('Tên đăng nhập quản trị','Administrator username'))}
    <div class="recovery-code-field">${field('recovery_code',t('Mã khôi phục','Recovery code'),'','password')}
    ${button(t('Không có mã khôi phục?','No recovery code?'),'recovery-help','','text-button')}</div>
    <div class="recovery-passwords">${field('password',t('Mật khẩu mới','New password'),'','password',t('Ít nhất 6 ký tự','At least 6 characters'))}${field('repeat',t('Nhập lại mật khẩu','Confirm password'),'','password')}</div>
    <div id="login-error" role="alert"></div><button type="submit" class="button primary">${t('Đặt lại mật khẩu','Reset password')}</button>${button(t('Quay lại đăng nhập','Back to sign in'),'back-login','','text-button')}</form>`;
  for(const input of $('#recovery-form').querySelectorAll('input'))input.required=true;
  $('#recovery-form').elements.password.minLength=6;
}
function showLogin(message='',setup=false){
  localStorage.removeItem(recoveryViewKey);
  clearInterval(pollTimer);csrfToken='';jobId=null;state={profiles:[],machines:[],jobs:[]};currentStatus=null;
  if($('#modal').open)$('#modal').close();$('#content').replaceChildren();document.body.classList.add('auth-pending');
  $('#admin-username').textContent='';$('#logout-button').hidden=true;const root=$('#login-root');root.hidden=false;
  const title=setup?dataLabel('Tạo tài khoản quản trị đầu tiên','Create the first administrator account'):uiText("Đăng nhập");
  root.innerHTML=`<form id="login-form" data-setup="${setup}" class="login-card">${languagePicker()}<div class="brand"><span class="brandmark">m</span><span>MongoDB Manager</span></div><div class="eyebrow">${uiText("QUẢN TRỊ HỆ THỐNG")}</div><h1>${title}</h1><p>${uiText("Quản lý các cụm MongoDB và VPS của bạn.")}</p><label class="field"><span>Username</span><input name="username" autocomplete="username" required maxlength="80"></label><label class="field"><span>${uiText("Mật khẩu")}</span>${passwordControl('<input name="password" type="password" autocomplete="'+(setup?'new-password':'current-password')+'" required maxlength="1000" '+(setup?'minlength="6"':'')+'>')}</label>${setup?field('repeat',dataLabel('Nhập lại mật khẩu','Confirm password'),'','password'):''}<div id="login-error" role="alert">${message?errorBox(message):''}</div><button type="submit" class="button primary">${setup?dataLabel('Tạo tài khoản','Create account'):uiText("Đăng nhập")}</button><small>${setup?dataLabel('Mật khẩu từ 6 ký tự.','Use at least 6 characters.'):uiText("Phiên tự hết hạn sau 30 phút không hoạt động.")}</small>${setup?'':button(dataLabel('Quên mật khẩu?','Forgot password?'),'forgot-password')}</form>`;
}
async function enterWorkspace(auth){
  localStorage.removeItem(recoveryViewKey);
  csrfToken=auth.csrf||'';$('#login-root').replaceChildren();$('#login-root').hidden=true;document.body.classList.remove('auth-pending');
  $('#logout-button').hidden=!auth.enabled;$('#logout-button').textContent=uiText("Đăng xuất");
  $('#admin-username').textContent=auth.username||'';
  const accountLabel=dataLabel('Sửa tài khoản quản trị','Edit administrator account')+' · '+auth.username;
  const accountButton=$('.account-profile');
  accountButton.title=accountLabel;
  accountButton.setAttribute('aria-label',accountLabel);
  $('#admin-avatar').textContent=(auth.username||'AD').slice(0,2).toUpperCase();
  await refreshState();await render();clearInterval(pollTimer);pollTimer=setInterval(poll,2500);
}
document.addEventListener('submit',async event=>{
  if(!['login-form','recovery-form'].includes(event.target.id))return;event.preventDefault();
  const form=event.target,submit=form.querySelector('button[type="submit"]');submit.disabled=true;$('#login-error').replaceChildren();
  try{
    const {repeat,...credentials}=Object.fromEntries(new FormData(form));
    const setup=form.dataset.setup==='true';
    const recovering=form.id==='recovery-form';
    if((setup||recovering)&&credentials.password!==repeat)throw new Error(dataLabel('Hai mật khẩu chưa khớp.','Passwords do not match.'));
    if(recovering){
      const result=await api('/auth/recover',{method:'POST',body:JSON.stringify(credentials)});
      showLogin(dataLabel('Đã đặt lại mật khẩu. Hãy đăng nhập.','Password reset. Please sign in.'));
      showRecoveryCode(result.recovery_code);return;
    }
    const result=await api(setup?'/auth/setup':'/auth/login',{method:'POST',body:JSON.stringify(credentials)});
    form.elements.password.value='';await enterWorkspace({...result,enabled:true});if(result.recovery_code)showRecoveryCode(result.recovery_code);}
  catch(error){const output=$('#login-error');if(output)output.innerHTML=errorBox(error.message);else toast(error.message,true);}
  finally{submit.disabled=false;}
});
async function boot(){
  try{const auth=await api('/auth/status');if(!auth.authenticated){
    const saved=localStorage.getItem(recoveryViewKey);
    showLogin('',!auth.enabled);
    if(auth.enabled&&saved){
      showRecoveryForm();
      if(saved!=='form')showRecoveryHelp(saved);
    }
    return;
  }await enterWorkspace(auth);}
  catch(error){showLogin(error.message);}
}
boot();
