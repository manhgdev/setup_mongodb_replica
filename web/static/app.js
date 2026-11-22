'use strict';
const $ = (q, root = document) => root.querySelector(q);
const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const paths = {
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
  ['overview','Tổng quan','grid','QUẢN LÝ'],['clusters','Các cụm MongoDB','cluster'],['machines','Máy chủ','server'],['replica','Replica Set','cluster'],['users','User & phân quyền','users'],
  ['backup','Backup & restore','backup','VẬN HÀNH'],['data','Dữ liệu','db'],['settings','Cấu hình','settings'],['diagnostics','Chẩn đoán','pulse'],['upgrade','Phiên bản & nâng cấp','arrow'],['jobs','Lịch sử tác vụ','clock'],
];
let state = {profiles:[],machines:[],jobs:[]};
let demo = localStorage.getItem('mongo-manager-demo') === 'true';
let selected = localStorage.getItem('mongo-manager-profile') || '';
let currentRoute = 'overview', currentStatus = null, statusError = '', renderId = 0, pollTimer = null;
let topologyBusy=false, topologyChecked=0;
let actionContext = null, recordContext = null, previewPlan = null, jobId = null, backupItems = [];
const demoProfiles = [{id:'demo-production',name:'Production',seeds:['203.0.113.10:27017','203.0.113.11:27017','203.0.113.12:27017'],replica_set:'rs0',username:'admin',auth_db:'admin',tls:false,has_password:true}];
const demoMachines = [10,11,12].map((n,i)=>({id:`demo-${n}`,name:`mongo-${String(i+1).padStart(2,'0')}`,mode:'ssh',host:`203.0.113.${n}`,port:22,user:'root',service:'mongod',identity:'',profile_id:'demo-production',mongo_endpoint:`203.0.113.${n}:27017`}));
const demoStatus = {connected:true,version:'9.0.4',fcv:'9.0',replica_set:'rs0',primary:'203.0.113.10:27017',voters:3,healthy_voters:3,majority:2,quorum:true,warnings:[],members:[
  {id:0,host:'203.0.113.10:27017',state:'PRIMARY',health:1,uptime:86400*12,lag:0,priority:1,votes:1},
  {id:1,host:'203.0.113.11:27017',state:'SECONDARY',health:1,uptime:86400*12,lag:0.2,priority:1,votes:1},
  {id:2,host:'203.0.113.12:27017',state:'SECONDARY',health:1,uptime:86400*12,lag:0.1,priority:1,votes:1}]};
