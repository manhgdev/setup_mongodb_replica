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
  'backup-preview':'info', 'member-edit':'info', 'machine-edit':'info', preflight:'info',
  'prepared-node':'info', 'backup-repeat':'create', 'backup-new':'create', 'node-add':'create',
  'join-fresh':'create', 'add-member':'create', 'add-arbiter':'configure', 'write-concern':'configure',
  'step-down':'warning', restore:'warning', 'backup-delete':'remove',
  'member-remove':'remove', 'machine-delete':'remove', 'user-drop':'remove', 'database-drop':'remove',
  'record-delete':'remove', 'profile-delete':'remove', 'cluster-ssh-remove':'remove',
  'user-new':'create', 'machine-new':'create', 'profile-new':'create', 'cluster-ssh-add':'create', provision:'create',
  'profile-open':'info', 'profile-edit':'info', 'job-open':'info', logs:'info', diagnose:'info',
  refresh:'info', collections:'info', 'upgrade-check':'info', 'ubuntu-open':'info',
  'member-ssh':'configure', 'ssh-bulk':'configure', 'user-password':'configure', service:'configure',
  'remember-user':'configure', 'backup-schedule':'configure', 'backup-sync':'warning', 'ubuntu-install':'create'
};
const button = (label, act, glyph='', tone='', attrs='') => `<button type="button" class="button ${tone}" ${actionColors[act]&&!tone.includes('vote-label')?'data-tone="'+actionColors[act]+'"':''} data-act="${act}" ${attrs}>${glyph?icon(glyph):''}${label}</button>`;
const formatDate = s => s ? new Date(s).toLocaleString(uiLanguage==='en'?'en-US':'vi-VN',{day:'2-digit',month:'2-digit',hour:'2-digit',minute:'2-digit'}) : '—';
const bytes = n => !Number.isFinite(n) ? '—' : n>=1024**3?`${(n/1024**3).toFixed(1)} GB`:n>=1024**2?`${(n/1024**2).toFixed(1)} MB`:`${(n/1024).toFixed(1)} KB`;
const statusNames = {queued:uiText("Đang chờ"),running:uiText("Đang chạy"),succeeded:uiText("Hoàn tất"),failed:uiText("Thất bại"),interrupted:uiText("Bị gián đoạn")};
const jobBadge = j => badge(statusNames[j.status]||j.status, j.status==='succeeded'?'success':j.status==='failed'||j.status==='interrupted'?'error':'warn');
let csrfToken='';
async function api(path, options={}) {
  const response = await fetch('/api'+path,{...options,headers:{'X-MongoDB-Manager':'1','Content-Type':'application/json',...(csrfToken?{'X-CSRF-Token':csrfToken}:{}),...options.headers}});
  const data = await response.json();
  if(response.status===401&&path!=='/auth/login')showLogin(uiText("Phiên đăng nhập đã hết hạn. Đăng nhập lại để tiếp tục."));
  if(!response.ok) throw new Error(typeof data.detail==='string'?data.detail:Array.isArray(data.detail)?data.detail.map(x=>x.msg).join('; '):uiText("Yêu cầu thất bại."));
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
function memberLabel(member, fallback){
  const key=JSON.stringify(['mongo-manager-member',demo,profile()?.id,member.id,member.host]);
  if(!demo)fallback=machines().find(m=>m.profile_id===profile()?.id&&m.mongo_endpoint===member.host)?.name||fallback;
  const name=localStorage.getItem(key)||fallback;
  return `<button type="button" class="member-label" data-member-key="${esc(key)}" data-fallback="${esc(fallback)}" title="${uiText("Nhấp đúp để đổi tên member")}">${esc(name)}</button>`;
}
function renameMember(event){
  const label=event.target.closest('.member-label');
  if(!label)return;
  const input=document.createElement('input');
  input.className='member-name-input';
  input.setAttribute('aria-label',uiText("Tên hiển thị của member"));
  input.value=label.textContent;
  label.replaceWith(input);
  input.focus();
  input.select();
  function finish(save,restoreFocus){
    if(!input.isConnected)return;
    const key=label.dataset.memberKey;
    const name=input.value.trim();
    input.removeEventListener('blur',onBlur);
    input.replaceWith(label);
    if(save){
      if(name)localStorage.setItem(key,name);
      else localStorage.removeItem(key);
      for(const item of document.querySelectorAll('.member-label')){
        if(item.dataset.memberKey===key)item.textContent=name||item.dataset.fallback;
      }
    }
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
function memberTable(s,full=false){
  if(!s?.members.length)return empty(uiText("Chưa đọc được thành viên"),uiText("Kiểm tra kết nối và quyền xem replica set."),'','');
  return table([uiText("THÀNH VIÊN"),uiText("VAI TRÒ"),uiText("TRẠNG THÁI"),uiText("ĐỘ TRỄ"),'VOTES / PRIORITY',full?uiText("THAO TÁC"):'UPTIME'],s.members.map((m,i)=>`<tr><td><div class="host-cell"><span class="server-icon">${icon('server')}</span><div><strong>${memberLabel(m,demo?`mongo-0${i+1}`:`Member ${m.id}`)}</strong><small class="mongo-address"><a href="#machines?member=${encodeURIComponent(m.host)}">${esc(m.host)}</a></small></div></div></td><td>${memberBadge(m.state)}</td><td><span class="legend"><span class="dot ${m.health?'green':''}"></span>${m.health?'Healthy':uiText("Không reachable")}</span></td><td class="mono">${m.lag==null?'—':`${m.lag} s`}</td><td class="mono">${m.votes} / ${m.priority}</td><td>${full?`${button(uiText("Sửa"),'member-edit','','small',`data-host="${esc(m.host)}"`)} ${button(uiText("Gỡ"),'member-remove','','small',`data-host="${esc(m.host)}"`)}`:`${Math.floor(m.uptime/86400)} ${uiText("ngày")}`}</td></tr>`));
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
function machinePage(){
 let html=heading(uiText("Máy chủ"),uiText("Quản lý kết nối SSH, cài đặt và dịch vụ trên từng máy."),button(uiText("Thêm máy chủ"),'machine-new','plus')+(profile()?button(uiText("Thêm Secondary"),'node-add','plus','primary')+button(uiText("Thêm Arbiter"),'add-arbiter','plus'):''));
 if(!profile())html+=onboardingCards();
 const linked=machines().filter(m=>!profile()||m.profile_id===profile().id);
 const members=profile()?(currentStatus?.members||profile().seeds.map(host=>({host}))):[];
 const memberByHost=new Map(members.map(member=>[member.host,member]));
 linked.sort((a,b)=>Number(memberByHost.has(b.mongo_endpoint))-Number(memberByHost.has(a.mongo_endpoint)));
 const electionActions=member=>{
   if(member?.votes==null)return '';
   const settings=`Votes: ${esc(member.votes)} · ${uiText("Ưu tiên:")} ${esc(member.priority??'—')}`;
   const tone=memberTones.get(member.state)||'';
   if(!['PRIMARY','SECONDARY'].includes(member.state))return `<span class="button small vote-label ${tone}">${settings}</span>`;
   return button(settings,'member-edit','','small vote-label '+tone,`data-host="${esc(member.host)}"`);
 };
 const removeAction=member=>member?.state && member.state!=='PRIMARY'
   ?button(uiText("Gỡ"),'member-remove','trash','small danger',`data-host="${esc(member.host)}"`):'';
 const rows=linked.map((m,index)=>{
   const member=memberByHost.get(m.mongo_endpoint);
   return `<tr data-node="${esc(m.mongo_endpoint)}" tabindex="-1"><td class="row-number">${index+1}</td><td><div class="host-cell"><span class="server-icon">${icon('server')}</span><div><strong>${member?.id!=null?memberLabel(member,m.name):esc(m.name)}</strong>${m.mongo_endpoint?`<small class="mongo-address">${esc(m.mongo_endpoint)}</small>`:''}${member?.state?memberBadge(member.state):''}</div></div></td><td>${badge(m.mode==='ssh'?'SSH':'LOCAL','dark')} ${m.mode==='ssh'?`<span class="mono ssh-address">${esc(m.user)}@${esc(m.host.includes(':')?'['+m.host+']':m.host)}:${esc(m.port)}</span>`:''}</td><td class="mono">${esc(m.service)}<small>${esc(profiles().find(p=>p.id===m.profile_id)?.name||uiText("Chưa liên kết cụm"))}</small></td><td><div class="actions">${electionActions(member)}${!member&&profile()&&currentStatus&&m.mode==='ssh'?button(uiText("Thêm làm Secondary"),'join-fresh','plus','small',`data-id="${esc(m.id)}"`):''}<a class="button small" href="#upgrade?machine=${encodeURIComponent(m.id)}">${dataLabel("Tương thích","Compatibility")}</a>${button(uiText("Kiểm tra"),'preflight','pulse','small',`data-id="${esc(m.id)}"`)}${button(uiText("Dịch vụ"),'service','','small',`data-id="${esc(m.id)}"`)}${button(uiText("Sửa"),'machine-edit','','small',`data-id="${esc(m.id)}"`)}${button(uiText("Xoá"),'machine-delete','trash','small danger',`data-id="${esc(m.id)}"`)}${removeAction(member)}</div></td></tr>`;
 });
 const discovered=[];
 for(const member of members){
   if(linked.some(m=>m.mongo_endpoint===member.host))continue;
   const label=member.id!=null?memberLabel(member,'Member '+member.id):esc(member.host);
   discovered.push(`<tr data-node="${esc(member.host)}" tabindex="-1"><td class="row-number">${discovered.length+1}</td><td><strong>${label}</strong><small class="mongo-address">${esc(member.host)}</small>${member.state?memberBadge(member.state):''}</td><td>${uiText("Chưa cấu hình SSH")}</td><td>—</td><td><div class="actions">${electionActions(member)}${button(uiText("Cấu hình SSH"),'member-ssh','','small',`data-host="${esc(member.host)}"`)}${removeAction(member)}</div></td></tr>`);
 }
 const headers=[uiText("STT"),uiText("MÁY CHỦ"),uiText("KẾT NỐI"),'SERVICE',uiText("THAO TÁC")];
 html+=panel(uiText("Máy chủ của bạn"),rows.length?table(headers,rows):empty(uiText("Thêm máy chủ đầu tiên"),uiText("Kết nối bằng mật khẩu SSH, key/agent hoặc chọn Local."),'machine-new',uiText("Thêm máy chủ"),'server'), '', members.some(m=>m.state==='PRIMARY')?button(uiText("Đổi primary"),'step-down','','small change-primary'):'');
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
function addClusterSSH(record=null){
 const container=$('#cluster-ssh-list');if(!container)return;
 const index=recordContext.sshIndex++;const prefix='cluster_ssh_'+index+'_';
 const firstSeed=$('[name="seeds"]',$('#record-form')).value.split(/[\n,]+/)[0].trim();
 const host=firstSeed.startsWith('[')?firstSeed.slice(1,firstSeed.indexOf(']')):firstSeed.split(':')[0];
 const row=document.createElement('section');row.className='cluster-ssh-row';row.dataset.recordId=record?.id||'';row.dataset.prefix=prefix;row.dataset.hasPassword=record?.has_ssh_password?'1':'';
 const f=(name,...args)=>field(prefix+name,...args);
 row.innerHTML=`<div class="ssh-row-heading"><strong>${uiText("SSH cho một VPS")}</strong>${button(uiText("Bỏ khỏi lần lưu"),'cluster-ssh-remove','','small')}</div><div class="form-grid">${f('name',uiText("Tên VPS"),record?.name||'','text',uiText("Ví dụ: mongo-01"))}${f('mongo_endpoint',uiText("Endpoint MongoDB trên VPS"),record?.mongo_endpoint||firstSeed,'text',uiText("IP:port của member tương ứng; IP trống port dùng 27017."))}${f('host',uiText("Địa chỉ SSH"),record?.host||host)}${f('port','Port SSH',record?.port||22,'number')}${f('user','User SSH',record?.user||'root')}${f('ssh_auth',uiText("Xác thực SSH"),record?.ssh_auth||'password','select','',false,[{value:'password',label:uiText("Mật khẩu SSH")},{value:'key',label:'SSH key / Agent'}])}${f('ssh_password',uiText("Mật khẩu SSH"),'','password',record?.has_ssh_password?uiText("Để trống để giữ mật khẩu đã lưu."):uiText("Mật khẩu của tài khoản hệ điều hành trên VPS."),true)}${f('identity','SSH private key',record?.identity||'','text',uiText("Để trống để dùng agent."),true)}${f('service','Service MongoDB',record?.service||'mongod','text',uiText("Tên systemd service đang chạy."),true)}</div>`;
 if(record?.has_ssh_password)markSavedPassword(row.querySelector('.password-control input'),'/machines/'+record.id+'/reveal-password');
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
 const auth=value('ssh_auth');if(!value('name')||!value('host')||!value('mongo_endpoint'))throw new Error(uiText("SSH: nhập tên VPS, địa chỉ SSH và endpoint MongoDB tương ứng."));
 if(auth==='password'&&!secret&&!row.dataset.hasPassword)throw new Error((uiText("Nhập mật khẩu SSH cho VPS")+" ")+value('name')+'.');
 return {record_id:row.dataset.recordId,machine:{name:value('name'),mode:'ssh',host:value('host'),port:Number(value('port')),user:value('user'),ssh_auth:auth,ssh_password:auth==='password'?(secret||null):'',identity:auth==='key'?value('identity'):'',service:value('service'),mongo_endpoint:value('mongo_endpoint')}};
 });
}

function feature(title,desc,glyph,act,label){return `<article class="feature-card"><span class="quick-icon">${icon(glyph)}</span><h2>${title}</h2><p>${desc}</p>${button(label,act,'','')}</article>`;}
function replicaPage(){return heading('Replica Set',uiText("Quản lý thành viên, vai trò và cấu hình bầu chọn."),button(uiText("Thêm Arbiter"),'add-arbiter','plus')+button(uiText("Node đã chuẩn bị"),'prepared-node','plus')+button(uiText("Thêm Secondary"),'node-add','plus','primary'))+(statusError?errorBox(statusError):'')+panel(uiText("Thành viên"),memberTable(currentStatus,true),uiText("Chọn Votes và Ưu tiên khi thêm secondary."))+`<div class="cards">${feature('Step down Primary',uiText("Chuyển quyền primary qua cơ chế bầu chọn. Cần secondary sẵn sàng và đủ quorum."),'cluster','step-down',uiText("Xem trước"))}${feature('Write Concern',uiText("Xem và đặt mức xác nhận ghi cho replica set."),'shield','write-concern',uiText("Cấu hình"))}</div>`;}
function archiveHosts(){return machines().filter(m=>m.profile_id===profile()?.id);}
function archiveHostKey(){return 'mongo-backup-host:'+demo+':'+profile()?.id;}
function selectedArchiveHost(){
  const hosts=archiveHosts(),saved=localStorage.getItem(archiveHostKey());
  const recent=jobs().find(j=>['backup','backups'].includes(j.action)&&hosts.some(m=>m.id===j.machine_id||m.name===j.target));
  return hosts.find(m=>m.id===saved)||hosts.find(m=>m.id===recent?.machine_id||m.name===recent?.target)||hosts[0];
}
const deletedDemoBackups=new Set();
let catalogLoading=false,catalogError='';
async function loadArchiveCatalog(id){
  const host=selectedArchiveHost(),pid=profile()?.id;
  backupItems=[];backupListedHost=host;catalogError='';catalogLoading=!!host;
  $('#content').innerHTML=backupPage();
  if(!host)return;
  try{
    const items=demo?[{id:'a'.repeat(32),time:new Date().toISOString(),machine_id:host.id,source:profile().name,source_id:pid,database:'application',size:2048}]:
      await api('/profiles/'+pid+'/machines/'+host.id+'/backups');
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
  if(catalogError)return errorBox(catalogError);
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
 const records=chosen.map(index=>{const t=sshBulkTargets[Number(index)],old=t.existing;
 if(fields.ssh_auth==='password'&&!fields.ssh_password&&!old?.has_ssh_password)throw new Error('VPS '+t.endpoint+(" "+uiText("chưa có mật khẩu SSH.")));
 return {record_id:old?.id||'',machine:{name:old?.name||t.profile.name+' · '+t.host,mode:'ssh',host:old?.host||t.host,port:Number(fields.port),user:fields.user,ssh_auth:fields.ssh_auth,ssh_password:fields.ssh_auth==='password'?(fields.ssh_password||null):'',identity:fields.ssh_auth==='key'?fields.identity:'',profile_id:t.profile.id,mongo_endpoint:t.endpoint,service:old?.service||'mongod'}};
 });
 if(demo){toast(uiText("Chế độ minh họa không lưu thông tin SSH."));return;}
 await api('/machines/batch',{method:'POST',body:JSON.stringify(records)});form.elements.ssh_password.value='';$('#modal').close();await refreshState();await render();toast((uiText("Đã lưu SSH cho")+" ")+records.length+' VPS.');
 }catch(error){formError(error);}finally{submit.disabled=false;}
});
function settingsPage(){const p=profile();return heading(uiText("Cấu hình workspace"),uiText("Thông tin kết nối và các thiết lập của cụm đang chọn."),button(uiText("Chỉnh kết nối"),'profile-edit','settings','primary'))+sshSettingsPanel()+panel(uiText("Hồ sơ MongoDB"),p?`<div class="panel-body">${[[uiText("Tên cụm"),p.name],['Seed list',p.seeds.join(', ')],['Replica set',p.replica_set||'Standalone'],['Username',p.username||uiText("Không dùng")],['Auth database',p.auth_db],['TLS',p.tls?uiText("Bật"):uiText("Tắt")]].map(([k,v])=>`<div class="key-value"><span>${k}</span><strong>${esc(v)}</strong></div>`).join('')}<div class="section-title"></div><div class="actions">${button(uiText("Chỉnh kết nối"),'profile-edit','settings','primary')}${button(uiText("Chuỗi kết nối"),'connection','external')}${button(uiText("Xóa hồ sơ"),'profile-delete','trash','danger')}</div></div>`:empty(uiText("Chưa chọn cụm"),uiText("Tạo hồ sơ kết nối trước khi cấu hình.")))+`<div class="callout neutral">${uiText("Hồ sơ và mật khẩu được mã hóa trên máy quản trị. Khóa mã hóa nằm cùng thư mục dữ liệu, chỉ tài khoản hệ điều hành hiện tại có quyền đọc. SSH hỗ trợ mật khẩu hoặc key/agent của tài khoản chạy ứng dụng.")}</div>`;}
function diagnosticsPage(){return heading(uiText("Chẩn đoán"),uiText("Kiểm tra kết nối MongoDB và môi trường máy chủ."),button(uiText("Kiểm tra kết nối"),'diagnose','pulse','primary'))+`<div class="cards">${feature(uiText("Kết nối các node"),uiText("Kết nối trực tiếp từng seed, xác thực và đọc vai trò từ máy quản trị."),'cluster','diagnose',uiText("Chạy chẩn đoán"))}${feature(uiText("Môi trường VPS"),uiText("Kiểm tra Ubuntu, CPU, kernel, đĩa, package và service qua SSH."),'server','preflight',uiText("Kiểm tra máy"))}${feature(uiText("Nhật ký MongoDB"),uiText("Xem journal của service để xác định lỗi startup, quyền hoặc port."),'terminal','logs',uiText("Đọc nhật ký"))}</div><div class="section-title"><h2>${uiText("Kết quả kiểm tra")}</h2></div><div id="query-result">${empty(uiText("Sẵn sàng kiểm tra"),uiText("Chọn một phép kiểm tra phía trên. Các bước chẩn đoán chỉ đọc thông tin."),'','','pulse')}</div>`;}
function hostCompatibilityPanel(){
  const hosts=machines().filter(m=>(m.profile_id||'')===(profile()?.id||''));
  if(!hosts.length)return panel('Ubuntu',empty(dataLabel('Chưa có máy để kiểm tra','No hosts to inspect'),'', 'machine-new',uiText('Thêm máy')));
  const requested=new URLSearchParams(location.hash.split('?')[1]).get('machine');
  const host=hosts.find(m=>m.id===requested)||hosts[0];
  const options=hosts.map(m=>({value:m.id,label:m.name+' · '+(m.host||'Local')}));
  const selector=field('compatibility_host',dataLabel('Máy cần kiểm tra','Host to inspect'),host.id,'select','',false,options);
  return panel(dataLabel('Ubuntu và MongoDB trên máy','Ubuntu and MongoDB on this host'),
    `<div class="panel-body host-compatibility"><div class="actions">${selector}${button(dataLabel('Kiểm tra lại','Check again'),'compatibility-refresh','pulse')}</div><div id="compatibility-report" aria-live="polite"></div></div>`,
    dataLabel('Đọc phiên bản trên máy và đối chiếu gói từ kho MongoDB chính thức.','Read host versions and check packages in the official MongoDB repository.'),
    button(dataLabel('Quản lý Ubuntu','Manage Ubuntu'),'ubuntu-open','server'));
}
function compatibilityReport(r,series){
  const t=dataLabel;
  const statuses={compatible:t('Ubuntu hiện tại phù hợp','Current Ubuntu is compatible'),upgrade:t('Cần nâng Ubuntu','Ubuntu upgrade required'),unsupported:t('Chưa có cấu hình phù hợp','No compatible configuration'),unknown:t('Chưa xác minh được','Verification incomplete')};
  const role=({uninitialized:t('Replica set chưa khởi tạo','Replica set uninitialized'),other:t('Vai trò khác','Other member role')})[r.role]||r.role||t('Chưa xác minh','Unverified');
  const notes=[];
  if(r.processes>1)notes.push(t(`Có ${r.processes} tiến trình mongod trên máy. Trình nâng Ubuntu tự động yêu cầu một instance duy nhất.`,`This host has ${r.processes} mongod processes. Automated Ubuntu upgrades require a single instance.`));
  if(r.endpoint&&!r.live)notes.push(t('Chưa đọc được phiên bản trực tiếp từ endpoint.','The endpoint version could not be verified directly.'));
  const rows=[
    ['Ubuntu',r.os,r.hostname], [t('Kiến trúc CPU','CPU architecture'),r.arch,r.current],
    ['MongoDB',r.version||r.series,r.live?t('Đọc trực tiếp từ endpoint','Reported by the endpoint'):r.version?t('Đọc từ mongod trên máy','Reported by host binary'):t('Nhánh dự định cài','Planned series')],
    [t('Gói trong kho chính thức','Official repository package'),r.package||'—',r.target?'Ubuntu '+r.target:''],
    [t('Dịch vụ','Service'),r.service,r.service_state], [t('Vai trò MongoDB','MongoDB role'),role,r.endpoint||'—']
  ];
  const planned=!r.version?field('compatibility_series',t('Nhánh MongoDB dự định cài','Planned MongoDB series'),series,'select','',false,['9.0','8.0']):'';
  return planned+`<div class="compatibility-outcome">${badge(statuses[r.status],r.status==='compatible'?'success':'warn')}<span>${esc(r.reason||(r.path.length?r.path.join(' → '):t('Giữ nguyên phiên bản Ubuntu.','Keep the current Ubuntu release.')))}</span></div>`+
    table([t('Hạng mục','Item'),t('Kết quả','Result'),t('Chi tiết','Details')],rows.map(row=>'<tr>'+row.map(cell=>'<td>'+esc(cell||'—')+'</td>').join('')+'</tr>'))+
    notes.map(note=>`<div class="callout">${esc(note)}</div>`).join('');
}
async function loadCompatibility(){
  const output=$('#compatibility-report'),selector=$('[name="compatibility_host"]');
  if(!output||!selector)return;
  const id=selector.value;
  const series=output.dataset.series||'9.0';
  const pending=document.createElement('div');
  pending.className='loading';
  pending.textContent=dataLabel('Đang đọc Ubuntu, MongoDB và kho gói…','Checking Ubuntu, MongoDB and the package repository…');
  output.replaceChildren(pending);
  try{
    const m=machines().find(host=>host.id===id);
    const result=demo?{os:'Ubuntu 26.04 LTS',arch:'arm64',current:'resolute',hostname:m.name,version:'9.0.4',series:'9.0',package:'9.0.4',target:'26.04',status:'compatible',path:[],live:true,role:demoStatus.members.find(node=>node.host===m.mongo_endpoint)?.state,service:m.service,service_state:'active',endpoint:m.mongo_endpoint,processes:1}:await api('/machines/'+encodeURIComponent(id)+'/compatibility?series='+encodeURIComponent(series));
    if(pending.isConnected)output.innerHTML=compatibilityReport(result,series);
  }catch(error){if(pending.isConnected)output.innerHTML=errorBox(error.message);}
}

function upgradePage(){return heading(uiText("Phiên bản & nâng cấp"),uiText("Kiểm tra tương thích trước khi thay đổi phiên bản MongoDB."),button(uiText("Kiểm tra điều kiện"),'upgrade-check','pulse','primary'))+`${hostCompatibilityPanel()}<div class="layout-two">${panel(uiText("Quy trình nâng 8.0 → 9.0"),`<div class="panel-body"><ol class="step-list"><li><strong>${uiText("Kiểm tra và backup")}</strong>${uiText("Xác minh driver, FCV và sức khỏe tất cả member. Restore thử trước khi thay phiên bản.")}</li><li><strong>${uiText("Nâng secondary tuần tự")}</strong>${uiText("Đợi từng member quay lại SECONDARY rồi mới chuyển sang node tiếp theo.")}</li><li><strong>${uiText("Chuyển primary")}</strong>${uiText("Step down, chờ primary mới rồi nâng node còn lại.")}</li><li><strong>${uiText("Kiểm chứng ứng dụng")}</strong>${uiText("Giữ FCV cũ trong thời gian kiểm tra. Nâng FCV bằng bước riêng sau đó.")}</li></ol></div>`)}${panel(uiText("Phạm vi tự động hóa"),`<div class="panel-body"><div class="callout">${uiText("Web hỗ trợ kiểm tra điều kiện nâng cấp. Thay binary và nâng FCV thực hiện theo runbook; chưa tự chạy từ giao diện.")}</div><p class="help-links"><a href="https://www.mongodb.com/docs/manual/tutorial/install-mongodb-on-ubuntu/" target="_blank" rel="noopener noreferrer">${dataLabel('Cài MongoDB Community trên Ubuntu ↗','Install MongoDB Community on Ubuntu ↗')}</a></p><p class="help-links"><a href="https://www.mongodb.com/docs/manual/release-notes/9.0-upgrade-from-8.0-replica-set/" target="_blank" rel="noopener noreferrer">${uiText("Mở hướng dẫn MongoDB chính thức ↗")}</a></p>${button(uiText("Xem kết quả kiểm tra"),'upgrade-check','pulse')}</div>`)}</div>`;}
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
function confirmProfileDeletion(name){
  const dialog=document.createElement('dialog');
  dialog.className='delete-confirmation';
  dialog.setAttribute('aria-labelledby','delete-confirmation-title');
  dialog.innerHTML=`<form method="dialog"><div class="modal-header"><h2 id="delete-confirmation-title">${uiText("Xóa hồ sơ")}</h2></div><div class="modal-body"><p><strong>${esc(name)}</strong> · ${uiText("Hồ sơ sẽ được xóa khỏi ứng dụng. Dữ liệu và dịch vụ trên VPS vẫn giữ nguyên.")}</p></div><div class="modal-footer"><button class="button" value="cancel" autofocus>${uiText("Hủy")}</button><button class="button danger" value="delete">${uiText("Xoá")}</button></div></form>`;
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
function showRecord(kind,record=null){
  recordContext={kind,profileId:record?.profile_id||profile()?.id||'',id:record?.id,hasSSHPassword:!!record?.has_ssh_password,sshIndex:0};jobId=null;
  let fields='';
  if(kind==='profiles'){
    fields=field('name',uiText("Tên hiển thị"),record?.name||'','text',uiText("Ví dụ: Production hoặc Staging"),true)+field('seeds','Seed list',record?.seeds.join('\n')||'','textarea',uiText("Nhập IP hoặc hostname của member; bỏ trống port sẽ dùng 27017. Ví dụ: 203.0.113.10 hoặc 203.0.113.10:27018."),true)+field('replica_set',uiText("Tên replica set"),record?.replica_set??'','text',uiText("Để trống để tự nhận diện từ primary hoặc secondary."))+field('auth_db','Auth database',record?.auth_db||'admin')+field('username','Username MongoDB',record?.username||'')+field('password',uiText("Mật khẩu MongoDB"), '', 'password',record?uiText("Để trống để giữ mật khẩu đã lưu."):uiText("Được mã hóa trên máy quản trị."))+field('tls',uiText("Bật TLS"),record?.tls||false,'checkbox','',true)+field('tls_ca',uiText("Đường dẫn CA (nếu dùng)"),record?.tls_ca||'','text',uiText("Đường dẫn trên máy quản trị. Để trống để dùng CA hệ thống."),true);
  }else{
    fields=field('name',uiText("Tên máy chủ"),record?.name||'','text',uiText("Ví dụ: mongo-01"),true)+field('mode',uiText("Chế độ"),record?.mode||'ssh','select','',false,[{value:'ssh',label:uiText("SSH — VPS từ xa")},{value:'local',label:uiText("Local — máy chạy web")}])+field('host',uiText("Địa chỉ SSH"),record?.host||'','text',uiText("Mật khẩu dùng IP/hostname trực tiếp; key/agent có thể dùng alias SSH."))+field('port','Port SSH',record?.port||22,'number')+field('user','User SSH',record?.user||'root')+field('ssh_auth',uiText("Xác thực SSH"),record?.ssh_auth||'key','select','',true,[{value:'key',label:'SSH key / Agent'},{value:'password',label:uiText("Mật khẩu SSH")}])+field('ssh_password',uiText("Mật khẩu SSH"),'','password',record?.has_ssh_password?uiText("Đã lưu mật khẩu. Để trống để giữ nguyên."):uiText("Mật khẩu được lưu mã hóa trên máy quản trị."),true)+field('identity',uiText("SSH private key (tùy chọn)"),record?.identity||'','text',uiText("Để trống để dùng SSH agent hoặc ~/.ssh/config."),true)+field('mongo_endpoint',uiText("Endpoint MongoDB trên VPS"),record?.mongo_endpoint||'','text',uiText("Ví dụ: 203.0.113.10:27017. Port này khác port SSH."),true)+field('service',uiText("Tên service"),record?.service||'mongod','text',uiText("Service systemd của instance cần quản lý."),true);
  }
  modal(record?uiText("Chỉnh sửa hồ sơ"):kind==='profiles'?uiText("Kết nối cụm MongoDB"):uiText("Thêm máy chủ"),`<form id="record-form"><div class="modal-body"><div class="form-grid">${fields}</div>${kind==='profiles'?("<div id=\"probe-result\"></div><details class=\"cluster-ssh\"><summary>"+uiText("SSH cho các VPS trong cụm (tùy chọn)")+"</summary><p>"+uiText("Tài khoản SSH dùng để đọc log, điều khiển service, cài đặt và xử lý trên VPS. Mỗi VPS có thông tin SSH riêng; tài khoản này khác tài khoản MongoDB ở trên. Lưu hồ sơ không tự chạy lệnh trên VPS.")+"</p><div id=\"cluster-ssh-list\"></div>")+button(uiText("Thêm VPS bằng SSH"),'cluster-ssh-add','plus')+' '+button(uiText("Lưu SSH"),'cluster-ssh-save')+("<p>"+uiText("Có thể lưu SSH trước để kiểm tra VPS khi MongoDB chưa kết nối được. Sau đó tiếp nhận cụm khi đã xử lý xong.")+"</p></details>"):''}<div id="form-error"></div></div><div class="modal-footer">${kind==='profiles'?button(uiText("Kiểm tra kết nối"),'profile-probe'):''}${record?button(uiText("Xóa hồ sơ"),'record-delete','trash','danger'):''}${button(uiText("Hủy"),'modal-close')}<button class="button primary" type="submit">${icon('check')}${kind==='profiles'?uiText("Kiểm tra & lưu cụm"):uiText("Lưu hồ sơ")}</button></div></form>`,'',kind==='profiles'?uiText("Tiếp nhận cụm đang chạy: chỉ đọc và kiểm tra kết nối, không cài đặt hay khởi tạo lại."):uiText("Chọn mật khẩu hoặc SSH key/agent. Máy đích cần có trong known_hosts."));
  if(record?.has_password || record?.has_ssh_password){
    markSavedPassword($('#record-form .password-control input'),'/'+kind+'/'+record.id+'/reveal-password');
  }
  if(kind==='machines'){syncSSHFields();$('#record-form').addEventListener('change',syncSSHFields);}
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
    if(name==='ssh_password')input.required=password&&!recordContext.hasSSHPassword;
  }
}
const schemas={
  preflight:{title:uiText("Kiểm tra môi trường"),host:true,fields:[]},
  logs:{title:uiText("Xem nhật ký dịch vụ"),host:true,fields:[]},
  install:{title:uiText("Cài MongoDB Community"),host:true,note:uiText("Cài mới bằng package chính thức. Nếu đã có mongod, tác vụ sẽ dừng và giữ nguyên phiên bản hiện tại."),fields:[['series',uiText("Nhánh MongoDB"),'9.0','select','',false,['9.0','8.0']]]},
  setup:{title:uiText("Tạo replica set một node"),host:true,note:uiText("Cần cài mongod và mongosh trước. Tạo service và đường dẫn riêng theo tên instance. Cụm mới dùng keyfile và mật khẩu, TLS tắt."),fields:[['instance',uiText("Tên instance"),'production','text',uiText("Chữ thường, số, dấu gạch ngang.")],['replica_set',uiText("Tên replica set"),'rs0'],['port','Port MongoDB',27017,'number'],['advertise',uiText("Địa chỉ quảng bá"),'', 'text',uiText("Nhập IP public hoặc DNS của VPS kèm port MongoDB, ví dụ mongo.example.com:27017.")],['bind_ip','Bind address','0.0.0.0','text',uiText("0.0.0.0 hoặc danh sách IP có 127.0.0.1. Firewall quản lý riêng."),true],['username',uiText("User quản trị"),'admin'],['password',uiText("Mật khẩu quản trị"),'','password',uiText("Ít nhất 12 ký tự.")]]},
  service:{title:uiText("Điều khiển dịch vụ"),host:true,note:uiText("Chỉ tác động service trong hồ sơ máy. Stop/restart có thể gián đoạn truy cập dữ liệu; xem trạng thái replica set trước khi chạy."),fields:[['operation',uiText("Thao tác"),'restart','select','',true,[{value:'start',label:uiText("Khởi động")},{value:'stop',label:uiText("Dừng")},{value:'restart',label:uiText("Khởi động lại")},{value:'enable',label:uiText("Bật autostart")},{value:'disable',label:uiText("Tắt autostart")}]]]},
  add_member:{title:uiText("Thêm thành viên"),profile:true,note:uiText("Node đích phải chạy mongod với cùng replSetName và keyfile. Web thêm membership; không ghi đè cấu hình node đích. Chọn Votes và Ưu tiên khi thêm secondary."),fields:[['host',uiText("Địa chỉ node"),'','text',uiText("IP hoặc hostname:port"),true],['arbiter',uiText("Thêm dưới vai trò Arbiter"),false,'checkbox','',true]]},
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
schemas.ubuntu_upgrade={title:dataLabel('Quản lý Ubuntu','Manage Ubuntu'),host:true,
  note:dataLabel('Máy đã cài MongoDB sẽ dùng phiên bản đang chạy để kiểm tra kho gói.','For existing installations, package checks use the running MongoDB version.'),
  fields:[['series',uiText('Nhánh MongoDB'),'9.0','select','',false,['9.0','8.0']],
    ['target',dataLabel('Ubuntu đích','Target Ubuntu'),'auto','select','',false,
      [{value:'auto',label:dataLabel('Tự chọn LTS tương thích gần nhất','Nearest compatible LTS')},
       ...Object.entries({focal:'20.04',jammy:'22.04',noble:'24.04',resolute:'26.04'}).map(([value,v])=>({value,label:'Ubuntu '+v+' LTS'}))]]]};
schemas.provision={...schemas.setup,title:uiText("Cài và tạo cụm mới"),note:uiText("Dành cho VPS chưa có cụm ở port này. Kiểm tra đích, cài package nếu thiếu, tạo keyfile và replica set, lưu hồ sơ và xác minh kết nối."),fields:[['series',uiText("Nhánh MongoDB"),'9.0','select','',true,['9.0','8.0']],...schemas.setup.fields]};
schemas.join_fresh={title:uiText("Kiểm tra VPS và thêm member"),host:true,profile:true,note:uiText("Mọi chế độ đều kiểm tra SSH, phiên bản và keyfile. Chế độ cài mới cần port/thư mục trống hoặc instance manager khớp cấu hình để tái sử dụng. Chọn member nguồn bất kỳ, có quyền SSH đọc keyfile; nguồn không cần là primary; tài khoản MongoDB cần quyền getCmdLineOpts và quản lý cụm. Không tạo replica set/user riêng trên Secondary. Cụm TLS cần chuẩn bị node riêng."),fields:[['mode',uiText("Cách xử lý VPS"),'prepare','select',uiText("Cài khi thiếu; instance manager khớp cấu hình được tái sử dụng. Không tự cài đè dữ liệu."),true,[{value:'prepare',label:uiText("Kiểm tra và cài/cấu hình instance manager")},{value:'prepared',label:uiText("Kiểm tra node đã cấu hình sẵn (giữ nguyên)")}]],['arbiter',uiText("Thêm dưới vai trò Arbiter"),false,'checkbox',uiText("Bỏ chọn để thêm Secondary."),true],['target_keyfile',uiText("Keyfile trên node đã chuẩn bị"),'','text',uiText("Chỉ bắt buộc với chế độ node đã chuẩn bị; nhập đường dẫn thực tế để đối chiếu nguồn."),true],['source_machine_id',uiText("VPS nguồn giữ keyfile (bất kỳ member)"),'','select',uiText("Dùng để đọc keyfile đang chạy; không thay đổi VPS nguồn."),true,[]],['source_endpoint',uiText("Endpoint MongoDB của VPS nguồn"),'','text',uiText("Phải là member của cụm đã chọn."),true],['instance',uiText("Tên instance mới"),'secondary'],['port','Port MongoDB',27017,'number'],['advertise',uiText("Địa chỉ MongoDB của VPS mới (tùy chọn)"),'','text',uiText("Để trống để dùng địa chỉ MongoDB đã lưu hoặc IP public của VPS cùng cổng đã chọn."),true],['bind_ip','Bind address','0.0.0.0','text',uiText("Kiểm tra firewall giữa các VPS trước khi chạy."),true]]};
for(const schema of [schemas.add_member,schemas.join_fresh]){
  schema.fields.push(['votes','Votes',0,'select','',false,[0,1]],
    ['priority',uiText("Ưu tiên bầu primary"),0,'number',uiText("Giá trị cao hơn được ưu tiên. Đặt 0 để node không thể làm primary.")]);
}
function openAction(action,overrides={}){
  jobId=null;const schema=schemas[action];
  if(schema.profile&&!profile()){toast(uiText("Thêm hồ sơ MongoDB trước khi thực hiện."));showRecord('profiles');return;}
  const cluster=profile();
  const hosts=machines().filter(m=>cluster?m.profile_id===cluster.id:!m.profile_id);
  if(schema.host&&!hosts.length){toast(uiText("Thêm máy thực thi trước khi thực hiện."));showRecord('machines');return;}
  if(action==='join_fresh'&&hosts.length<2){pendingJoinOptions=overrides;toast(uiText("Cần SSH của VPS nguồn và VPS đích. Nhập VPS mới trước."));pendingJoin=true;showRecord('machines');return;}
  actionContext={action,overrides,profileId:schema.profile?cluster.id:''};
  let fields='';
  if(schema.host)fields+=field('machine_id',action==='join_fresh'?uiText("VPS đích mới"):uiText("Máy thực thi"),overrides.machine_id||(action==='join_fresh'?(hosts.find(m=>!m.profile_id)||hosts.at(-1)).id:hosts[0].id),'select','',true,hosts.map(m=>({value:m.id,label:`${m.name} · ${m.mode==='local'?'Local':`${m.user}@${m.host}`} · ${m.service}`})));
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
  for(const entry of schema.fields){const f=[...entry];if(f[0]==='source_machine_id')f[6]=hosts.map(m=>({value:m.id,label:m.name+' · '+m.host}));if(f[0] in overrides)f[2]=overrides[f[0]];fields+=field(...f);}
  modal(schema.title,`<form id="action-form"><div class="modal-body">${schema.note?`<div class="callout">${schema.note}</div>`:''}<div class="form-grid">${fields}</div><div id="form-error"></div></div><div class="modal-footer">${action==='install'?button(dataLabel('Kiểm tra Ubuntu','Check Ubuntu'),'ubuntu-from-install'):''}${action==='backup_schedule'&&currentSchedule()?.enabled?button(dataLabel('Tạm dừng lịch','Pause schedule'),'schedule-pause'):''}${button(uiText("Hủy"),'modal-close')}<button class="button primary" type="submit">${action==='backup_schedule'?dataLabel('Lưu và bật lịch','Save and enable'):uiText("Xem lại thao tác →")}</button></div></form>`);
  const form=$('#action-form');let lastSource='';
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
  if(action==='join_fresh')form.elements.advertise.required=false;
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
    const src=machines().find(m=>m.id===form.elements.source_machine_id?.value);
    if(form.elements.source_endpoint&&src){const next=src.mongo_endpoint||'';if(!form.elements.source_endpoint.value||form.elements.source_endpoint.value===lastSource)form.elements.source_endpoint.value=next;lastSource=next;}
  };fill();form.addEventListener('change',fill);
}
function formError(error){const target=$('#form-error');if(target)target.innerHTML=`<div class="form-error">${esc(error.message||error)}</div>`;else toast(error.message||error,true);}
async function runPlan(action,plan,confirmation){
  if(demo){
    const result=action==='backups'?[{id:'a'.repeat(32),time:new Date().toISOString(),source:'Production',database:uiText("Tất cả"),size:2.4*1024**3,verified_restore:false}]:{demo:true,message:uiText("Mô phỏng hoàn tất. Không thay đổi máy chủ.")};
    if(action==='ubuntu_upgrade')Object.assign(result,{series:plan.ubuntu.series,version:plan.ubuntu.version});
    if(action==='backups')for(const item of result)Object.assign(item,{source_id:profile()?.id,machine_id:actionContext.overrides.machine_id,databases:[]});
    const job={id:'demo-'+Date.now(),action:action,label:plan.label,target:plan.target,status:'succeeded',created_at:new Date().toISOString(),events:[{time:new Date().toISOString(),message:uiText("Đây là tác vụ minh họa, không thực thi lệnh.")}],result};
    if(action==='ubuntu_upgrade')Object.assign(job,{machine_id:actionContext.overrides.machine_id,series:plan.ubuntu.series});
    demoJobs.unshift(job);if(job.action==='backups')backupItems=result;showJob(job);updateChrome();return;
  }
  const payload={plan_id:plan.id,confirmation};
  if(action==='ubuntu_upgrade')payload.backup_confirmed=!!$('#modal [name=backup_confirmed]')?.checked;
  const job=await api('/jobs',{method:'POST',body:JSON.stringify(payload)});showJob(job);await refreshState();
}
async function checkMachine(machineId){
  const machine=machines().find(item=>item.id===machineId);
  if(!machine)return;
  const plan=demo?{label:schemas.preflight.title,target:machine.name,params:{},notices:[],confirmation:''}:
    await api('/plans',{method:'POST',body:JSON.stringify({action:'preflight',machine_id:machineId,profile_id:'',params:{}})});
  await runPlan('preflight',plan,'');
}
function showPreview(plan){
  previewPlan=plan;
  const schema=schemas[actionContext.action];
  const labels={application_only:dataLabel('Tất cả database ứng dụng','All application databases'),databases:dataLabel('Database nguồn','Source databases'),destination_id:dataLabel('Cụm đích','Destination cluster'),...Object.fromEntries(schema.fields.map(f=>[f[0],f[1]]))};
  if(plan.install_blocked){
    modal(uiText('Cài MongoDB'),`<div class="modal-body"><strong>${esc(plan.target)}</strong><p>${esc(plan.install_blocked)}</p></div>`,
      button(uiText('Quay lại'),'action-back')+button(dataLabel('Quản lý Ubuntu','Manage Ubuntu'),'ubuntu-install-plan','server','primary'));
    return;
  }
  if(plan.ubuntu){
    const i=plan.ubuntu, host=actionContext.overrides.machine_id;
    const back=button(uiText('Quay lại'),'action-back');
    const install=button(uiText('Cài MongoDB'),'ubuntu-install','server','primary',`data-id="${esc(host)}" data-series="${esc(i.series)}"`);
    const confirm=!i.blocked&&i.path.length&&i.version?field('backup_confirmed',dataLabel('Tôi đã có bản sao lưu có thể phục hồi','I have a recoverable backup'),false,'checkbox'):'';
    const rows=[
      [dataLabel('Ubuntu hiện tại','Current Ubuntu'),i.os],
      [dataLabel('Kiến trúc CPU','CPU architecture'),i.arch],
      [i.version?dataLabel('MongoDB đang chạy','Running MongoDB'):dataLabel('MongoDB dự định cài','Planned MongoDB'),i.version||i.series],
      [dataLabel('Lộ trình Ubuntu','Ubuntu release path'),i.route||'—']];
    const summary=rows.map(([label,value])=>`<div class="review-row"><span>${label}</span><strong>${esc(value)}</strong></div>`).join('');
    modal(dataLabel('Ubuntu trên ','Ubuntu on ')+esc(plan.target),`<div class="modal-body"><div class="review-params">${summary}</div><div class="callout">${plan.notices.map(esc).join('<br>')}</div>${confirm}<div id="form-error"></div></div>`,
      back+(!i.blocked&&i.path.length?button(dataLabel('Nâng Ubuntu','Upgrade Ubuntu'),'action-apply','arrow','primary'):(i.version||i.blocked)?'':install));
    return;
  }
  let electionPicker='';
  if(actionContext.action==='step_down'){
    const options=[{value:'',label:uiText("Để MongoDB tự bầu")}];
    for(const m of currentStatus?.members||[]){
      if(m.state==='SECONDARY'&&m.health===1&&m.votes===1&&m.priority>0){
        const key=JSON.stringify(['mongo-manager-member',demo,actionContext.profileId,m.id,m.host]);
        const name=localStorage.getItem(key)||machines().find(v=>v.profile_id===actionContext.profileId&&v.mongo_endpoint===m.host)?.name;
        options.push({value:m.host,label:name?name+' · '+m.host:m.host});
      }
    }
    electionPicker=field('next_primary',uiText("Primary mong muốn"),'','select',uiText("Chỉ secondary khỏe có Votes = 1 và Ưu tiên > 0 mới xuất hiện."),true,options);
  }
  modal(uiText("Xác nhận thao tác"),`<div class="modal-body"><div class="review-params"><div class="review-row"><span>${uiText("Tác vụ")}</span><span>${esc(plan.label)}</span></div><div class="review-row"><span>${uiText("Máy / cụm đích")}</span><span>${esc(plan.target)}</span></div>${Object.entries(plan.params).map(([k,v])=>`<div class="review-row"><span>${esc(labels[k]||k)}</span><span>${esc(k==='destination_id'?(profiles().find(p=>p.id===v)?.name||v):k==='databases'?(v.join(', ')||uiText('Tất cả')):typeof v==='boolean'?(v?uiText("Bật"):uiText("Tắt")):v||'—')}</span></div>`).join('')}</div>${electionPicker}${plan.notices.map(n=>`<div class="callout">${esc(n)}</div>`).join('')}${demo?("<div class=\"callout neutral\">"+uiText("Đây là mô phỏng. Không có lệnh nào được gửi đến máy chủ.")+"</div>"):''}<div id="form-error"></div></div>`,(['remove_member','step_down'].includes(actionContext.action)?button(uiText("Hủy"),'modal-close'):button(uiText("Quay lại"),'action-back'))+button(demo?uiText("Chạy mô phỏng"):uiText("Thực hiện"),'action-apply','check','primary'));
}
function showJob(job){
  jobId=job.id;
  if(job.status==='succeeded'&&job.action==='backup'&&job.result?.archives&&job.profile_id===profile()?.id){
    const archive=job.result;
    backupItems=[archive,...backupItems.filter(b=>b.id!==archive.id&&b.machine_id===archive.machine_id)].sort((a,b)=>b.time.localeCompare(a.time));
  }
  if(job.action==='backups'&&job.status==='succeeded'&&Array.isArray(job.result)){
    catalogLoading=false;catalogError='';backupItems=job.result;
    backupListedHost={name:job.target,id:job.machine_id||job.result[0]?.machine_id};
    modal(esc(job.label),`<div class="modal-body"><p>${esc(job.target)} · ${job.result.length} backup</p>${backupCatalog()}</div>`,button(uiText('Đóng'),'modal-close'));
    return;
  }
  const running=['queued','running'].includes(job.status);
  let footer=button(uiText('Đóng'),'modal-close');
  if(job.action==='ubuntu_upgrade'&&!running){
    const install=job.status==='succeeded'&&!job.result?.version;
    const action=install?'ubuntu-install':job.status==='failed'?'ubuntu-verify':'ubuntu-recheck';
    const attrs=`data-job="${esc(job.id)}" data-id="${esc(job.machine_id)}" data-series="${esc(job.series)}"`;
    footer+=button(uiText(install?'Cài MongoDB':'Kiểm tra lại'),action,'','primary',attrs);
  }
  modal(esc(job.label),`${running?'<div class="progress-track"><i></i></div>':''}<div class="modal-body job-detail"><div class="actions">${jobBadge(job)}<span class="mono">${esc(job.target)}</span></div>${job.error?errorBox(job.error):''}<pre class="terminal">${job.events.map(e=>`<small>${esc(formatDate(e.time))}</small>  ${esc(e.message)}`).join('\n')||uiText("Đang chờ tác vụ…")}</pre>${job.result?`<div><div class="notice-label">${uiText("Kết quả")}</div><pre>${esc(typeof job.result==='string'?job.result:JSON.stringify(job.result,null,2))}</pre></div>`:''}</div>`,footer);
}
async function openJob(id){
  const job=demo?demoJobs.find(j=>j.id===id):await api('/jobs/'+id);
  if(!job){toast(uiText("Không tìm thấy tác vụ."),true);return;}
  showJob(job);
  if(job.action==='backups'&&job.status==='succeeded')backupItems=job.result;
}
async function runDiagnostics(){
  if(!profile()){showRecord('profiles');return;}
  const data=demo?[{host:'203.0.113.10:27017',ok:true,role:'PRIMARY'},{host:'203.0.113.11:27017',ok:true,role:'SECONDARY'},{host:'203.0.113.12:27017',ok:true,role:'SECONDARY'}]:await api(`/profiles/${profile().id}/query/diagnostics`);
  modal(uiText("Kết quả chẩn đoán"),`<div class="modal-body"><div class="callout neutral">${uiText("Kiểm tra từ máy đang chạy web. Kết quả không thay thế kiểm tra mạng hai chiều giữa các member.")}</div>${table(['ENDPOINT',uiText("KẾT QUẢ"),(uiText("VAI TRÒ")+" / GHI CHÚ")],data.map(r=>`<tr><td class="mono">${esc(r.host)}</td><td>${badge(r.ok?uiText("Kết nối được"):uiText("Thất bại"),r.ok?'success':'error')}</td><td>${esc(r.ok?r.role:r.error)}${r.note?'<br><small>'+esc(r.note)+'</small>':''}</td></tr>`))}</div>`,button(uiText("Đóng"),'modal-close'));
}
async function saveRecord(form){
  let data=Object.fromEntries(new FormData(form));const ctx=recordContext;
  if(ctx.kind==='profiles'){data=profileFormData(form);data.machines=clusterSSHData();}
  else {data.profile_id=ctx.profileId;data.port=Number(data.port||22);if(!data.ssh_password)data.ssh_password=null;}
  if(demo){toast(uiText("Hồ sơ xem thử không được lưu. Chuyển sang dữ liệu thật để kết nối."));$('#modal').close();return;}
  const adopted=ctx.kind==='profiles'?await api('/profiles/adopt',{method:'POST',body:JSON.stringify({...data,record_id:ctx.id||''})}):null;
  const saved=adopted?adopted.profile:await api('/'+ctx.kind+(ctx.id?'/'+ctx.id:''),{method:ctx.id?'PUT':'POST',body:JSON.stringify(data)});
  if(ctx.kind==='profiles'){if(!profile()){selected=saved.id;localStorage.setItem('mongo-manager-profile',selected);}currentStatus=null;}
  $('#modal').close();toast(uiText("Đã lưu hồ sơ."));await refreshState();await render();if(ctx.kind==='machines'&&pendingJoin){pendingJoin=false;openAction('join_fresh',{...pendingJoinOptions,machine_id:saved.id});pendingJoinOptions={};}
}
document.addEventListener('submit',async event=>{
  if(!['record-form','action-form'].includes(event.target.id))return;
  event.preventDefault();const submit=$('button[type="submit"]',event.target);submit.disabled=true;
  try{
    if(event.target.id==='record-form')await saveRecord(event.target);
    else{
      const schema=schemas[actionContext.action];const data=Object.fromEntries(new FormData(event.target));const params={};
      for(const f of schema.fields){params[f[0]]=f[3]==='checkbox'?event.target.elements[f[0]].checked:(f[3]==='number'||f[0]==='votes')?Number(event.target.elements[f[0]].value):data[f[0]];}
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
      actionContext.overrides={...params,machine_id:data.machine_id};
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
      if(demo&&actionContext.action==='ubuntu_upgrade'){
        const route={auto:'22.04',jammy:'22.04',noble:'24.04',resolute:'26.04',focal:'20.04'};
        const blocked=params.target==='focal'||(params.series==='8.0'&&params.target==='resolute');
        const path=blocked||['auto','jammy'].includes(params.target)?[]:params.target==='noble'?['noble']:['noble','resolute'];
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
    if(act==='compatibility-refresh'){await loadCompatibility();return;}
    if(act==='ubuntu-open'){openAction('ubuntu_upgrade',{machine_id:$('[name="compatibility_host"]')?.value,series:$('#compatibility-report')?.dataset.series||'9.0'});return;}
    if(act==='ubuntu-install-plan'){openAction('ubuntu_upgrade',actionContext.overrides);return;}
    if(act==='ubuntu-from-install'){
      const form=$('#action-form');
      openAction('ubuntu_upgrade',{machine_id:form.elements.machine_id.value,series:form.elements.series.value});return;
    }
    if(act==='ubuntu-install'){
      const host=machines().find(m=>m.id===target.dataset.id);
      if(!host||(host.profile_id||'')!==(profile()?.id||'')){toast(dataLabel('Máy đích đã thay đổi workspace. Mở lại máy để tiếp tục.','Open the target server in its current workspace to continue.'),true);return;}
      openAction('install',{machine_id:host.id,series:target.dataset.series});return;
    }
    if(act==='ubuntu-verify'){
      const attrs=`data-job="${esc(target.dataset.job)}" data-id="${esc(target.dataset.id)}" data-series="${esc(target.dataset.series)}"`;
      modal(dataLabel('Tiếp tục tác vụ Ubuntu','Resume Ubuntu upgrade'),
        `<div class="modal-body">${dataLabel('Manager sẽ đọc trạng thái trên VPS và tiếp tục các bước còn lại của chặng đã xác nhận. Máy có thể khởi động lại.','Manager will check the host and resume the remaining confirmed steps. The server may reboot.')}</div>`,
        button(uiText('Hủy'),'modal-close')+button(uiText('Tiếp tục'),'ubuntu-verify-apply','','primary',attrs));return;
    }
    if(act==='ubuntu-verify-apply'){
      target.disabled=true;
      try{showJob(await api('/jobs/'+target.dataset.job+'/verify-ubuntu',{method:'POST',body:'{}'}));}
      catch(error){toast(error.message,true);openAction('ubuntu_upgrade',{machine_id:target.dataset.id,series:target.dataset.series});}
      return;
    }
    if(act==='ubuntu-recheck'){openAction('ubuntu_upgrade',{machine_id:target.dataset.id,series:target.dataset.series});return;}
    if(act==='password-toggle'){event.preventDefault();await togglePassword(target);return;}
    if(act==='preflight'&&target.dataset.id){target.disabled=true;await checkMachine(target.dataset.id);return;}
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
      fields.name.value=name;
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
    if(act==='node-ssh-new'){pendingJoin=true;showRecord('machines');return;}
    if(act==='machine-edit'){showRecord('machines',machines().find(m=>m.id===target.dataset.id));return;}
    if(act==='record-delete'||act==='profile-delete'||act==='machine-delete'){
      const ctx=act==='profile-delete'?{kind:'profiles',id:target.dataset.id||profile()?.id}:act==='machine-delete'?{kind:'machines',id:target.dataset.id}:recordContext;
      if(!ctx.id)return;
      const label=ctx.kind==='profiles'?profiles().find(p=>p.id===ctx.id)?.name:machines().find(m=>m.id===ctx.id)?.name;
      if(demo){toast(uiText("Không xóa hồ sơ minh họa."));return;}
      if(!await confirmProfileDeletion(label||ctx.id))return;
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
    if(act==='member-remove'||act==='step-down'){
      target.disabled=true;
      const cluster=profile();
      if(!cluster){showRecord('profiles');return;}
      const action=act==='step-down'?'step_down':'remove_member';
      const params=action==='step_down'?{}:{host:target.dataset.host};
      const plan=demo?{label:schemas[action].title,target:cluster.name,params,notices:[schemas[action].note],confirmation:cluster.name}:
        await api('/plans',{method:'POST',body:JSON.stringify({action,profile_id:cluster.id,params})});
      actionContext={action,profileId:cluster.id,overrides:params};
      showPreview(plan);
      return;
    }
    if(act==='action-back'){openAction(actionContext.action,actionContext.overrides);return;}
    if(act==='action-apply'){
      const backup=$('#modal [name=backup_confirmed]');
      if(backup&&!backup.checked){formError(dataLabel('Xác nhận bản sao lưu trước khi nâng Ubuntu.','Confirm the backup before upgrading Ubuntu.'));return;}
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
    if(jobId){const job=await api('/jobs/'+jobId);if($('#modal').open&&jobId===job.id){showJob(job);if(job.status==='succeeded'&&job.action==='backups')backupItems=job.result;if(!['queued','running'].includes(job.status)){jobId=null;await refreshState();await render();return;}}}
    else {
      const pending=jobs().filter(j=>['queued','running'].includes(j.status));
      if(pending.length){
        await refreshState();
        if(jobs().some(j=>pending.some(old=>old.id===j.id)&&!['queued','running'].includes(j.status))){await render();return;}
        if(currentRoute==='jobs')$('#content').innerHTML=jobsPage();
      }
    }
  }catch(error){toast(error.message,true);jobId=null;}
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
function showLogin(message=''){
  clearInterval(pollTimer);csrfToken='';jobId=null;state={profiles:[],machines:[],jobs:[]};currentStatus=null;
  if($('#modal').open)$('#modal').close();$('#content').replaceChildren();document.body.classList.add('auth-pending');
  $('#logout-button').hidden=true;const root=$('#login-root');root.hidden=false;
  root.innerHTML=`<form id="login-form" class="login-card">${languagePicker()}<div class="brand"><span class="brandmark">m</span><span>MongoDB Manager</span></div><div class="eyebrow">${uiText("QUẢN TRỊ HỆ THỐNG")}</div><h1>${uiText("Đăng nhập")}</h1><p>${uiText("Quản lý các cụm MongoDB và VPS của bạn.")}</p><label class="field"><span>Username</span><input name="username" autocomplete="username" required maxlength="80"></label><label class="field"><span>${uiText("Mật khẩu")}</span>${passwordControl('<input name="password" type="password" autocomplete="current-password" required maxlength="1000">')}</label><div id="login-error" role="alert">${message?errorBox(message):''}</div><button type="submit" class="button primary">${uiText("Đăng nhập")}</button><small>${uiText("Phiên tự hết hạn sau 30 phút không hoạt động.")}</small></form>`;
}
async function enterWorkspace(auth){
  csrfToken=auth.csrf||'';$('#login-root').replaceChildren();$('#login-root').hidden=true;document.body.classList.remove('auth-pending');
  $('#logout-button').hidden=!auth.enabled;$('#logout-button').textContent=auth.username?auth.username+(" "+uiText("· Đăng xuất")):uiText("Đăng xuất");
  $('#admin-avatar').textContent=(auth.username||'AD').slice(0,2).toUpperCase();
  await refreshState();await render();clearInterval(pollTimer);pollTimer=setInterval(poll,2500);
}
document.addEventListener('submit',async event=>{
  if(event.target.id!=='login-form')return;event.preventDefault();
  const form=event.target,submit=form.querySelector('button[type="submit"]');submit.disabled=true;$('#login-error').replaceChildren();
  try{const result=await api('/auth/login',{method:'POST',body:JSON.stringify(Object.fromEntries(new FormData(form)))});form.elements.password.value='';await enterWorkspace({...result,enabled:true});}
  catch(error){const output=$('#login-error');if(output)output.innerHTML=errorBox(error.message);else toast(error.message,true);}
  finally{submit.disabled=false;}
});
async function boot(){
  try{const auth=await api('/auth/status');if(!auth.authenticated){showLogin();return;}await enterWorkspace(auth);}
  catch(error){showLogin(error.message);}
}
boot();