const demoJobs = [
 {id:'demo-backup',action:'backup',label:'Backup toàn bộ replica set',target:'Production',status:'succeeded',created_at:new Date(Date.now()-3600000).toISOString(),events:[{time:new Date().toISOString(),message:'Bản backup minh họa đã hoàn tất.'}],result:{size:'2.4 GB',sha256:'Dữ liệu minh họa'}},
 {id:'demo-health',action:'preflight',label:'Kiểm tra môi trường',target:'mongo-01',status:'succeeded',created_at:new Date(Date.now()-7200000).toISOString(),events:[],result:{os:'Ubuntu 26.04 LTS',architecture:'x86_64',service_state:'active'}},
 {id:'demo-add',action:'add_member',label:'Thêm Secondary mongo-03',target:'Production',status:'succeeded',created_at:new Date(Date.now()-86400000).toISOString(),events:[],result:{ready:true}}
];
const profiles = () => demo ? demoProfiles : state.profiles;
const machines = () => demo ? demoMachines : state.machines;
const jobs = () => demo ? demoJobs : state.jobs;
const profile = () => profiles().find(p=>p.id===selected) || profiles()[0];
const badge = (text, tone='') => `<span class="badge ${tone}">${esc(text)}</span>`;
const button = (label, act, glyph='', tone='', attrs='') => `<button type="button" class="button ${tone}" data-act="${act}" ${attrs}>${glyph?icon(glyph):''}${label}</button>`;
const formatDate = s => s ? new Date(s).toLocaleString('vi-VN',{day:'2-digit',month:'2-digit',hour:'2-digit',minute:'2-digit'}) : '—';
const bytes = n => !Number.isFinite(n) ? '—' : n>=1024**3?`${(n/1024**3).toFixed(1)} GB`:n>=1024**2?`${(n/1024**2).toFixed(1)} MB`:`${(n/1024).toFixed(1)} KB`;
const statusNames = {queued:'Đang chờ',running:'Đang chạy',succeeded:'Hoàn tất',failed:'Thất bại',interrupted:'Bị gián đoạn'};
const jobBadge = j => badge(statusNames[j.status]||j.status, j.status==='succeeded'?'success':j.status==='failed'||j.status==='interrupted'?'error':'warn');
let csrfToken='';
async function api(path, options={}) {
  const response = await fetch('/api'+path,{...options,headers:{'X-MongoDB-Manager':'1','Content-Type':'application/json',...(csrfToken?{'X-CSRF-Token':csrfToken}:{}),...options.headers}});
  const data = await response.json();
  if(response.status===401&&path!=='/auth/login')showLogin('Phiên đăng nhập đã hết hạn. Đăng nhập lại để tiếp tục.');
  if(!response.ok) throw new Error(typeof data.detail==='string'?data.detail:Array.isArray(data.detail)?data.detail.map(x=>x.msg).join('; '):'Yêu cầu thất bại.');
  return data;
}
function toast(message,error=false){const el=document.createElement('div');el.className='toast'+(error?' error':'');el.textContent=message;$('#toasts').append(el);setTimeout(()=>el.remove(),5500);}
function errorBox(message){return `<div class="callout error">${esc(message)}</div>`;}
function empty(title,message,action='profile-new',label='Kết nối cụm MongoDB',glyph='cluster'){return `<div class="empty"><span class="empty-icon">${icon(glyph)}</span><h2>${title}</h2><p>${message}</p>${action?button(label,action,'plus','primary'):''}</div>`;}
function heading(title,desc,actions=''){return `<div class="page-heading"><div><div class="eyebrow">MONGODB WORKSPACE</div><h1>${title}</h1><p>${desc}</p></div><div class="actions">${actions}</div></div>`;}
function panel(title,body,subtitle='',actions=''){return `<section class="panel"><div class="panel-head"><div><h2>${title}</h2>${subtitle?`<p>${subtitle}</p>`:''}</div>${actions}</div>${body}</section>`;}
function metric(label,value,note,glyph,good=false){return `<article class="metric"><div class="metric-head">${label}<span class="metric-icon">${icon(glyph)}</span></div><div class="metric-value">${value}</div><div class="metric-note ${good?'good':''}">${good?'<span class="dot green"></span>':''}${note}</div></article>`;}
function table(headers,rows){return `<div class="table-wrap"><table><thead><tr>${headers.map(h=>`<th>${h}</th>`).join('')}</tr></thead><tbody>${rows.join('')}</tbody></table></div>`;}
function updateChrome(){
  $('#navigation').innerHTML=nav.map(([id,title,glyph,group])=>`${group?`<div class="nav-label">${group}</div>`:''}<a class="nav-link ${currentRoute===id?'active':''}" href="#${id}">${icon(glyph)}<span>${title}</span>${id==='jobs'&&jobs().some(j=>j.status==='running')?'<span class="nav-count">LIVE</span>':''}</a>`).join('');
  $('#profile-select').innerHTML=profiles().length?profiles().map(p=>`<option value="${esc(p.id)}" ${profile()?.id===p.id?'selected':''}>${esc(p.name)}</option>`).join(''):'<option>Chưa có cụm</option>';
  $('#breadcrumb').textContent=nav.find(n=>n[0]===currentRoute)?.[1]||'Tổng quan';
  $('#demo-toggle').textContent=demo?'● Đang xem thử':'Xem thử giao diện';
  $('#demo-banner').hidden=!demo;
  $('#footer-time').textContent=demo?'Chế độ minh họa':'127.0.0.1 · Local workspace';
}
async function refreshState(){if(!demo)state=await api('/state');updateChrome();}
function topology(s){
  const primary=s?.members.find(m=>m.state==='PRIMARY');
  const others=s?.members.filter(m=>m!==primary)||[];
  if(!primary)return `<div class="topology">${empty('Chưa có topology','Kết nối cụm để xem các thành viên.','','')}</div>`;
  return `<div class="topology"><div class="topo-main"><span class="node-icon">${icon('db')}</span><div class="node-name">${demo?'mongo-01':'Primary'}</div>${badge('PRIMARY','success')}<div class="node-address">${esc(primary.host)}</div></div>${others.length?`<div class="branches">${others.slice(0,3).map((m,i)=>`<div class="topo-child"><div class="node-name">${demo?`mongo-0${i+2}`:`Member ${m.id}`}</div>${badge(m.state,m.health?'blue':'error')}<div class="node-address">${esc(m.host)}</div></div>`).join('')}</div>`:'<div class="topology-empty">Thêm secondary để tạo bản sao dữ liệu.</div>'}</div><div class="panel-foot"><span class="legend"><span class="dot green"></span> ${s.members.filter(m=>m.health).length} member đang hoạt động</span><span>${esc(s.replica_set)}</span></div>`;
}
function memberTable(s,full=false){
  if(!s?.members.length)return empty('Chưa đọc được thành viên','Kiểm tra kết nối và quyền xem replica set.','','');
  return table(['THÀNH VIÊN','VAI TRÒ','TRẠNG THÁI','ĐỘ TRỄ','VOTES / PRIORITY',full?'THAO TÁC':'UPTIME'],s.members.map((m,i)=>`<tr><td><div class="host-cell"><span class="server-icon">${icon('server')}</span><div><strong>${demo?`mongo-0${i+1}`:`Member ${m.id}`}</strong><small class="mono">${esc(m.host)}</small></div></div></td><td>${badge(m.state,m.state==='PRIMARY'?'success':m.state==='SECONDARY'?'blue':'warn')}</td><td><span class="legend"><span class="dot ${m.health?'green':''}"></span>${m.health?'Healthy':'Không reachable'}</span></td><td class="mono">${m.lag==null?'—':`${m.lag} s`}</td><td class="mono">${m.votes} / ${m.priority}</td><td>${full?`${button('Sửa','member-edit','','small',`data-host="${esc(m.host)}"`)} ${button('Gỡ','member-remove','','small',`data-host="${esc(m.host)}"`)}`:`${Math.floor(m.uptime/86400)} ngày`}</td></tr>`));
}
function overview(){
  const p=profile(),s=currentStatus;
  let html=heading('Tổng quan cụm','Theo dõi hệ thống và quản lý MongoDB của bạn.',button('Làm mới','refresh','refresh')+button('Thêm node','node-add','plus','primary'));
  if(!p){
    html+=`<div class="welcome"><div><div class="eyebrow">CHÀO MỪNG ĐẾN WORKSPACE</div><h2>Một nơi để quản lý<br>mọi node MongoDB.</h2><p>Kết nối cụm đang chạy hoặc cài MongoDB trên VPS mới. Bắt đầu từ một node và mở rộng khi bạn cần.</p><div class="actions">${button('Kết nối cụm','profile-new','plus','primary')}${button('Cài đặt VPS mới','provision','server')}</div></div><div class="welcome-art">${icon('cluster')}</div></div>`;
    html+=`<div class="metrics">${metric('Cụm đã kết nối','0','Thêm hồ sơ để bắt đầu','cluster')}${metric('Máy chủ',String(machines().length),'Local hoặc SSH','server')}${metric('Tác vụ',String(jobs().length),'Lịch sử được lưu trên máy này','clock')}${metric('Phiên bản hỗ trợ','8 / 9','Ubuntu 22.04 · 24.04 · 26.04','db')}</div>`;
    html+=quickActions();
    html+=`<div class="callout neutral" style="">Chưa có kết nối thật. Bạn có thể chọn “Xem thử giao diện” ở góc trên để khám phá với dữ liệu minh họa.</div>`;
    return html;
  }
  if(statusError)html+=errorBox(statusError);
  const healthy=s?.members.filter(m=>m.health===1).length||0;
  const lags=s?.members.filter(m=>m.state==='SECONDARY').map(m=>m.lag).filter(v=>v!=null)||[];
  const backup=jobs().find(j=>j.action==='backup'&&j.status==='succeeded');
  html+=`<div class="metrics">${metric('Trạng thái cụm',s?.connected?'Đã kết nối':'Chưa rõ',s?.quorum?'Đủ số phiếu cho majority':'Chưa xác minh quorum','pulse',!!s?.quorum)}${metric('Thành viên',`${s?.members.length??'—'} <small>nodes</small>`,`${healthy} healthy · ${Math.max(0,(s?.members.length||0)-healthy)} cần kiểm tra`,'server',!!healthy)}${metric('Replication lag',lags.length?`${Math.max(...lags)} <small>giây</small>`:'—',lags.length?'Độ trễ lớn nhất trên secondary':'Chưa có dữ liệu secondary','clock',lags.length>0)}${metric('Backup gần nhất',backup?formatDate(backup.created_at).split(' ')[0]:'—',backup?'Tác vụ backup đã hoàn tất':'Chưa ghi nhận backup','backup',!!backup)}</div>`;
  html+=`<div class="layout-two">${panel('Sơ đồ replica set',topology(s),'Cấu trúc và vai trò của các thành viên',badge(s?.replica_set||p.replica_set,'dark'))}${panel('Sức khỏe hệ thống',`<div class="health-list"><div class="health-row"><span>MongoDB Community</span><strong>${esc(s?.version||'—')}</strong></div><div class="health-row"><span>Feature Compatibility</span><strong>${esc(s?.fcv||'—')}</strong></div><div class="health-row"><span>Phiếu đang hoạt động</span><strong>${s?.healthy_voters??'—'} / ${s?.voters??'—'}</strong></div><div class="health-row"><span>Xác thực</span><strong>${p.username?'Username / password':'Không có user'}</strong></div><div class="health-row"><span>Mã hóa TLS</span><strong>${p.tls?'Đã bật':'Tắt'}</strong></div></div><div class="health-summary">${icon('shield')}<span>${s?.warnings?.length?esc(s.warnings[0]):s?.connected?(demo?'Thông số minh họa để xem trước giao diện.':'Các thông số được đọc trực tiếp từ MongoDB.'):'Kết nối MongoDB để kiểm tra trạng thái.'}</span></div>`,'Tự cập nhật mỗi 10 giây · '+(s?.checked_at?formatDate(s.checked_at):'Chưa có kiểm tra thật'))}</div>`;
  html+=panel('Thành viên trong cụm',memberTable(s),'Danh sách các node đã tham gia replica set',`<a class="text-button" href="#replica">Quản lý thành viên →</a>`);
  html+=quickActions();
  if(jobs().length)html+=panel('Hoạt động gần đây',activityList(jobs().slice(0,3)),'',`<a class="text-button" href="#jobs">Xem tất cả →</a>`);
  return html;
}
function quickActions(){if(profile())return `<div class="section-title"><h2>Thao tác trong cụm</h2></div><div class="button-row">${button('Thêm Secondary','node-add','plus')}${button('Tạo backup','backup-new','backup')}${button('Kiểm tra kết nối','diagnose','pulse')}${button('Nhật ký VPS','logs','terminal')}</div>`;return `<div class="section-title"><h2>Thao tác nhanh</h2><span class="page-number">WORKSPACE TOOLS</span></div><div class="quick-grid"><button class="quick-card" data-act="provision"><span class="quick-icon">${icon('server')}</span><span><strong>Cài đặt MongoDB</strong><small>Chuẩn bị VPS và tạo replica set</small></span><span class="quick-arrow">↗</span></button><button class="quick-card" data-act="backup-new"><span class="quick-icon">${icon('backup')}</span><span><strong>Tạo bản backup</strong><small>Lưu lại dữ liệu của cụm</small></span><span class="quick-arrow">↗</span></button><button class="quick-card" data-act="diagnose"><span class="quick-icon">${icon('pulse')}</span><span><strong>Kiểm tra kết nối</strong><small>Chẩn đoán các node từ máy quản trị</small></span><span class="quick-arrow">↗</span></button></div><div class="section-title"></div>`;}
function activityList(list){return `<div class="activity">${list.map(j=>`<div class="activity-row"><span class="activity-icon">${icon(j.status==='succeeded'?'check':'clock')}</span><div class="activity-text"><button class="text-button" data-act="job-open" data-id="${esc(j.id)}">${esc(j.label)}</button><small>${esc(j.target)}</small></div><span class="activity-time">${formatDate(j.created_at)}</span>${jobBadge(j)}</div>`).join('')}</div>`;}
function clustersPage(){
 return heading('Các cụm MongoDB','Thêm, sửa kết nối hoặc xóa hồ sơ cụm khỏi ứng dụng.',button('Thêm cụm','profile-new','plus','primary'))+onboardingCards()+panel('Danh sách cụm',profiles().length?table(['TÊN CỤM','REPLICA SET','SEED / MEMBER','THAO TÁC'],profiles().map(p=>`<tr><td><strong>${esc(p.name)}</strong></td><td>${esc(p.replica_set||'Standalone')}</td><td class="mono">${p.seeds.map(esc).join('<br>')}</td><td><div class="actions">${button('Mở','profile-open','','small',`data-id="${esc(p.id)}"`)}${button('Sửa','profile-edit','','small',`data-id="${esc(p.id)}"`)}${button('Xóa','profile-delete','trash','small danger',`data-id="${esc(p.id)}"`)}</div></td></tr>`)):empty('Chưa có cụm','Bấm Thêm cụm rồi nhập seed và tài khoản MongoDB.'))+`<div class="callout neutral">Xóa hồ sơ chỉ bỏ kết nối khỏi ứng dụng. Dữ liệu, user MongoDB và replica set trên VPS vẫn giữ nguyên.</div>`;
}
function machinePage(){
 let html=heading('Máy chủ','Quản lý kết nối SSH, cài đặt và dịch vụ trên từng máy.',button('Thêm máy chủ','machine-new','plus','primary'));
 if(!profile())html+=onboardingCards();
 html+=panel('Máy chủ của bạn',machines().filter(m=>!profile()||m.profile_id===profile().id).length?table(['MÁY CHỦ','KẾT NỐI','SERVICE','THAO TÁC'],machines().filter(m=>!profile()||m.profile_id===profile().id).map(m=>`<tr><td><div class="host-cell"><span class="server-icon">${icon('server')}</span><div><strong>${esc(m.name)}</strong><small>${esc(m.host)}</small></div></div></td><td>${badge(m.mode==='ssh'?'SSH':'LOCAL','dark')} <span class="mono">${esc(m.user)}:${m.port}</span></td><td class="mono">${esc(m.service)}<small>${esc(profiles().find(p=>p.id===m.profile_id)?.name||'Chưa liên kết cụm')}<br>${esc(m.mongo_endpoint||'')}</small></td><td><div class="actions">${button('Kiểm tra','preflight','pulse','small',`data-id="${esc(m.id)}"`)}${button('Dịch vụ','service','','small',`data-id="${esc(m.id)}"`)}${button('Sửa','machine-edit','','small',`data-id="${esc(m.id)}"`)}</div></td></tr>`)):empty('Thêm máy chủ đầu tiên','Kết nối bằng mật khẩu SSH, key/agent hoặc chọn Local để quản lý máy đang chạy web.','machine-new','Thêm máy chủ','server'));
 if(!profile())html+=`<div class="cards">${feature('Cài MongoDB Server','Kiểm tra repository và cài package Community 8.0 hoặc 9.0 đúng phiên bản Ubuntu.','server','install','Cài package')}${feature('Tạo replica set','Tạo instance mới với service riêng, keyfile và tài khoản quản trị.','cluster','setup','Bắt đầu setup')}${feature('Xem nhật ký dịch vụ','Đọc 100 dòng journal gần nhất của service đã cấu hình.','terminal','logs','Mở nhật ký')}</div>`;
 return html;
}

function onboardingCards(){return `<div class="cards onboarding">${feature('Cụm đã có primary / secondary','Nhập endpoint bất kỳ và tài khoản MongoDB. Tự nhận diện replica set và toàn bộ member; tiếp nhận để quản lý.','cluster','profile-new','Tiếp nhận cụm đang chạy')}${feature('VPS mới → Cụm mới','Thêm hồ sơ SSH, kiểm tra môi trường, cài package và tạo replica set một node cùng tài khoản quản trị.','server','provision','Cài và tạo cụm mới')}${feature('VPS mới → Secondary','Chọn cụm đích và một member nguồn (primary hoặc secondary). Đọc keyfile qua SSH, cấu hình node trống, thêm và chờ đồng bộ.','plus','join-fresh','Thêm VPS vào cụm')}</div>`;}
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
 output.innerHTML='<div class="callout neutral">Đang đăng nhập và đọc trạng thái cụm…</div>';$('#form-error').replaceChildren();
 try{
 const result=demo?{profile:demoProfiles[0],status:demoStatus}:await api('/profiles/probe',{method:'POST',body:JSON.stringify({...data,record_id:recordContext.id||''})});
 if(!form.isConnected)return;
 form.elements.replica_set.value=result.profile.replica_set;form.elements.seeds.value=result.profile.seeds.join('\n');
 output.innerHTML=`<div class="callout">${demo?'Minh họa':'Đã xác minh'}: ${esc(result.status.replica_set)} · ${result.status.members.length} member · Primary: ${esc(result.status.primary)}.</div>`;
 }catch(error){if(form.isConnected){output.replaceChildren();formError(error);}}
}
function addClusterSSH(record=null){
 const container=$('#cluster-ssh-list');if(!container)return;
 const index=recordContext.sshIndex++;const prefix='cluster_ssh_'+index+'_';
 const firstSeed=$('[name="seeds"]',$('#record-form')).value.split(/[\n,]+/)[0].trim();
 const host=firstSeed.startsWith('[')?firstSeed.slice(1,firstSeed.indexOf(']')):firstSeed.split(':')[0];
 const row=document.createElement('section');row.className='cluster-ssh-row';row.dataset.recordId=record?.id||'';row.dataset.prefix=prefix;row.dataset.hasPassword=record?.has_ssh_password?'1':'';
 const f=(name,...args)=>field(prefix+name,...args);
 row.innerHTML=`<div class="ssh-row-heading"><strong>SSH cho một VPS</strong>${button('Bỏ khỏi lần lưu','cluster-ssh-remove','','small')}</div><div class="form-grid">${f('name','Tên VPS',record?.name||'','text','Ví dụ: mongo-01')}${f('mongo_endpoint','Endpoint MongoDB trên VPS',record?.mongo_endpoint||firstSeed,'text','IP:port của member tương ứng; IP trống port dùng 27017.')}${f('host','Địa chỉ SSH',record?.host||host)}${f('port','Port SSH',record?.port||22,'number')}${f('user','User SSH',record?.user||'root')}${f('ssh_auth','Xác thực SSH',record?.ssh_auth||'password','select','',false,[{value:'password',label:'Mật khẩu SSH'},{value:'key',label:'SSH key / Agent'}])}${f('ssh_password','Mật khẩu SSH','','password',record?.has_ssh_password?'Để trống để giữ mật khẩu đã lưu.':'Mật khẩu của tài khoản hệ điều hành trên VPS.',true)}${f('identity','SSH private key',record?.identity||'','text','Để trống để dùng agent.',true)}${f('service','Service MongoDB',record?.service||'mongod','text','Tên systemd service đang chạy.',true)}</div>`;
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
 const auth=value('ssh_auth');if(!value('name')||!value('host')||!value('mongo_endpoint'))throw new Error('SSH: nhập tên VPS, địa chỉ SSH và endpoint MongoDB tương ứng.');
 if(auth==='password'&&!secret&&!row.dataset.hasPassword)throw new Error('Nhập mật khẩu SSH cho VPS '+value('name')+'.');
 return {record_id:row.dataset.recordId,machine:{name:value('name'),mode:'ssh',host:value('host'),port:Number(value('port')),user:value('user'),ssh_auth:auth,ssh_password:auth==='password'?(secret||null):'',identity:auth==='key'?value('identity'):'',service:value('service'),mongo_endpoint:value('mongo_endpoint')}};
 });
}

function feature(title,desc,glyph,act,label){return `<article class="feature-card"><span class="quick-icon">${icon(glyph)}</span><h2>${title}</h2><p>${desc}</p>${button(label,act,'','')}</article>`;}
function replicaPage(){return heading('Replica Set','Quản lý thành viên, vai trò và cấu hình bầu chọn.',button('Thêm Arbiter','add-arbiter','plus')+button('Node đã chuẩn bị','prepared-node','plus')+button('Thêm node qua SSH','node-add','plus','primary'))+(statusError?errorBox(statusError):'')+panel('Thành viên',memberTable(currentStatus,true),'Secondary mới được thêm với votes = 0 và priority = 0.')+`<div class="cards">${feature('Step down Primary','Chuyển quyền primary qua cơ chế bầu chọn. Cần secondary sẵn sàng và đủ quorum.','cluster','step-down','Xem trước')}${feature('Write Concern','Xem và đặt mức xác nhận ghi cho replica set.','shield','write-concern','Cấu hình')}</div>`;}
function backupPage(){return heading('Backup & restore','Tạo bản sao dữ liệu, kiểm tra và khôi phục khi cần.',button('Đọc danh sách backup','backups-list','refresh')+button('Tạo backup','backup-new','plus','primary'))+`<div class="callout">Backup được lưu trên máy thực thi tại <code>/var/backups/mongodb-manager</code>. Bản toàn cụm có oplog; bản database/collection riêng không có oplog.</div>`+panel('Các bản backup',backupItems.length?table(['THỜI GIAN','NGUỒN / DATABASE','DUNG LƯỢNG','KIỂM CHỨNG',''],backupItems.map(b=>`<tr><td>${formatDate(b.time)}</td><td><strong>${esc(b.source)}</strong><br>${esc(b.database)}</td><td>${bytes(b.size)}</td><td>${badge('Có checksum','success')} ${badge(b.verified_restore?'Đã restore thử':'Chưa restore thử','warn')}</td><td>${button('Restore','restore','','small',`data-backup="${esc(b.id)}"`)}</td></tr>`)):empty('Chưa tải danh sách backup','Chọn máy thực thi để đọc các backup đã tạo bằng bộ quản lý.','backups-list','Chọn máy và đọc danh sách','backup'))+`<div class="cards compact-cards">${feature('Backup toàn cụm hoặc một phần','Chọn database và collection khi cần. Mỗi bản có checksum và manifest riêng.','backup','backup-new','Tạo bản sao')}${feature('Restore từ bản backup','Chọn đúng máy chứa backup và cụm đích. Xem lại toàn bộ thông tin trước khi ghi dữ liệu.','db','restore','Khôi phục dữ liệu')}</div>`;}
function sshSettingsPanel(){return panel('SSH cho tất cả các cụm',`<div class="panel-body"><p>Mỗi VPS giữ thông tin SSH riêng, không phụ thuộc vai trò primary/secondary. Có thể áp dụng cùng tài khoản cho các node được chọn, sau đó sửa riêng từng VPS khi cần.</p>${button('Cấu hình SSH nhiều VPS','ssh-bulk','server','primary')}</div>`);}
let pendingJoin=false,pendingJoinOptions={};
function showNodeAdd(){modal('Thêm node vào cụm',`<div class="modal-body"><div class="callout neutral">VPS mới cần SSH để kiểm tra, cài MongoDB và cấu hình trước khi thêm membership. Không dùng mật khẩu MongoDB làm mật khẩu SSH.</div><div class="cards compact-cards">${feature('Cài và cấu hình qua SSH','Kiểm tra VPS → cài nếu thiếu → lấy keyfile nguồn → tạo service → thêm member → chờ SECONDARY.','server','join-fresh','Chọn VPS đã lưu SSH')}${feature('Chưa nhập SSH của VPS mới','Thêm host, user/password hoặc key SSH của VPS đích rồi tiếp tục quy trình chuẩn bị node.','plus','node-ssh-new','Nhập SSH VPS mới')}</div><div class="section-title"></div>${button('Kiểm tra node đã chuẩn bị qua SSH','prepared-node')}</div>`,button('Đóng','modal-close'));}
let sshBulkTargets=[];
function openBulkSSH(){
 sshBulkTargets=[];
 for(const p of profiles())for(const endpoint of p.seeds){
   const existing=machines().find(m=>m.mode==='ssh'&&m.profile_id===p.id&&m.mongo_endpoint===endpoint);
   const host=endpoint.startsWith('[')?endpoint.slice(1,endpoint.indexOf(']')):endpoint.slice(0,endpoint.lastIndexOf(':'));
   sshBulkTargets.push({profile:p,endpoint,host,existing});
 }
 if(!sshBulkTargets.length){toast('Thêm cụm MongoDB trước để cấu hình SSH cho các member.');return;}
 const rows=sshBulkTargets.map((t,i)=>`<tr><td><input type="checkbox" name="targets" value="${i}" checked aria-label="Chọn ${esc(t.profile.name+' '+t.endpoint)}"></td><td>${esc(t.profile.name)}</td><td class="mono">${esc(t.endpoint)}</td><td>${badge(t.existing?.has_ssh_password?'Đã lưu mật khẩu':t.existing?'Key / Agent':'Chưa có SSH')}</td></tr>`);
 modal('SSH cho tất cả các cụm',`<form id="ssh-bulk-form"><div class="modal-body"><div class="callout neutral">Chọn các VPS thực sự dùng cùng thông tin SSH. Lưu chỉ cập nhật hồ sơ trên ứng dụng, không đổi mật khẩu trên VPS. Node thêm về sau cần được cấu hình riêng.</div>${table(['CHỌN','CỤM','MEMBER','SSH'],rows)}<div class="section-title"></div><div class="form-grid">${field('user','User SSH','root')}${field('port','Port SSH',22,'number')}${field('ssh_auth','Xác thực SSH','password','select','',true,[{value:'password',label:'Mật khẩu SSH'},{value:'key',label:'SSH key / Agent'}])}${field('ssh_password','Mật khẩu SSH','','password','Nhập để áp dụng cho các VPS đã chọn. Để trống chỉ giữ mật khẩu đã lưu; VPS chưa có cần nhập.',true)}${field('identity','SSH private key (tùy chọn)','','text','Chỉ dùng khi chọn Key / Agent.',true)}</div><div id="form-error"></div></div><div class="modal-footer">${button('Hủy','modal-close')}<button class="button primary" type="submit">Lưu cho các VPS đã chọn</button></div></form>`);
}
document.addEventListener('submit',async event=>{
 if(event.target.id!=='ssh-bulk-form')return;event.preventDefault();const form=event.target,submit=form.querySelector('button[type="submit"]');submit.disabled=true;
 try{
 const fields=Object.fromEntries(new FormData(form));const chosen=new FormData(form).getAll('targets');if(!chosen.length)throw new Error('Chọn ít nhất một VPS.');if(chosen.length>50)throw new Error('Chọn tối đa 50 VPS mỗi lần lưu.');
 const records=chosen.map(index=>{const t=sshBulkTargets[Number(index)],old=t.existing;
 if(fields.ssh_auth==='password'&&!fields.ssh_password&&!old?.has_ssh_password)throw new Error('VPS '+t.endpoint+' chưa có mật khẩu SSH.');
 return {record_id:old?.id||'',machine:{name:old?.name||t.profile.name+' · '+t.host,mode:'ssh',host:old?.host||t.host,port:Number(fields.port),user:fields.user,ssh_auth:fields.ssh_auth,ssh_password:fields.ssh_auth==='password'?(fields.ssh_password||null):'',identity:fields.ssh_auth==='key'?fields.identity:'',profile_id:t.profile.id,mongo_endpoint:t.endpoint,service:old?.service||'mongod'}};
 });
 if(demo){toast('Chế độ minh họa không lưu thông tin SSH.');return;}
 await api('/machines/batch',{method:'POST',body:JSON.stringify(records)});form.elements.ssh_password.value='';$('#modal').close();await refreshState();await render();toast('Đã lưu SSH cho '+records.length+' VPS.');
 }catch(error){formError(error);}finally{submit.disabled=false;}
});
function settingsPage(){const p=profile();return heading('Cấu hình workspace','Thông tin kết nối và các thiết lập của cụm đang chọn.',button('Chỉnh kết nối','profile-edit','settings','primary'))+sshSettingsPanel()+panel('Hồ sơ MongoDB',p?`<div class="panel-body">${[['Tên cụm',p.name],['Seed list',p.seeds.join(', ')],['Replica set',p.replica_set||'Standalone'],['Username',p.username||'Không dùng'],['Auth database',p.auth_db],['TLS',p.tls?'Bật':'Tắt']].map(([k,v])=>`<div class="key-value"><span>${k}</span><strong>${esc(v)}</strong></div>`).join('')}<div class="section-title"></div><div class="actions">${button('Chỉnh kết nối','profile-edit','settings','primary')}${button('Chuỗi kết nối','connection','external')}${button('Xóa hồ sơ','profile-delete','trash','danger')}</div></div>`:empty('Chưa chọn cụm','Tạo hồ sơ kết nối trước khi cấu hình.'))+`<div class="callout neutral">Hồ sơ và mật khẩu được mã hóa trên máy quản trị. Khóa mã hóa nằm cùng thư mục dữ liệu, chỉ tài khoản hệ điều hành hiện tại có quyền đọc. SSH hỗ trợ mật khẩu hoặc key/agent của tài khoản chạy ứng dụng.</div>`;}
function diagnosticsPage(){return heading('Chẩn đoán','Kiểm tra kết nối MongoDB và môi trường máy chủ.',button('Kiểm tra kết nối','diagnose','pulse','primary'))+`<div class="cards">${feature('Kết nối các node','Kết nối trực tiếp từng seed, xác thực và đọc vai trò từ máy quản trị.','cluster','diagnose','Chạy chẩn đoán')}${feature('Môi trường VPS','Kiểm tra Ubuntu, CPU, kernel, đĩa, package và service qua SSH.','server','preflight','Kiểm tra máy')}${feature('Nhật ký MongoDB','Xem journal của service để xác định lỗi startup, quyền hoặc port.','terminal','logs','Đọc nhật ký')}</div><div class="section-title"><h2>Kết quả kiểm tra</h2></div><div id="query-result">${empty('Sẵn sàng kiểm tra','Chọn một phép kiểm tra phía trên. Các bước chẩn đoán chỉ đọc thông tin.','','','pulse')}</div>`;}
function upgradePage(){return heading('Phiên bản & nâng cấp','Kiểm tra tương thích trước khi thay đổi phiên bản MongoDB.',button('Kiểm tra điều kiện','upgrade-check','pulse','primary'))+`<div class="metrics">${metric('Phiên bản hiện tại',esc(currentStatus?.version||'—'),'Đọc từ cụm đang chọn','db')}${metric('FCV',esc(currentStatus?.fcv||'—'),'Feature Compatibility Version','shield')}${metric('Nhánh hỗ trợ','8.0 / 9.0','Package Community chính thức','arrow')}${metric('Ubuntu 26.04','≥ 9.0.4','Kiểm tra package trước khi cài','server')}</div><div class="layout-two">${panel('Quy trình nâng 8.0 → 9.0',`<div class="panel-body"><ol class="step-list"><li><strong>Kiểm tra và backup</strong>Xác minh driver, FCV và sức khỏe tất cả member. Restore thử trước khi thay phiên bản.</li><li><strong>Nâng secondary tuần tự</strong>Đợi từng member quay lại SECONDARY rồi mới chuyển sang node tiếp theo.</li><li><strong>Chuyển primary</strong>Step down, chờ primary mới rồi nâng node còn lại.</li><li><strong>Kiểm chứng ứng dụng</strong>Giữ FCV cũ trong thời gian kiểm tra. Nâng FCV bằng bước riêng sau đó.</li></ol></div>`)}${panel('Phạm vi tự động hóa',`<div class="panel-body"><div class="callout">Web hỗ trợ kiểm tra điều kiện nâng cấp. Thay binary và nâng FCV thực hiện theo runbook; chưa tự chạy từ giao diện.</div><p class="help-links"><a href="https://www.mongodb.com/docs/manual/release-notes/9.0-upgrade-from-8.0-replica-set/" target="_blank" rel="noopener noreferrer">Mở hướng dẫn MongoDB chính thức ↗</a></p>${button('Xem kết quả kiểm tra','upgrade-check','pulse')}</div>`)}</div>`;}
function jobsPage(){return heading('Lịch sử tác vụ','Theo dõi tiến độ, kết quả và những thao tác cần kiểm tra.',button('Làm mới','refresh','refresh'))+panel('Tác vụ',jobs().length?table(['TÁC VỤ','ĐÍCH','THỜI GIAN','TRẠNG THÁI',''],jobs().map(j=>`<tr><td><strong>${esc(j.label)}</strong></td><td>${esc(j.target)}</td><td>${formatDate(j.created_at)}</td><td>${jobBadge(j)}</td><td>${button('Chi tiết','job-open','','small',`data-id="${esc(j.id)}"`)}</td></tr>`)):empty('Chưa có tác vụ','Các thao tác thực hiện từ web sẽ xuất hiện tại đây.','','','clock'));}
async function render(){
  const id=++renderId; currentRoute=location.hash.slice(1).split('?')[0]||'overview';
  if(!nav.some(n=>n[0]===currentRoute))currentRoute='overview';
  updateChrome();document.body.classList.remove('nav-open');
  const needsStatus=['overview','replica','upgrade'].includes(currentRoute);
  if(demo){currentStatus=profile()?structuredClone(demoStatus):null;statusError='';}
  else if(needsStatus&&profile()){
    $('#content').innerHTML=heading(nav.find(n=>n[0]===currentRoute)[1],'Đang đọc dữ liệu từ MongoDB…')+'<div class="loading"><span class="spinner"></span>Đang kết nối cụm</div>';
    try{const data=await api(`/profiles/${profile().id}/status`);if(id!==renderId)return;currentStatus=data;statusError='';topologyChecked=Date.now();const saved=state.profiles.find(p=>p.id===profile()?.id);if(saved&&data.seeds)saved.seeds=data.seeds;}
    catch(e){if(id!==renderId)return;currentStatus=null;statusError=e.message;}
  }else if(!profile()){currentStatus=null;statusError='';}
  if(id!==renderId)return;
  const pages={overview,clusters:clustersPage, machines:machinePage, replica:replicaPage,backup:backupPage,settings:settingsPage,diagnostics:diagnosticsPage,upgrade:upgradePage,jobs:jobsPage};
  if(pages[currentRoute])$('#content').innerHTML=pages[currentRoute]();
  else {
    const users=currentRoute==='users';
    $('#content').innerHTML=heading(users?'User & phân quyền':'Dữ liệu',users?'Quản lý quyền truy cập vào các database.':'Khám phá database, collection và index.',button(users?'Tạo user':'Làm mới',users?'user-new':'refresh',users?'plus':'refresh','primary'))+`<div id="query-result"><div class="loading"><span class="spinner"></span>Đang tải…</div></div>`;
    if(!profile()){$('#query-result').innerHTML=empty('Chưa có kết nối','Thêm hồ sơ MongoDB để đọc dữ liệu.');return;}
    try{const data=demo?(users?[{user:'admin',db:'admin',roles:[{role:'root',db:'admin'}]},{user:'app_service',db:'app',roles:[{role:'readWrite',db:'app'}]},{user:'backup_agent',db:'admin',roles:[{role:'backup',db:'admin'}]}]:[{name:'admin',sizeOnDisk:2*1024**2},{name:'application',sizeOnDisk:2.4*1024**3},{name:'analytics',sizeOnDisk:640*1024**2},{name:'local',sizeOnDisk:256*1024**2}]):await api(`/profiles/${profile().id}/query/${users?'users':'databases'}`);
      if(id!==renderId)return;
      $('#query-result').innerHTML=users?panel('Tài khoản',table(['USERNAME','DATABASE','VAI TRÒ',''],data.map(u=>`<tr><td><strong>${esc(u.user)}</strong></td><td>${esc(u.db)}</td><td>${u.roles.map(r=>badge(r.role,'dark')).join(' ')}</td><td>${button('Mật khẩu','user-password','','small',`data-user="${esc(u.user)}" data-db="${esc(u.db)}"`)} ${button('Xóa','user-drop','','small',`data-user="${esc(u.user)}" data-db="${esc(u.db)}"`)}</td></tr>`))):panel('Databases',table(['DATABASE','DUNG LƯỢNG','LOẠI',''],data.map(d=>`<tr><td><div class="host-cell"><span class="server-icon">${icon('db')}</span><strong>${esc(d.name)}</strong></div></td><td>${bytes(d.sizeOnDisk)}</td><td>${badge(['admin','local','config'].includes(d.name)?'Hệ thống':'Ứng dụng')}</td><td>${button('Collections','collections','','small',`data-db="${esc(d.name)}"`)} ${!['admin','local','config'].includes(d.name)?button('Xóa','database-drop','','small',`data-db="${esc(d.name)}"`):''}</td></tr>`)));
    }catch(e){if(id===renderId)$('#query-result').innerHTML=errorBox(e.message);}
  }
}

function modal(title,body,footer='',subtitle=''){
  $('#modal-content').innerHTML=`<div class="modal-header"><div><div class="eyebrow">${demo?'CHẾ ĐỘ XEM THỬ':'MONGODB MANAGER'}</div><h2>${title}</h2>${subtitle?`<p>${subtitle}</p>`:''}</div><button class="icon-button" data-act="modal-close" aria-label="Đóng">×</button></div>${body}${footer?`<div class="modal-footer">${footer}</div>`:''}`;
  if(!$('#modal').open)$('#modal').showModal();
  const scrollBody=$('.modal-body',$('#modal'));if(scrollBody)scrollBody.scrollTop=0;
}
function field(name,label,value='',type='text',help='',wide=false,options=[]){
  let input;
  if(type==='select')input=`<select name="${name}">${options.map(o=>`<option value="${esc(o.value??o)}" ${(o.value??o)===value?'selected':''}>${esc(o.label??o)}</option>`).join('')}</select>`;
  else if(type==='checkbox')input=`<input type="checkbox" name="${name}" ${value?'checked':''}>`;
  else if(type==='textarea')input=`<textarea name="${name}" ${name==='seeds'?'required':''}>${esc(value)}</textarea>`;
  else input=`<input name="${name}" type="${type}" value="${esc(value)}" ${type==='password'?'autocomplete="new-password"':''} ${['name','username','host','instance','advertise','replica_set','port','backup_id'].includes(name)?'required':''} ${type==='number'?'step="any"':''}>`;
  return `<label class="field ${wide?'wide':''} ${type==='checkbox'?'checkbox':''}">${type==='checkbox'?input:''}<span>${label}</span>${type!=='checkbox'?input:''}${help?`<small>${help}</small>`:''}</label>`;
}
function showRecord(kind,record=null){
  recordContext={kind,id:record?.id,hasSSHPassword:!!record?.has_ssh_password,sshIndex:0};jobId=null;
  let fields='';
  if(kind==='profiles'){
    fields=field('name','Tên hiển thị',record?.name||'','text','Ví dụ: Production hoặc Staging',true)+field('seeds','Seed list',record?.seeds.join('\n')||'','textarea','Nhập IP hoặc hostname của member; bỏ trống port sẽ dùng 27017. Ví dụ: 203.0.113.10 hoặc 203.0.113.10:27018.',true)+field('replica_set','Tên replica set',record?.replica_set??'','text','Để trống để tự nhận diện từ primary hoặc secondary.')+field('auth_db','Auth database',record?.auth_db||'admin')+field('username','Username MongoDB',record?.username||'')+field('password','Mật khẩu MongoDB', '', 'password',record?'Để trống để giữ mật khẩu đã lưu.':'Được mã hóa trên máy quản trị.')+field('tls','Bật TLS',record?.tls||false,'checkbox','',true)+field('tls_ca','Đường dẫn CA (nếu dùng)',record?.tls_ca||'','text','Đường dẫn trên máy quản trị. Để trống để dùng CA hệ thống.',true);
  }else{
    fields=field('name','Tên máy chủ',record?.name||'','text','Ví dụ: mongo-01',true)+field('mode','Chế độ',record?.mode||'ssh','select','',false,[{value:'ssh',label:'SSH — VPS từ xa'},{value:'local',label:'Local — máy chạy web'}])+field('host','Địa chỉ SSH',record?.host||'','text','Mật khẩu dùng IP/hostname trực tiếp; key/agent có thể dùng alias SSH.')+field('port','Port SSH',record?.port||22,'number')+field('user','User SSH',record?.user||'root')+field('ssh_auth','Xác thực SSH',record?.ssh_auth||'key','select','',true,[{value:'key',label:'SSH key / Agent'},{value:'password',label:'Mật khẩu SSH'}])+field('ssh_password','Mật khẩu SSH','','password',record?.has_ssh_password?'Đã lưu mật khẩu. Để trống để giữ nguyên.':'Mật khẩu được lưu mã hóa trên máy quản trị.',true)+field('identity','SSH private key (tùy chọn)',record?.identity||'','text','Để trống để dùng SSH agent hoặc ~/.ssh/config.',true)+field('profile_id','Thuộc cụm (tùy chọn)',record?.profile_id||profile()?.id||'','select','Liên kết VPS với cụm đã tiếp nhận.',true,[{value:'',label:'Chưa liên kết cụm'},...profiles().map(p=>({value:p.id,label:p.name}))])+field('mongo_endpoint','Endpoint MongoDB trên VPS',record?.mongo_endpoint||'','text','Ví dụ: 203.0.113.10:27017. Port này khác port SSH.',true)+field('service','Tên service',record?.service||'mongod','text','Service systemd của instance cần quản lý.',true);
  }
  modal(record?'Chỉnh sửa hồ sơ':kind==='profiles'?'Kết nối cụm MongoDB':'Thêm máy chủ',`<form id="record-form"><div class="modal-body"><div class="form-grid">${fields}</div>${kind==='profiles'?'<div id="probe-result"></div><details class="cluster-ssh"><summary>SSH cho các VPS trong cụm (tùy chọn)</summary><p>Tài khoản SSH dùng để đọc log, điều khiển service, cài đặt và xử lý trên VPS. Mỗi VPS có thông tin SSH riêng; tài khoản này khác tài khoản MongoDB ở trên. Lưu hồ sơ không tự chạy lệnh trên VPS.</p><div id="cluster-ssh-list"></div>'+button('Thêm VPS bằng SSH','cluster-ssh-add','plus')+' '+button('Lưu SSH & mở máy chủ','cluster-ssh-save')+'<p>Có thể lưu SSH trước để kiểm tra VPS khi MongoDB chưa kết nối được. Sau đó tiếp nhận cụm khi đã xử lý xong.</p></details>':''}<div id="form-error"></div></div><div class="modal-footer">${kind==='profiles'?button('Kiểm tra kết nối','profile-probe'):''}${record?button('Xóa hồ sơ','record-delete','trash','danger'):''}${button('Hủy','modal-close')}<button class="button primary" type="submit">${icon('check')}${kind==='profiles'?'Kiểm tra & lưu cụm':'Lưu hồ sơ'}</button></div></form>`,'',kind==='profiles'?'Tiếp nhận cụm đang chạy: chỉ đọc và kiểm tra kết nối, không cài đặt hay khởi tạo lại.':'Chọn mật khẩu hoặc SSH key/agent. Máy đích cần có trong known_hosts.');
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
  preflight:{title:'Kiểm tra môi trường',host:true,fields:[]},
  logs:{title:'Xem nhật ký dịch vụ',host:true,fields:[]},
  install:{title:'Cài MongoDB Community',host:true,note:'Cài mới bằng package chính thức. Nếu đã có mongod, tác vụ sẽ dừng và giữ nguyên phiên bản hiện tại.',fields:[['series','Nhánh MongoDB','9.0','select','',false,['9.0','8.0']]]},
  setup:{title:'Tạo replica set một node',host:true,note:'Cần cài mongod và mongosh trước. Tạo service và đường dẫn riêng theo tên instance. Cụm mới dùng keyfile và mật khẩu, TLS tắt.',fields:[['instance','Tên instance','production','text','Chữ thường, số, dấu gạch ngang.'],['replica_set','Tên replica set','rs0'],['port','Port MongoDB',27017,'number'],['advertise','Địa chỉ quảng bá','', 'text','IP public hoặc hostname:port mà các node và ứng dụng truy cập được.'],['bind_ip','Bind address','0.0.0.0','text','0.0.0.0 hoặc danh sách IP có 127.0.0.1. Firewall quản lý riêng.',true],['username','User quản trị','admin'],['password','Mật khẩu quản trị','','password','Ít nhất 12 ký tự.']]},
  service:{title:'Điều khiển dịch vụ',host:true,note:'Chỉ tác động service trong hồ sơ máy. Stop/restart có thể gián đoạn truy cập dữ liệu; xem trạng thái replica set trước khi chạy.',fields:[['operation','Thao tác','restart','select','',true,[{value:'start',label:'Khởi động'},{value:'stop',label:'Dừng'},{value:'restart',label:'Khởi động lại'},{value:'enable',label:'Bật autostart'},{value:'disable',label:'Tắt autostart'}]]]},
  add_member:{title:'Thêm thành viên',profile:true,note:'Node đích phải chạy mongod với cùng replSetName và keyfile. Web thêm membership; không ghi đè cấu hình node đích. Secondary mới có votes=0, priority=0.',fields:[['host','Địa chỉ node','','text','IP hoặc hostname:port',true],['arbiter','Thêm dưới vai trò Arbiter',false,'checkbox','',true]]},
  remove_member:{title:'Gỡ node khỏi cụm',profile:true,note:'Giữ nguyên dữ liệu trên máy đích. Gỡ bằng reconfig thông thường và kiểm tra quorum trước khi áp dụng.',fields:[['host','Node cần gỡ','','text','',true]]},
  member_options:{title:'Sửa cấu hình member',profile:true,fields:[['host','Địa chỉ node','','text','',true],['priority','Priority',1,'number'],['votes','Votes',1,'number','Chỉ nhận 0 hoặc 1.'],['hidden','Hidden member',false,'checkbox','Hidden hoặc votes=0 cần priority=0.',true]]},
  step_down:{title:'Step down Primary',profile:true,note:'Cần secondary sẵn sàng. Thao tác chờ primary mới, không force bầu chọn.',fields:[]},
  create_user:{title:'Tạo user MongoDB',profile:true,fields:[['username','Username',''],['database','Database','app'],['password','Mật khẩu','','password','Ít nhất 12 ký tự.',true],['role','Quyền','readWrite','select','Root / backup / clusterMonitor phải dùng database admin.',true,['readWrite','read','dbAdmin','backup','clusterMonitor','root']]]},
  password:{title:'Đổi mật khẩu user',profile:true,fields:[['username','Username',''],['database','Database xác thực','admin'],['password','Mật khẩu mới','','password','Nếu đổi user đang kết nối, cập nhật mật khẩu trong hồ sơ sau khi chạy.',true]]},
  drop_user:{title:'Xóa user',profile:true,fields:[['username','Username',''],['database','Database xác thực','admin']]},
  write_concern:{title:'Cấu hình Write Concern',profile:true,note:'w=1 chỉ yêu cầu primary xác nhận. Với Primary-Secondary-Arbiter, majority cần cả hai node dữ liệu để xác nhận ghi.',fields:[['w','Mức xác nhận ghi','majority','select','',true,[{value:'majority',label:'majority'},{value:'1',label:'w = 1'}]]]},
  backup:{title:'Tạo bản backup',host:true,profile:true,note:'Máy thực thi cần mongodump và kết nối được cụm. Để trống database để backup toàn replica set với oplog.',fields:[['database','Database (tùy chọn)','','text','Để trống = tất cả database.'],['collection','Collection (tùy chọn)','','text','Chỉ sử dụng khi đã chọn database.']]},
  backups:{title:'Danh sách backup trên máy',host:true,fields:[]},
  restore:{title:'Restore bản backup',host:true,profile:true,note:'Máy thực thi phải chứa backup. Cụm đang chọn là đích nhận dữ liệu. Kiểm tra binary/FCV tương thích trước khi chạy.',fields:[['backup_id','ID bản backup','','text','Lấy từ danh sách backup trên máy.',true],['drop','Xóa collection đích trước khi restore',false,'checkbox','Mặc định tắt. Bật có thể mất dữ liệu hiện tại.',true]]},
  drop_database:{title:'Xóa database',profile:true,note:'Xóa dữ liệu vĩnh viễn trên cụm được chọn. Không áp dụng cho admin, local hoặc config.',fields:[['database','Tên database','','text','',true]]},
  upgrade_check:{title:'Kiểm tra nâng cấp lên 9.0',profile:true,note:'Chỉ đọc phiên bản, FCV và trạng thái cụm. Không thay binary hoặc nâng FCV.',fields:[]},
};
schemas.provision={...schemas.setup,title:'Cài và tạo cụm mới',note:'Dành cho VPS chưa có cụm ở port này. Kiểm tra đích, cài package nếu thiếu, tạo keyfile và replica set, lưu hồ sơ và xác minh kết nối.',fields:[['series','Nhánh MongoDB','9.0','select','',true,['9.0','8.0']],...schemas.setup.fields]};
schemas.join_fresh={title:'Kiểm tra VPS và thêm member',host:true,profile:true,note:'Mọi chế độ đều kiểm tra SSH, phiên bản và keyfile. Chế độ cài mới cần port/thư mục trống hoặc instance manager khớp cấu hình để tái sử dụng. Chọn member nguồn bất kỳ, có quyền SSH đọc keyfile; nguồn không cần là primary; tài khoản MongoDB cần quyền getCmdLineOpts và quản lý cụm. Không tạo replica set/user riêng trên Secondary. Cụm TLS cần chuẩn bị node riêng.',fields:[['mode','Cách xử lý VPS','prepare','select','Cài khi thiếu; instance manager khớp cấu hình được tái sử dụng. Không tự cài đè dữ liệu.',true,[{value:'prepare',label:'Kiểm tra và cài/cấu hình instance manager'},{value:'prepared',label:'Kiểm tra node đã cấu hình sẵn (giữ nguyên)'}]],['arbiter','Thêm dưới vai trò Arbiter',false,'checkbox','Bỏ chọn để thêm Secondary.',true],['target_keyfile','Keyfile trên node đã chuẩn bị','','text','Chỉ bắt buộc với chế độ node đã chuẩn bị; nhập đường dẫn thực tế để đối chiếu nguồn.',true],['source_machine_id','VPS nguồn giữ keyfile (bất kỳ member)','','select','Dùng để đọc keyfile đang chạy; không thay đổi VPS nguồn.',true,[]],['source_endpoint','Endpoint MongoDB của VPS nguồn','','text','Phải là member của cụm đã chọn.',true],['instance','Tên instance mới','secondary'],['port','Port MongoDB',27017,'number'],['advertise','Endpoint quảng bá của VPS mới','','text','IP/hostname:port truy cập được từ mọi member.',true],['bind_ip','Bind address','0.0.0.0','text','Kiểm tra firewall giữa các VPS trước khi chạy.',true]]};
function openAction(action,overrides={}){
  jobId=null;const schema=schemas[action];
  if(schema.profile&&!profile()){toast('Thêm hồ sơ MongoDB trước khi thực hiện.');showRecord('profiles');return;}
  if(schema.host&&!machines().length){toast('Thêm máy thực thi trước khi thực hiện.');showRecord('machines');return;}
  if(action==='join_fresh'&&machines().length<2){pendingJoinOptions=overrides;toast('Cần SSH của VPS nguồn và VPS đích. Nhập VPS mới trước.');pendingJoin=true;showRecord('machines');return;}
  actionContext={action,overrides};
  let fields='';
  if(schema.host)fields+=field('machine_id',action==='join_fresh'?'VPS đích mới':'Máy thực thi',overrides.machine_id||(action==='join_fresh'?(machines().find(m=>!m.profile_id)||machines().at(-1)).id:machines()[0].id),'select','',true,machines().map(m=>({value:m.id,label:`${m.name} · ${m.mode==='local'?'Local':`${m.user}@${m.host}`} · ${m.service}`})));
  if(schema.profile)fields+=field('profile_id',action==='restore'?'Cụm đích nhận dữ liệu':'Cụm MongoDB',profile().id,'select','',true,profiles().map(p=>({value:p.id,label:`${p.name} · ${p.replica_set}`})));
  for(const entry of schema.fields){const f=[...entry];if(f[0]==='source_machine_id')f[6]=machines().map(m=>({value:m.id,label:m.name+' · '+m.host}));if(f[0] in overrides)f[2]=overrides[f[0]];fields+=field(...f);}
  modal(schema.title,`<form id="action-form"><div class="modal-body">${schema.note?`<div class="callout">${schema.note}</div>`:''}<div class="form-grid">${fields}</div><div id="form-error"></div></div><div class="modal-footer">${button('Hủy','modal-close')}<button class="button primary" type="submit">Xem lại thao tác →</button></div></form>`);
  const form=$('#action-form');let lastAdvertise='',lastSource='';
  const fill=()=>{
    if(form.elements.target_keyfile){const prepared=form.elements.mode?.value==='prepared';form.elements.target_keyfile.closest('.field').hidden=!prepared;form.elements.target_keyfile.disabled=!prepared;form.elements.target_keyfile.required=prepared;}
    const m=machines().find(m=>m.id===form.elements.machine_id?.value);
    if(form.elements.advertise&&m){const next=(m.host.includes(':')?'['+m.host+']':m.host)+':'+form.elements.port.value;if(!form.elements.advertise.value||form.elements.advertise.value===lastAdvertise)form.elements.advertise.value=next;lastAdvertise=next;}
    const src=machines().find(m=>m.id===form.elements.source_machine_id?.value);
    if(form.elements.source_endpoint&&src){const next=src.mongo_endpoint||'';if(!form.elements.source_endpoint.value||form.elements.source_endpoint.value===lastSource)form.elements.source_endpoint.value=next;lastSource=next;}
  };fill();form.addEventListener('change',fill);
}
function formError(error){const target=$('#form-error');if(target)target.innerHTML=`<div class="form-error">${esc(error.message||error)}</div>`;else toast(error.message||error,true);}
function showPreview(plan){
  previewPlan=plan;
  const schema=schemas[actionContext.action];
  const labels=Object.fromEntries(schema.fields.map(f=>[f[0],f[1]]));
  modal('Xác nhận thao tác',`<div class="modal-body"><div class="review-params"><div class="review-row"><span>Tác vụ</span><span>${esc(plan.label)}</span></div><div class="review-row"><span>Máy / cụm đích</span><span>${esc(plan.target)}</span></div>${Object.entries(plan.params).map(([k,v])=>`<div class="review-row"><span>${esc(labels[k]||k)}</span><span>${esc(typeof v==='boolean'?(v?'Bật':'Tắt'):v||'—')}</span></div>`).join('')}</div>${plan.notices.map(n=>`<div class="callout">${esc(n)}</div>`).join('')}${demo?'<div class="callout neutral">Đây là mô phỏng. Không có lệnh nào được gửi đến máy chủ.</div>':''}${plan.confirmation?`<div class="confirmation"><p>Nhập <code>${esc(plan.confirmation)}</code> để xác nhận đúng đích.</p><label class="field"><input id="confirmation-input" autocomplete="off" placeholder="Nhập tên đích ở trên" aria-label="Tên xác nhận"></label></div>`:''}<div id="form-error"></div></div>`,button('Quay lại','action-back')+button(demo?'Chạy mô phỏng':'Thực hiện','action-apply','check','primary'));
}
function showJob(job){
  jobId=job.id;
  const running=['queued','running'].includes(job.status);
  modal(esc(job.label),`${running?'<div class="progress-track"><i></i></div>':''}<div class="modal-body job-detail"><div class="actions">${jobBadge(job)}<span class="mono">${esc(job.target)}</span></div>${job.error?errorBox(job.error):''}<pre class="terminal">${job.events.map(e=>`<small>${esc(formatDate(e.time))}</small>  ${esc(e.message)}`).join('\n')||'Đang chờ tác vụ…'}</pre>${job.result?`<div><div class="notice-label">Kết quả</div><pre>${esc(typeof job.result==='string'?job.result:JSON.stringify(job.result,null,2))}</pre></div>`:''}</div>`,button('Đóng','modal-close'));
}
async function openJob(id){
  const job=demo?demoJobs.find(j=>j.id===id):await api('/jobs/'+id);
  if(!job){toast('Không tìm thấy tác vụ.',true);return;}
  showJob(job);
  if(job.action==='backups'&&job.status==='succeeded')backupItems=job.result;
}
async function runDiagnostics(){
  if(!profile()){showRecord('profiles');return;}
  const data=demo?[{host:'203.0.113.10:27017',ok:true,role:'PRIMARY'},{host:'203.0.113.11:27017',ok:true,role:'SECONDARY'},{host:'203.0.113.12:27017',ok:true,role:'SECONDARY'}]:await api(`/profiles/${profile().id}/query/diagnostics`);
  modal('Kết quả chẩn đoán',`<div class="modal-body"><div class="callout neutral">Kiểm tra từ máy đang chạy web. Kết quả không thay thế kiểm tra mạng hai chiều giữa các member.</div>${table(['ENDPOINT','KẾT QUẢ','VAI TRÒ / GHI CHÚ'],data.map(r=>`<tr><td class="mono">${esc(r.host)}</td><td>${badge(r.ok?'Kết nối được':'Thất bại',r.ok?'success':'error')}</td><td>${esc(r.ok?r.role:r.error)}${r.note?'<br><small>'+esc(r.note)+'</small>':''}</td></tr>`))}</div>`,button('Đóng','modal-close'));
}
async function saveRecord(form){
  let data=Object.fromEntries(new FormData(form));const ctx=recordContext;
  if(ctx.kind==='profiles'){data=profileFormData(form);data.machines=clusterSSHData();}
  else {data.port=Number(data.port||22);if(!data.ssh_password)data.ssh_password=null;}
  if(demo){toast('Hồ sơ xem thử không được lưu. Chuyển sang dữ liệu thật để kết nối.');$('#modal').close();return;}
  const adopted=ctx.kind==='profiles'?await api('/profiles/adopt',{method:'POST',body:JSON.stringify({...data,record_id:ctx.id||''})}):null;
  const saved=adopted?adopted.profile:await api('/'+ctx.kind+(ctx.id?'/'+ctx.id:''),{method:ctx.id?'PUT':'POST',body:JSON.stringify(data)});
  if(ctx.kind==='profiles'){selected=saved.id;localStorage.setItem('mongo-manager-profile',selected);currentStatus=null;}
  $('#modal').close();toast('Đã lưu hồ sơ.');await refreshState();await render();if(ctx.kind==='machines'&&pendingJoin){pendingJoin=false;openAction('join_fresh',{...pendingJoinOptions,machine_id:saved.id});pendingJoinOptions={};}
}
document.addEventListener('submit',async event=>{
  if(!['record-form','action-form'].includes(event.target.id))return;
  event.preventDefault();const submit=$('button[type="submit"]',event.target);submit.disabled=true;
  try{
    if(event.target.id==='record-form')await saveRecord(event.target);
    else{
      const schema=schemas[actionContext.action];const data=Object.fromEntries(new FormData(event.target));const params={};
      for(const f of schema.fields){params[f[0]]=f[3]==='checkbox'?event.target.elements[f[0]].checked:f[3]==='number'?Number(data[f[0]]):data[f[0]];}
      actionContext.overrides={...params,machine_id:data.machine_id};
      if(params.collection&&!params.database)throw new Error('Chọn database trước khi chỉ định collection.');
      const payload={action:actionContext.action,profile_id:data.profile_id||'',machine_id:data.machine_id||'',params};
      let plan;
      if(demo){const target=schema.host?machines().find(m=>m.id===data.machine_id).name:profile().name;plan={id:'demo',label:schema.title,target,params:{...params,...('password'in params?{password:'••••••••'}:{})},notices:[],confirmation:['preflight','logs','backups','upgrade_check'].includes(actionContext.action)?'':target};}
      else plan=await api('/plans',{method:'POST',body:JSON.stringify(payload)});
      showPreview(plan);
    }
  }catch(error){formError(error);}finally{submit.disabled=false;}
});
document.addEventListener('click',async event=>{
  const target=event.target.closest('[data-act]');if(!target)return;
  const act=target.dataset.act;
  try{
    if(act==='ssh-bulk'){openBulkSSH();return;}
    if(act==='logout'){await api('/auth/logout',{method:'POST',body:'{}'});showLogin();return;}
    if(act==='sidebar'){document.body.classList.toggle('nav-open');return;}
    if(act==='demo'){demo=!demo;localStorage.setItem('mongo-manager-demo',demo);currentStatus=null;statusError='';backupItems=[];await refreshState();await render();return;}
    if(act==='refresh'){await refreshState();await render();return;}
    if(act==='modal-close'){$('#modal').close();jobId=null;return;}
    if(act==='cluster-ssh-save'){const attached=clusterSSHData();if(!attached.length)throw new Error('Thêm ít nhất một VPS SSH trước khi lưu.');if(demo){toast('Chế độ minh họa không lưu hồ sơ.');return;}if(recordContext.id)attached.forEach(a=>a.machine.profile_id=recordContext.id);await api('/machines/batch',{method:'POST',body:JSON.stringify(attached)});$('#modal').close();await refreshState();location.hash='machines';await render();toast('Đã lưu SSH. Bấm Kiểm tra ở VPS để đọc môi trường trước khi xử lý.');return;}
    if(act==='cluster-ssh-add'){addClusterSSH();return;}
    if(act==='cluster-ssh-remove'){target.closest('.cluster-ssh-row').remove();return;}
    if(act==='profile-probe'){await probeProfileForm();return;}
    if(act==='profile-new'){showRecord('profiles');return;}
    if(act==='profile-open'){selected=target.dataset.id;if(!demo)localStorage.setItem('mongo-manager-profile',selected);currentStatus=null;location.hash='overview';await render();return;}
    if(act==='profile-edit'){const p=profiles().find(p=>p.id===target.dataset.id)||profile();if(p)showRecord('profiles',p);return;}
    if(act==='machine-new'){showRecord('machines');return;}
    if(act==='node-add'){showNodeAdd();return;}
    if(act==='prepared-node'){openAction('join_fresh',{mode:'prepared'});return;}
    if(act==='node-ssh-new'){pendingJoin=true;showRecord('machines');return;}
    if(act==='machine-edit'){showRecord('machines',machines().find(m=>m.id===target.dataset.id));return;}
    if(act==='record-delete'||act==='profile-delete'){
      const ctx=act==='profile-delete'?{kind:'profiles',id:target.dataset.id||profile()?.id}:recordContext;
      if(!ctx.id)return;
      const label=ctx.kind==='profiles'?profiles().find(p=>p.id===ctx.id)?.name:machines().find(m=>m.id===ctx.id)?.name;
      if(!confirm('Xóa hồ sơ '+(label||'')+' khỏi ứng dụng? Dữ liệu và dịch vụ trên VPS vẫn giữ nguyên.'))return;
      if(demo){toast('Không xóa hồ sơ minh họa.');return;}
      await api('/'+ctx.kind+'/'+ctx.id,{method:'DELETE'});$('#modal').close();currentStatus=null;await refreshState();await render();return;
    }
    if(act==='connection'){
      const p=profile();if(!p)return;
      const connection=`mongodb://${p.username?encodeURIComponent(p.username)+':<PASSWORD>@':''}${p.seeds.join(',')}/?authSource=${encodeURIComponent(p.auth_db)}${p.replica_set?'&replicaSet='+encodeURIComponent(p.replica_set):''}${p.tls?'&tls=true':''}`;
      modal('Chuỗi kết nối ứng dụng',`<div class="modal-body"><p>Thay <code>&lt;PASSWORD&gt;</code> bằng mật khẩu đã URL-encode. Chuỗi này không hiển thị mật khẩu đã lưu.</p><pre>${esc(connection)}</pre></div>`,button('Đóng','modal-close'));return;
    }
    if(act==='help'){
      modal('Bắt đầu sử dụng',`<div class="modal-body"><ol class="step-list"><li><strong>Kết nối MongoDB đang chạy</strong>Thêm hồ sơ với seed, replica set và tài khoản có đủ quyền. Không cần SSH để xem cụm hoặc quản lý user.</li><li><strong>Quản lý VPS</strong>Thêm máy SSH bằng mật khẩu hoặc key/agent. Kiểm tra known_hosts và sudo -n trước; chạy Kiểm tra môi trường.</li><li><strong>Cài một VPS mới</strong>Cài package trước, sau đó tạo replica set một node. Setup thành công sẽ tạo hồ sơ kết nối tự động.</li><li><strong>Theo dõi tác vụ</strong>Xem trước đích, xác nhận rồi chạy. Mở Lịch sử tác vụ để xem tiến độ và kết quả.</li></ol><div class="section-title"></div><div class="callout neutral">Web lắng nghe trên localhost. Nếu chạy trên VPS, dùng SSH tunnel:<br><code>ssh -L 8765:127.0.0.1:8765 user@vps</code></div></div>`,button('Đã hiểu','modal-close'));return;
    }
    if(act==='job-open'){await openJob(target.dataset.id);return;}
    if(act==='diagnose'){target.disabled=true;await runDiagnostics();return;}
    if(act==='collections'){
      const name=target.dataset.db;const result=demo?[{name:'users',type:'collection',indexes:[{name:'_id_',key:{_id:1}}]},{name:'events',type:'collection',indexes:[{name:'_id_',key:{_id:1}},{name:'createdAt_1',key:{createdAt:1}}]}]:await api(`/profiles/${profile().id}/query/collections?database=${encodeURIComponent(name)}`);
      modal('Collections · '+esc(name),`<div class="modal-body"><pre>${esc(JSON.stringify(result,null,2))}</pre></div>`,button('Đóng','modal-close'));return;
    }
    if(act==='action-back'){openAction(actionContext.action,actionContext.overrides);return;}
    if(act==='action-apply'){
      const confirmation=$('#confirmation-input')?.value||'';
      if(confirmation!==previewPlan.confirmation)throw new Error('Tên xác nhận chưa khớp.');
      target.disabled=true;
      if(demo){
        const result=actionContext.action==='backups'?[{id:'a'.repeat(32),time:new Date().toISOString(),source:'Production',database:'Tất cả',size:2.4*1024**3,verified_restore:false}]:{demo:true,message:'Mô phỏng hoàn tất. Không thay đổi máy chủ.'};
        const job={id:'demo-'+Date.now(),action:actionContext.action,label:previewPlan.label,target:previewPlan.target,status:'succeeded',created_at:new Date().toISOString(),events:[{time:new Date().toISOString(),message:'Đây là tác vụ minh họa, không thực thi lệnh.'}],result};
        demoJobs.unshift(job);if(job.action==='backups')backupItems=result;showJob(job);updateChrome();return;
      }
      const job=await api('/jobs',{method:'POST',body:JSON.stringify({plan_id:previewPlan.id,confirmation})});showJob(job);await refreshState();return;
    }
    const mapping={'provision':'provision','join-fresh':'join_fresh','setup':'setup','install':'install','preflight':'preflight','logs':'logs','service':'service','add-member':'add_member','add-arbiter':'join_fresh','member-remove':'remove_member','member-edit':'member_options','step-down':'step_down','write-concern':'write_concern','user-new':'create_user','user-password':'password','user-drop':'drop_user','database-drop':'drop_database','backup-new':'backup','backups-list':'backups','restore':'restore','upgrade-check':'upgrade_check'};
    if(mapping[act]){
      const extra={};if(target.dataset.id)extra.machine_id=target.dataset.id;if(target.dataset.host)extra.host=target.dataset.host;
      if(target.dataset.db)extra.database=target.dataset.db;if(target.dataset.user)extra.username=target.dataset.user;
      if(target.dataset.backup)extra.backup_id=target.dataset.backup;
      if(act==='add-arbiter')extra.arbiter=true;
      if(act==='member-edit'){const member=currentStatus?.members.find(m=>m.host===extra.host);if(member)Object.assign(extra,{priority:member.priority,votes:member.votes,hidden:!!member.hidden});}
      openAction(mapping[act],extra);
    }
  }catch(error){formError(error);}finally{target.disabled=false;}
});
$('#profile-select').addEventListener('change',async event=>{selected=event.target.value;if(!demo)localStorage.setItem('mongo-manager-profile',selected);currentStatus=null;statusError='';await render();});
$('#modal').addEventListener('close',()=>{jobId=null;if(currentRoute==='backup')$('#content').innerHTML=backupPage();});
window.addEventListener('hashchange',()=>{if(!document.body.classList.contains('auth-pending'))render();});
async function poll(){
  if(demo||document.body.classList.contains('auth-pending'))return;
  try{
    if(jobId){const job=await api('/jobs/'+jobId);if($('#modal').open&&jobId===job.id){showJob(job);if(job.status==='succeeded'&&job.action==='backups')backupItems=job.result;if(!['queued','running'].includes(job.status)){jobId=null;await refreshState();}}}
    else if(state.jobs.some(j=>['queued','running'].includes(j.status))){await refreshState();if(currentRoute==='jobs'&&!$('#modal').open)$('#content').innerHTML=jobsPage();}
  }catch(error){toast(error.message,true);jobId=null;}
  await refreshTopology();
}
async function refreshTopology(){
  if(topologyBusy||demo||document.hidden||$('#modal').open||!['overview','replica','upgrade'].includes(currentRoute)||!profile()||Date.now()-topologyChecked<10000||document.body.classList.contains('auth-pending'))return;
  topologyBusy=true;topologyChecked=Date.now();const requestId=renderId,pid=profile().id,route=currentRoute;
  try{const data=await api(`/profiles/${pid}/status`);if(requestId!==renderId||demo||profile()?.id!==pid||document.body.classList.contains('auth-pending'))return;currentStatus=data;statusError='';const saved=state.profiles.find(p=>p.id===pid);if(saved&&data.seeds)saved.seeds=data.seeds;}
  catch(error){if(requestId!==renderId||demo||profile()?.id!==pid||document.body.classList.contains('auth-pending'))return;currentStatus=null;statusError=error.message;}
  finally{topologyBusy=false;}
  if(requestId===renderId&&!$('#modal').open&&!document.body.classList.contains('auth-pending'))$('#content').innerHTML=({overview,replica:replicaPage,upgrade:upgradePage})[route]();
}
function showLogin(message=''){
  clearInterval(pollTimer);csrfToken='';jobId=null;state={profiles:[],machines:[],jobs:[]};currentStatus=null;
  if($('#modal').open)$('#modal').close();$('#content').replaceChildren();document.body.classList.add('auth-pending');
  $('#logout-button').hidden=true;const root=$('#login-root');root.hidden=false;
  root.innerHTML=`<form id="login-form" class="login-card"><div class="brand"><span class="brandmark">m</span><span>MongoDB Manager</span></div><div class="eyebrow">QUẢN TRỊ HỆ THỐNG</div><h1>Đăng nhập</h1><p>Quản lý các cụm MongoDB và VPS của bạn.</p><label class="field"><span>Username</span><input name="username" autocomplete="username" required maxlength="80"></label><label class="field"><span>Mật khẩu</span><input name="password" type="password" autocomplete="current-password" required maxlength="1000"></label><div id="login-error" role="alert">${message?errorBox(message):''}</div><button type="submit" class="button primary">Đăng nhập</button><small>Phiên tự hết hạn sau 30 phút không hoạt động.</small></form>`;
}
async function enterWorkspace(auth){
  csrfToken=auth.csrf||'';$('#login-root').hidden=true;document.body.classList.remove('auth-pending');
  $('#logout-button').hidden=!auth.enabled;$('#logout-button').textContent=auth.username?auth.username+' · Đăng xuất':'Đăng xuất';
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
