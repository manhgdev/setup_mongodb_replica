function vpsToastStack(){
  let stack=$('#vps-toast-stack');
  if(!stack){stack=document.createElement('div');stack.id='vps-toast-stack';document.body.append(stack);}
  return stack;
}
const $=s=>document.querySelector(s);
const escapeHTML=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let csrf='',currentAuth=null,revision=0,selectedJob=sessionStorage.getItem('vps-selected-job')||'',onConfirm;
const previewMode=localStorage.getItem('mongo-manager-demo')==='true';
const vpsGetCache=new Map();
async function api(path,data,method){
  if(previewMode && path!=='vps/catalog' && path.startsWith('vps/'))return previewVps(path,data);
  const verb=method||(data?'POST':'GET');
  const base=path.split('?')[0],refresh=path.includes('refresh=true');
  const cacheable=verb==='GET'&&path.startsWith('vps/')&&!refresh&&!path.startsWith('vps/jobs/')&&!path.endsWith('/metrics')&&path!=='vps/machines'&&path!=='vps/servers';
  if(cacheable&&vpsGetCache.has(path))return vpsGetCache.get(path);
  const wsHeaders=window.zmWorkspaceHelper?window.zmWorkspaceHelper.headers():{};
  const res=await fetch('/api/'+path,{method:verb,headers:{'Content-Type':'application/json','X-MongoDB-Manager':'1','X-CSRF-Token':csrf,...wsHeaders},body:data?JSON.stringify(data):undefined});
  if(res.status===401){managerLogin();throw new Error("HTTP 401");}
  const result=await res.json();
  if(!res.ok)throw Object.assign(new Error(typeof result.detail==='string'?result.detail:'Yêu cầu thất bại ('+res.status+')'),{job:res.headers.get('X-Active-Job')});
  if(refresh)vpsGetCache.set(base,result);
  else if(cacheable)vpsGetCache.set(path,result);
  else if(verb!=='GET')vpsGetCache.clear();
  return result;
}
function modal(title,html,submit){
  $('#popup h2').textContent=title;$('#fields').innerHTML=html;onConfirm=submit;$('dialog').showModal();
}
$('#cancel').onclick=$('#modal-x').onclick=()=>$('dialog').close();
$('#popup').onsubmit=async e=>{
  e.preventDefault();const button=e.submitter,origHtml=button.innerHTML;
  $('#fields [role=alert]')?.remove();
  button.disabled=true;button.innerHTML='<span class="spinner"></span> '+escapeHTML(button.textContent.trim());
  try{const res=await onConfirm(new FormData(e.target));if(res!==false)$('dialog').close();}
  catch(err){let p=$('#fields [role=alert]');if(!p){p=document.createElement('p');p.setAttribute('role','alert');$('#fields').append(p);}p.textContent=err.message;}
  finally{button.disabled=false;button.innerHTML=origHtml;}
};
const titles={servers:'Máy chủ',git:'Git & SSH Key',overview:'Tổng quan VPS',software:'Software Center',docker:'Docker & Compose',firewall:'Firewall',terminal:'SSH Terminal',sftp:'SFTP',sysadmin:'User & Ổ đĩa',domains:'Nginx & tên miền',jobs:'Lịch sử tác vụ',settings:'Cài đặt',users:'Người dùng'};
function certificateWarning(days){
  const threshold=[0,7,14,30].find(limit=>days<=limit);
  if(threshold===undefined||days===null)return '';
  const label=days<0?(vpsEnglish?'Expired':'Đã hết hạn'):(vpsEnglish?'Expires within ':'Sắp hết hạn · ≤ ')+threshold+(vpsEnglish?' days':' ngày');
  return label+' ('+days+(vpsEnglish?' days':' ngày')+')';
}
const endpoint=()=> 'vps/machines/'+encodeURIComponent($('#hosts').value);
async function trackJobBanner(jobId,{prefix='',onDone}={}){
  if(!jobId)return;
  const stack=vpsToastStack();
  if(stack.querySelector('.fw-job-banner[data-job="'+CSS.escape(jobId)+'"]'))return;
  const banner=document.createElement('div');banner.className='fw-job-banner';banner.dataset.job=jobId;
  banner.innerHTML='<span class="spinner"></span><span></span><button type="button" class="banner-close" aria-label="Đóng">×</button>';
  banner.querySelector('.banner-close').onclick=()=>banner.remove();
  stack.append(banner);
  const spin=banner.querySelector('.spinner'),msg=banner.querySelector('span:not(.spinner)');
  if(spin)spin.hidden=false;
  banner.dataset.state='running';
  msg.textContent=prefix+vt('Đang thực hiện…','Running…');
  for(let i=0;i<600;i++){
    const j=await api('vps/jobs/'+encodeURIComponent(jobId)).catch(()=>null);
    if(j){
      const last=j.events?.at(-1)?.message;
      const started=j.created_at?Date.parse(j.created_at):NaN;
      const elapsed=Number.isFinite(started)?Math.max(1,Math.round((Date.now()-started)/1000)):(i+1);
      msg.textContent=prefix+(last||vt('Đang thực hiện…','Running…'))+' ('+elapsed+'s)';
      if(j.status==='succeeded'){
        banner.dataset.state='ok';if(spin)spin.hidden=true;
        msg.textContent='✓ '+prefix+(j.label||vt('Hoàn tất','Done'));
        setTimeout(()=>banner.remove(),6000);
        vpsGetCache.clear();
        if(onDone)await onDone(j);else await render();
        return;
      }
      if(j.status==='failed'||j.status==='interrupted'){
        banner.remove();
        const logs=(j.events||[]).map(e=>e.message).filter(Boolean).slice(-8).join('\n');
        modal('✗ '+prefix+(j.label||vt('Thất bại','Failed')),'<div class="callout error" style="white-space:pre-wrap">'+escapeHTML(j.error||vt('Thao tác bị gián đoạn hoặc thất bại.','Action interrupted or failed.'))+'</div>'+(logs?'<details><summary>'+vt('Nhật ký gần nhất','Recent logs')+'</summary><pre>'+escapeHTML(logs)+'</pre></details>':''),async()=>{});
        return false;
      }
    }
    await new Promise(r=>setTimeout(r,1000));
  }
}
async function resumeActiveJobs(){
  if(previewMode)return;
  const hostId=$('#hosts')?.value;
  const seen=new Set();
  const candidates=[];
  if(hostId){
    const list=await api('vps/machines/'+encodeURIComponent(hostId)+'/jobs').catch(()=>[]);
    for(const j of list){if((j.status==='running'||j.status==='queued')&&!seen.has(j.id)){seen.add(j.id);candidates.push({id:j.id,prefix:j.target?j.target+' · ':''});}}
  }
  try{
    const batch=JSON.parse(sessionStorage.getItem('vps-batch')||'[]');
    for(const row of batch){if(row.job&&!seen.has(row.job)){seen.add(row.job);candidates.push({id:row.job,prefix:row.name?row.name+' · ':''});}}
  }catch{}
  for(const item of candidates){
    const j=await api('vps/jobs/'+encodeURIComponent(item.id)).catch(()=>null);
    if(j&&(j.status==='running'||j.status==='queued'))trackJobBanner(item.id,{prefix:item.prefix});
  }
}
async function submit(action,data){
  try{selectedJob=(await api(endpoint()+'/'+action,data)).id;}
  catch(err){if(!err.job)throw err;selectedJob=err.job;}
  sessionStorage.setItem('vps-selected-job',selectedJob);
  if($('dialog')?.open)$('dialog').close();
  return trackJobBanner(selectedJob,{
    onDone:async()=>{if(action==='hostname')await loadHosts($('#hosts').value);else await render();}
  });
}
function machineChoices(allChecked=false){
  const opts=Array.from($('#hosts').options);
  const allSelected=allChecked||(opts.length>0&&opts.every(o=>o.selected));
  const choices=opts.map(o=>'<label><input type="checkbox" name="machines" value="'+escapeHTML(o.value)+'" '+((allChecked||o.selected)?'checked':'')+'> '+escapeHTML(o.textContent)+'</label>');
  return '<fieldset class="batch-machines"><legend>'+vt('Máy chủ đích','Target servers')+' · <label style="font-weight:500;cursor:pointer"><input type="checkbox" class="batch-select-all"'+(allSelected?' checked':'')+'> '+vt('Chọn tất cả','Select all')+'</label></legend>'+choices.join('')+'</fieldset>';
}
document.addEventListener('change',e=>{
  const fs=e.target.closest?.('.batch-machines');if(!fs)return;
  const all=fs.querySelector('.batch-select-all'),items=[...fs.querySelectorAll('input[name="machines"]')];
  if(e.target===all)items.forEach(c=>{c.checked=all.checked;});
  else if(e.target.name==='machines'&&all){all.checked=items.length>0&&items.every(c=>c.checked);all.indeterminate=!all.checked&&items.some(c=>c.checked);}
});
async function submitTargets(form,action,data){
  const machines=form.getAll('machines');
  if(!machines.length)throw new Error('Chọn ít nhất một máy chủ.');
  delete data.machines;
  if(machines.length===1 && machines[0]===$('#hosts').value)return submit(action,data);
  const results=await api('vps/batches/'+action,{machines,operation:data});
  const names=new Map(Array.from($('#hosts').options,o=>[o.value,o.textContent]));
  sessionStorage.setItem('vps-batch',JSON.stringify(results.map(row=>({...row,name:names.get(row.machine)}))));
  if($('dialog')?.open)$('dialog').close();
  for(const row of results){
    if(!row.job){
      if(row.error){
        const errBanner=document.createElement('div');errBanner.className='fw-job-banner';errBanner.dataset.state='error';
        errBanner.innerHTML='<span>✗ '+escapeHTML((names.get(row.machine)||row.machine)+' · '+row.error)+'</span><button type="button" class="banner-close" aria-label="Đóng">×</button>';
        errBanner.querySelector('.banner-close').onclick=()=>errBanner.remove();
        vpsToastStack().append(errBanner);
      }
      continue;
    }
    const name=names.get(row.machine)||'';
    trackJobBanner(row.job,{prefix:name?name+' · ':''});
  }
}
async function batchHistory(view,rev){
  if(previewMode)return;
  const rows=JSON.parse(sessionStorage.getItem('vps-batch')||'[]');
  if(!rows.length)return;
  const panel=document.createElement('article');panel.className='panel';
  panel.innerHTML='<div class="panel-head"><h2>Tác vụ nhiều máy</h2><button class="button small" type="button">Đóng</button></div><div class="panel-body"></div>';
  panel.querySelector('button').onclick=()=>{sessionStorage.removeItem('vps-batch');render();};
  const states=await Promise.all(rows.map(async row=>{
    if(!row.job)return row;
    try{return {...row,...await api('vps/jobs/'+encodeURIComponent(row.job))};}catch(err){return {...row,error:err.message};}
  }));
  if(rev!==revision)return;
  for(const row of states){
    const entry=document.createElement('div');entry.className='batch-entry';
    entry.textContent=row.name+' · '+(row.status||'')+' '+(row.error||'');
    if(row.job){const btn=document.createElement('button');btn.className='button small';btn.dataset.tone='info';btn.textContent='Chi tiết';btn.onclick=()=>{$('#hosts').value=row.machine;selectedJob=row.job;render();};entry.append(btn);}
    panel.lastElementChild.append(entry);
  }
  view.prepend(panel);
}
const legacySnapshots=new Set();
async function render(){
  const rev=++revision,view=$('#view'),hashBase=location.hash.slice(1).split('?')[0],savedTab=localStorage.getItem('vps-active-tab');
  const section=Object.hasOwn(titles,hashBase)?hashBase:(Object.hasOwn(titles,savedTab)?savedTab:'overview');
  if(!hashBase&&section!=='overview')history.replaceState(null,'','#'+section);
  localStorage.setItem('vps-active-tab',section);
  view.closest('main').dataset.section=section;
  const descriptions={
    overview:['Xem tài nguyên, hệ điều hành và dịch vụ trên máy chủ đang chọn.','Inspect resources, the operating system and services on the selected server.'],
    software:['Kiểm tra bộ cài trên VPS và bổ sung phần còn thiếu.','Check your kits and install missing components.'],
    git:['Quản lý danh tính Git, SSH key và kết nối theo tài khoản trên VPS.','Manage Git identity, SSH keys and account connections on this server.'],
    docker:['Quản lý container và triển khai project Compose trên VPS.','Manage containers and deploy Compose projects on this server.'],
    servers:['Quản lý kết nối SSH, cài đặt và dịch vụ trên từng máy.','Manage SSH connections, installs and services on each server.'],
    firewall:['Quản lý UFW và Oracle Cloud Firewall, mở hoặc đóng port ở cả hai lớp.','Manage UFW and Oracle Cloud Firewall, opening or closing ports on both layers.'],
    terminal:['Kết nối SSH trực tiếp dạng terminal (giống Termius) nhiều tab cùng lúc.','Interactive multi-tab SSH terminal (Termius-style) right in your browser.'],
    sftp:['Quản lý và truyền file SFTP 2 khung song song (giống Termius) giữa máy tính và các VPS.','Termius-style dual-pane SFTP file manager for transfers between your computer and servers.'],
    sysadmin:['Tạo user Linux, phân quyền sudo/nhóm/SSH keys và chia ổ, mount, phân quyền thư mục.','Create Linux users, manage sudo/groups/SSH keys, partitions, mounts and folder permissions.'],
    domains:['Quản lý cấu hình website, định tuyến và chứng chỉ SSL trên VPS.','Manage website configurations, routes and SSL certificates on this server.'],
    jobs:['Theo dõi tiến độ và mở nhật ký để xem kết quả của từng tác vụ.','Track progress and open the logs to inspect each job’s result.'],
    settings:['Quản lý nơi lưu trữ dữ liệu (SQLite / MongoDB) và tài khoản quản trị ứng dụng.','Manage app data storage (SQLite / MongoDB) and administrator account settings.'],
    users:['Quản lý tài khoản đăng nhập, vai trò và workspace của người dùng.','Manage web login accounts, roles and user workspaces.']
  };
  $('#page-description').textContent=descriptions[section][vpsEnglish?1:0];
  $('#heading-actions').replaceChildren();
  $('#title').textContent=$('#crumb').textContent=vpsEnglish?(englishLabels[titles[section]]||titles[section]):titles[section];
  for(const link of document.querySelectorAll('nav a')){const active=link.hash==='#'+section;link.setAttribute('aria-current',active?'page':'false');link.classList.toggle('active',active);}
  if(section==='settings'){await settingsPageVps(view,rev);return;}
  if(section==='users'){await window.zmUsersPage({container:view,csrfToken:csrf,auth:currentAuth,en:vpsEnglish});return;}
  if(!$('#hosts').value){
    view.innerHTML='<section class="vps-box vps-empty"><h2>'+vt('Chưa có máy chủ','No servers yet')+'</h2><button class="button primary" id="first-machine">+ '+vt('Thêm VPS','Add server')+'</button></section>';
    $('#first-machine').onclick=()=>addVps();return;
  }
  const path=endpoint();
  try{
    if(section==='git'){await gitPage(view,path,rev);return;}
    if(section==='docker'){await dockerPage(view,path,rev);return;}
    if(section==='servers'){await serversPage(view,path,rev);return;}
    if(section==='firewall'){await firewallPage(view,path,rev);return;}
    if(section==='terminal'){await terminalPage(view,path,rev);return;}
    if(section==='sftp'){await sftpPage(view,path,rev);return;}
    if(section==='sysadmin'){await sysadminPage(view,path,rev);return;}
    if(section==='jobs'){
      const jobs=await api(path+'/jobs');if(rev!==revision)return;
      jobsPage(view,jobs,selectedJob);
      await batchHistory(view,rev);return;
    }
    if(section==='domains'){
      view.textContent='Đang đọc thông tin VPS…';
      const inventory=await api(path+'/nginx'), sites=inventory.sites;
      const hashParams=new URLSearchParams(location.hash.split('?')[1]||'');
      const openId=hashParams.get('site');
      if(openId){const target=sites.find(x=>x.file_id===openId);if(target){await showWebsite(target,path,rev,hashParams.get('tab'));return;}}
      if(rev!==revision)return;
      const labels={'renew-ssl':'Gia hạn SSL',detail:'Chi tiết',edit:'Sửa',disable:'Tắt site',enable:'Bật site',certificate:'Cấp SSL','renew-enable':'Bật tự gia hạn','renew-test':'Thử gia hạn',delete:'Xóa'};
      const tones={'renew-ssl':'create',detail:'info',edit:'configure',disable:'warning',enable:'create',certificate:'configure','renew-test':'info','renew-enable':'create',delete:'remove'};
      const actionButton=(key)=>'<button type="button" class="button small" data-tone="'+tones[key]+'" data-action="'+key+'">'+labels[key]+'</button>';
      const sslRenewal=inventory.ssl_renewal||{};
      const hasHttps=sites.some(s=>s.https);
      view.innerHTML='<article class="panel"><div class="panel-head"><input class="domain-search" type="search" id="find-site" aria-label="Domain" placeholder="'+vt('Tìm tên miền…','Find domain…')+'"><div class="actions"><button id="refresh-nginx" class="button" data-tone="info"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 12a9 9 0 0 1 15-6.7L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-15 6.7L3 16"/><path d="M3 21v-5h5"/></svg> '+vt('Làm mới','Refresh')+'</button><button id="reload-nginx" class="button" data-tone="configure"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12a9 9 0 1 1-2.64-6.36"/><path d="M21 3v6h-6"/></svg> Reload Nginx</button><button id="copy-sites" class="button" data-tone="info"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg> '+vt('Copy giữa các VPS','Copy across servers')+'</button><button id="delete-selected-sites" class="button" data-tone="remove" hidden>'+vt('Xóa đã chọn','Delete selected')+'</button><button id="create-site" class="button" data-tone="create"><span aria-hidden="true">+</span> Thêm tên miền</button></div></div><div class="ssl-renew-bar"><span class="ssl-renew-info"><span class="site-tag" data-state="'+(sslRenewal.enabled?'on':'off')+'">'+(sslRenewal.enabled?vt('Tự gia hạn SSL · Đang bật','SSL auto-renew · Active'):vt('Tự gia hạn SSL · Chưa bật','SSL auto-renew · Off'))+'</span>'+(sslRenewal.detail?'<code>'+escapeHTML(sslRenewal.detail)+'</code>':'')+'</span><div class="actions"><button type="button" id="cf-token-btn" class="button small" data-tone="configure">'+vt('Token Cloudflare','Cloudflare Token')+'</button>'+(sslRenewal.enabled?(hasHttps?'<button type="button" id="test-ssl-renew" class="button small" data-tone="info">'+vt('Thử gia hạn SSL','Test SSL renewal')+'</button>':''):'<button type="button" id="enable-ssl-renew" class="button small" data-tone="create">'+vt('Bật tự gia hạn SSL','Enable SSL auto-renew')+'</button>')+'</div></div><div class="panel-body" id="site-list"></div></article>';
      const list=$('#site-list');
      for(const message of inventory.diagnostics){
        const note=document.createElement('p');note.textContent=message;list.append(note);
      }
      for(const link of inventory.broken||[]){
        const fix=document.createElement('button');fix.className='button small';fix.textContent='Gỡ symlink hỏng · '+link.path;
        fix.onclick=()=>modal('Gỡ symlink hỏng','<p>'+escapeHTML(link.path)+' → '+escapeHTML(link.target)+'</p>',()=>submit('repair-link',{file_id:link.id}));
        list.append(fix);
      }
      const files=new Map();
      for(const route of sites){
        const key=route.file_id||route.source;
        if(!files.has(key))files.set(key,[]);
        files.get(key).push(route);
      }
      const groups=Array.from(files.values());
      const representative=routes=>routes.find(r=>r.https)||routes[0];
      if(groups.length){
        list.insertAdjacentHTML('beforeend','<div class="table-wrap"><table><thead><tr><th><input type="checkbox" id="select-all-sites" aria-label="'+vt('Chọn tất cả','Select all')+'"></th><th>#</th><th>'+vt('TÊN MIỀN','DOMAIN')+'</th><th>SSL</th><th>'+vt('ĐỊNH TUYẾN & BACKEND','ROUTE & BACKEND')+'</th><th></th></tr></thead><tbody></tbody></table></div>');
        const tbody=list.querySelector('tbody');
        for(const [i,routes] of groups.entries()){
          const site=representative(routes);
          const domains=[...new Set(routes.flatMap(r=>r.domain.split(/\s+/)))].join(' · ');
          const expiry=routes.map(r=>r.expires).filter(Number.isFinite);
          const soonest=Math.min(...expiry);
          const needsCert=!site.https||!(site.renewal_names||[]).length;
          const actions=site.managed?[...(site.port?['edit']:[]),site.enabled?'disable':'enable',...(site.enabled?['certificate']:[]),...(site.enabled&&site.https&&!sslRenewal.enabled?['renew-enable']:[]),'delete']:(site.source.startsWith('/etc/nginx/sites-available/')?[site.enabled?'disable':'enable',...(site.enabled&&needsCert&&site.primary.includes('.')&&routes.length===1?['certificate']:[]),...(site.enabled&&site.https&&!sslRenewal.enabled?['renew-enable']:[]),'delete']:[]);
          if(site.enabled&&site.https)actions.splice(Math.max(0,actions.indexOf('delete')),0,'renew-ssl');
          if(!actions.includes('edit')&&site.enabled&&/^\/etc\/nginx\/(conf\.d|sites-available)\//.test(site.source))actions.unshift('edit');
          const sslBadge=site.https?'<span class="site-tag" data-protocol="tls">'+(Number.isFinite(soonest)?vt('Còn '+soonest+' ngày',soonest+'d left'):vt('Đang bật','Active'))+'</span>':'<span class="site-tag" data-state="off">'+vt('Chưa có SSL','No SSL')+'</span>';
          tbody.insertAdjacentHTML('beforeend',`<tr data-row="${i}"><td><input type="checkbox" class="site-pick" value="${i}"></td><td class="row-number">${i+1}</td><td><div class="domain-name"><strong>${escapeHTML(domains)}</strong> <span class="site-tag" data-state="${site.enabled?'on':'off'}">${site.enabled?'Đang bật':'Đã tắt'}</span></div><small class="domain-source">${escapeHTML(site.source)}</small>${soonest<=30?'<small class="site-warning">SSL · '+certificateWarning(soonest)+'</small>':''}</td><td>${sslBadge}</td><td><div class="file-routes">${routes.map(r=>`<div class="domain-route"><span class="site-tag site-kind">${escapeHTML(r.kind)}</span> <span class="site-tag" data-protocol="${r.https?'tls':'http'}">${r.https?'HTTPS':'HTTP'} · ${escapeHTML(r.listeners.join(', '))}</span> <code>${escapeHTML(r.target)}</code></div>`).join('')}</div></td><td><div class="domain-actions">${(actions.includes('edit')?actions:['detail',...actions]).map(actionButton).join('')}</div></td></tr>`);
        }
      }
      if(!sites.length&&!inventory.diagnostics.length)list.textContent='Chưa có tên miền do Manager quản lý.';
      function openSite(operation,site={}){
        if(operation==='renew-ssl'){
          const names=site.renewal_names||[];
          if(!names.length){
            const certs=(site.ssl_certificates||[]).join(', ');
            const canReissue=site.enabled&&site.primary&&site.primary.includes('.')&&(site.managed||site.source.startsWith('/etc/nginx/sites-available/'));
            modal('Gia hạn SSL','<p>Không tìm thấy hồ sơ gia hạn Certbot trong <code>/etc/letsencrypt/renewal</code> trên VPS (thường do chứng chỉ được chép từ VPS khác hoặc chưa cấp qua Certbot trên máy này).</p>'+(certs?'<p><code>ssl_certificate</code> hiện tại: <code>'+escapeHTML(certs)+'</code></p>':'')+(canReissue?'<p>Bấm <strong>Xác nhận</strong> để mở <strong>Cấp SSL</strong> và tạo hồ sơ Certbot mới trên VPS này.</p>':''),async()=>{if(canReissue)setTimeout(()=>openSite('certificate',site),0);});
            return;
          }
          modal('Gia hạn SSL','<p>'+escapeHTML($('#hosts').selectedOptions[0].textContent)+' · '+escapeHTML(site.domain)+'</p><p>Certbot · '+escapeHTML(names.join(', '))+'</p><p>Gia hạn nếu đến hạn, kiểm tra cấu hình rồi reload Nginx.</p>',
            ()=>submit('renew-ssl',{file_id:site.file_id,domain:site.domain,revision:site.revision}));
          return;
        }
        const domain=site.primary||site.domain||'';
        const context='<p>'+escapeHTML($('#hosts').selectedOptions[0].textContent)+(domain?' · '+escapeHTML(domain):'')+'</p>';
        let fields=operation==='create'?machineChoices():'';
        if(site.file_id&&!site.managed)fields+='<p>'+escapeHTML(sites.filter(s=>s.file_id===site.file_id).map(s=>s.domain).join(', '))+' · '+escapeHTML(site.source)+'</p>';
        if(operation==='create')fields+='<fieldset class="site-draft"><legend>Website 1</legend><div class="site-inputs"><label class="field">Domain<input name="domain" required placeholder="app.example.com"></label>';
        if(operation==='create')fields+=`<label class="field">Kiểu website<select name="kind">${Object.entries({proxy:'Reverse proxy',upstream:'Upstream · Load balancing (nhiều server)',node:'Node.js · Express / Next.js / Nuxt SSR',spa:'Vue / React / Angular · SPA',static:vt('Web tĩnh · HTML','Static website · HTML'),PHP:'PHP-FPM',redirect:vt('Chuyển hướng URL','URL redirect'),WebSocket:'WebSocket',SSE:'SSE',gRPC:'gRPC',raw:vt('Dán file .conf trực tiếp','Paste raw .conf')}).map(([k,label])=>'<option value="'+k+'">'+label+'</option>').join('')}</select></label>
          <label class="field">IP Backend<input name="backend" placeholder="127.0.0.1:3000, app2:3000 weight=2"></label><div class="field wide upstream-builder" hidden><div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:6px"><span>${vt('Danh sách server Upstream','Upstream servers')}</span><button type="button" class="button small add-upstream-srv" data-tone="create">+ ${vt('Thêm server','Add server')}</button></div><div class="upstream-rows" style="display:grid;gap:6px"></div></div>
          <label class="field">Document root<input name="directory" placeholder="/var/www/html"></label>
          <label class="field">URL chuyển hướng<input name="redirect" type="url"></label><label class="field wide" hidden>Nội dung file .conf <select class="fill-raw-preset" style="margin-left:8px;width:auto;display:inline-block"><option value="">— Điền mẫu nhanh —</option><option value="lb">API Load Balancing (Upstream + keepalive)</option><option value="upload">Upload lớn / Streaming (10GB)</option><option value="spa">SPA tối ưu (Vue/React + Cache + Headers)</option></select><textarea name="raw_conf" rows="11" spellcheck="false" placeholder="server { ... }"></textarea></label>
          <details><summary>Tùy chọn nâng cao (Domain phụ, Location, Load balancing)</summary><div class="http-fields">
          <label class="field">Domain bổ sung<input name="names" placeholder="www.example.com"></label>
          <label class="field">Load balancing<select name="algorithm"><option>round-robin</option><option>least_conn</option><option>ip_hash</option></select></label>
          <label class="field">Location<input name="location" value="/"></label><label class="field">Thư mục lưu cấu hình<select name="save_dir"><option value="sites-available">/etc/nginx/sites-available/</option><option value="conf.d">/etc/nginx/conf.d/</option></select></label><label class="field">Tên file .conf (tùy chọn)<input name="conf_name" placeholder="api.zm.io.vn.conf"></label></div></details><details><summary>Tùy chọn HTTP</summary><div class="http-fields">
          <label class="field">CORS origin<input name="cors"></label><label class="field">Response headers<textarea name="headers" placeholder="X-Frame-Options: DENY"></textarea></label>
          <label class="field">IP whitelist<input name="allow_ips" placeholder="192.0.2.0/24, ::1"></label>
          <label class="field">Basic Auth · htpasswd<input name="auth_file" placeholder="/etc/nginx/website.htpasswd"></label>
          <label class="field">Rate limit (req/s)<input name="rate" type="number" value="0" min="0" max="10000"></label>
          <div class="http-switches"><label><input type="checkbox" name="gzip"> gzip</label> <label><input type="checkbox" name="cache"> Proxy cache</label>
          <label><input type="checkbox" name="brotli"> Brotli</label></div></div></details>`;
        const proxy=operation==='edit'||operation==='create';
        if(proxy)fields+='<label class="field">Cổng ứng dụng trên VPS<input name="port" type="number" min="1" max="65535" value="'+Number(site.port||3000)+'" required></label>';
        if(operation==='create')fields+='</div><details class="site-preview-wrap" open style="margin-top:8px"><summary>'+vt('Xem trước cấu hình Nginx','Preview Nginx configuration')+'</summary><pre class="nginx-highlight site-preview" style="margin-top:6px;font-size:12px;max-height:220px;overflow:auto"></pre></details><button type="button" class="button small remove-site" data-tone="remove">× '+vt('Bỏ website','Remove website')+'</button></fieldset><button type="button" class="button small" data-tone="create" id="another-site">+ '+vt('Thêm website khác','Add another website')+'</button>';
        if(operation==='certificate')fields+='<label class="field">Email<input name="email" type="email" required></label><label class="field">Xác thực<select name="method"><option value="http">HTTP-01 · Nginx</option><option value="cloudflare">DNS-01 · Cloudflare</option></select></label><label class="field" hidden id="credential">Cloudflare API token (Zone DNS Edit)<span class="input-eye-wrap"><input name="token" type="password" autocomplete="off"><button type="button" id="show-cf-token" class="input-eye" aria-label="Hiện token"><svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg></button></span></label><p>Cài Certbot và plugin tương ứng trong Software Center trước khi cấp SSL.</p><label class="field">Domain bổ sung<input name="names" placeholder="www.example.com, *.example.com"></label>';
        if(operation==='certificate'&&site.managed&&!site.https)fields+=['http2','http3'].map(k=>'<label><input type="checkbox" name="'+k+'" '+(inventory.capabilities[k]?'':'disabled')+'> '+k.toUpperCase()+'</label>').join(' ');
        if(operation==='certificate'&&!site.https)fields+='<label><input type="checkbox" name="force_https" checked> HTTP → HTTPS</label>';
        if(operation==='delete')fields+='<p>Xóa cấu hình tên miền khỏi Nginx trên máy này?</p>';
        modal(labels[operation]||'Thêm tên miền',(operation==='create'?'<div class="domain-form">'+fields+'</div>':context+fields),form=>{
          const data=Object.fromEntries(form);
          if(operation==='create'){
            const websites=Array.from($('#popup').querySelectorAll('.site-draft'),block=>{
              const draft={};
              for(const field of block.elements){
                if(!field.name||field.disabled||(field.type==='checkbox'&&!field.checked))continue;
                draft[field.name]=field.value.trim();
              }
              draft.domain=draft.domain.toLowerCase();
              draft.names=(draft.names||'').toLowerCase().split(/[\s,]+/).filter(Boolean);
              if(draft.kind==='node'||draft.kind==='upstream')draft.kind='proxy';
              draft.port=Number(draft.port||3000);if(draft.backend&&!draft.backend.includes(':')&&!draft.backend.includes(' '))draft.backend=draft.backend+':'+draft.port;
              return draft;
            });
            return submitTargets(form,'site',{operation,websites});
          }
          if(operation==='certificate'){
            localStorage.setItem('vps-ssl-email',data.email||'');
            localStorage.setItem('vps-ssl-method',data.method||'http');
            if(data.token)localStorage.setItem('vps-ssl-token',data.token);
          }
          if(site.file_id&&!site.managed&&operation==='certificate')return submit('external-certificate',{...data,domain,file_id:site.file_id,revision:site.revision,names:data.names.split(/[\s,]+/).filter(Boolean)});
          if(site.file_id&&!site.managed&&operation==='renew-test')return submit('renew-test',{file_id:site.file_id,domain:site.domain,revision:site.revision});
          if(site.file_id&&!site.managed&&operation==='renew-enable')return submit('ssl-renew-enable',{});
          if(site.file_id&&!site.managed)return submit('lifecycle',{file_id:site.file_id,revision:site.revision,operation});
          const payload={...data,domain:domain||data.domain.trim().toLowerCase(),operation,revision:site.revision||'',names:(data.names||'').split(/[\s,]+/).filter(Boolean),port:Number(data.port||3000)};
          return submit('site',payload);
        });
        const form=$('#popup');
        if(operation==='create'){
          const first=form.querySelector('.site-draft'),template=first.cloneNode(true),add=$('#another-site');
          const pm2=api(path+'/pm2').catch(()=>[]);
          function renumber(){
            const drafts=form.querySelectorAll('.site-draft');
            drafts.forEach((block,i)=>{
              block.querySelector('legend').textContent='Website '+(i+1);
              block.querySelector('.remove-site').hidden=drafts.length===1;
            });
            add.disabled=drafts.length>=50;
          }
          function bindDraft(block){
            const options=block.elements;
            options.brotli.disabled=!inventory.capabilities.brotli;
            block.querySelectorAll('details').forEach(d=>d.parentElement.append(d));
            block.querySelector('.remove-site').onclick=()=>{block.remove();renumber();};
            let lastKind='';
            options.kind.onchange=()=>{
              const kind=options.kind.value,proxyKind=['proxy','node','upstream','WebSocket','SSE','gRPC'].includes(kind);
              if(kind==='PHP'&&lastKind!=='PHP')options.backend.value=inventory.php_sockets?.[0]?'unix:'+inventory.php_sockets[0]:'';
              if(kind!=='PHP'&&lastKind==='PHP')options.backend.value='';
              const ub=block.querySelector('.upstream-builder');if(ub)ub.hidden=kind!=='upstream';
              for(const [name,visible] of Object.entries({backend:(proxyKind&&kind!=='upstream')||kind==='PHP',algorithm:proxyKind,port:proxyKind&&kind!=='upstream',directory:['static','PHP','spa'].includes(kind),redirect:kind==='redirect',location:proxyKind||kind==='static',raw_conf:kind==='raw'})){
                options[name].closest('label').hidden=!visible;options[name].disabled=(name==='backend'&&kind==='upstream')?false:!visible;
              }
              options.backend.placeholder=kind==='PHP'?'unix:/run/php/php-fpm.sock':'127.0.0.1';
              options.directory.placeholder=kind==='spa'?'/var/www/app/dist':'/var/www/html';
              options.directory.required=kind==='spa';options.backend.required=kind==='PHP';options.redirect.required=kind==='redirect';options.raw_conf.required=kind==='raw';const prevWrap=block.querySelector('.site-preview-wrap');if(prevWrap)prevWrap.hidden=kind==='raw';
              options.cache.disabled=!['proxy','node'].includes(kind);
              if(kind==='upstream')syncUpstream();
              lastKind=kind;
            };
            function updatePreview(){
              const pre=block.querySelector('.site-preview');if(!pre)return;
              const d=(options.domain.value||'app.example.com').trim().toLowerCase();
              const extra=(options.names.value||'').trim().split(/[\s,]+/).filter(Boolean);
              const names=[d,...extra].join(' ');
              const k=options.kind.value,loc=options.location.value||'/';
              const port=Number(options.port.value||3000),rawVal=options.backend.value.trim(),rawBe=rawVal?(rawVal.includes(':')||rawVal.includes(' ')?rawVal:rawVal+':'+port):('127.0.0.1:'+port);
              const entries=rawBe.split(',').map(s=>s.trim()).filter(Boolean);
              let prefix='',be=rawBe;
              if(['proxy','upstream','WebSocket','SSE','gRPC','PHP'].includes(k)&&(k==='upstream'||entries.length>1||rawBe.includes(' '))){
                const pool='zm_'+d.replace(/[.-]/g,'_'),alg=options.algorithm.value;
                const ul=(alg==='round-robin'?[]:[alg+';']).concat(['keepalive 32;'],entries.map(x=>'server '+x+';'));
                prefix=`upstream ${pool} {\n    ${ul.join('\n    ')}\n}\n\n`;
                be=pool;
              }
              let body='';
              if(k==='redirect')body=`    return 301 ${options.redirect.value||'https://example.com'}$request_uri;`;
              else if(k==='static')body=`    root ${options.directory.value||'/var/www/html'};\n    location ${loc} {\n        try_files $uri $uri/ =404;\n    }`;
              else if(k==='spa')body=`    root ${options.directory.value||'/var/www/app/dist'};\n    location / {\n        try_files $uri $uri/ /index.html;\n    }`;
              else if(k==='PHP')body=`    root ${options.directory.value||'/var/www/html'};\n    index index.php index.html;\n    location ~ \\.php$ {\n        include snippets/fastcgi-php.conf;\n        fastcgi_pass ${be};\n    }`;
              else if(k==='gRPC')body=`    location ${loc} {\n        grpc_pass grpc://${be};\n    }`;
              else if(k==='WebSocket')body=`    location ${loc} {\n        proxy_pass http://${be};\n        proxy_http_version 1.1;\n        proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection "upgrade";\n    }`;
              else if(k==='SSE')body=`    location ${loc} {\n        proxy_pass http://${be};\n        proxy_buffering off;\n        proxy_cache off;\n    }`;
              else body=`    location ${loc} {\n        proxy_pass http://${be};\n        proxy_http_version 1.1;\n        proxy_set_header Host $host;\n        proxy_set_header X-Forwarded-Proto $scheme;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n    }`;
              const opts=[];
              if(options.gzip.checked)opts.push('    gzip on;\n    gzip_types text/plain text/css application/json application/javascript;');
              if(options.brotli.checked)opts.push('    brotli on;');
              if(options.cors.value.trim())opts.push('    add_header Access-Control-Allow-Origin "'+options.cors.value.trim()+'" always;');
              if(Number(options.rate.value)>0)opts.push('    # rate limit '+options.rate.value+'r/s');
              pre.textContent=`${prefix}server {\n    listen 80;\n    server_name ${names};\n${body}${opts.length?'\n'+opts.join('\n'):''}\n}`;
            }

            block.addEventListener('input',updatePreview);block.addEventListener('change',updatePreview);
            const sampleSel=block.querySelector('.fill-raw-preset');
            if(sampleSel)sampleSel.onchange=()=>{
              const d=(options.domain.value||'example.com').trim(),pool='backend_'+d.replace(/[.-]/g,'_'),p=Number(options.port.value||3000),dir=(options.directory.value||'/var/www/app/dist').trim();
              const presets={
                lb:`upstream ${pool} {\n    zone ${pool} 64k;\n    least_conn;\n    keepalive 128;\n    server 127.0.0.1:${p} weight=5 max_fails=3 fail_timeout=10s;\n}\n\nserver {\n    listen 80;\n    server_name ${d};\n    access_log off;\n    error_log /var/log/nginx/${d}.log crit;\n    keepalive_timeout 30s;\n    tcp_nodelay on;\n    location / {\n        proxy_pass http://${pool};\n        proxy_http_version 1.1;\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto $scheme;\n        proxy_set_header Connection "";\n        proxy_connect_timeout 3s;\n        proxy_send_timeout 30s;\n        proxy_read_timeout 30s;\n        proxy_buffering off;\n        proxy_cache off;\n        gzip on;\n        gzip_types application/json;\n        gzip_min_length 2048;\n        gzip_comp_level 4;\n        proxy_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504;\n        proxy_next_upstream_tries 2;\n    }\n}`,
                upload:`server {\n    listen 80;\n    server_name ${d};\n    client_max_body_size 10G;\n    client_body_timeout 3600s;\n    access_log /var/log/nginx/${d}.access.log;\n    error_log /var/log/nginx/${d}.error.log;\n    location / {\n        proxy_pass http://127.0.0.1:${p};\n        proxy_http_version 1.1;\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto $scheme;\n        proxy_request_buffering off;\n        proxy_buffering off;\n        proxy_connect_timeout 60s;\n        proxy_send_timeout 3600s;\n        proxy_read_timeout 3600s;\n        proxy_redirect off;\n    }\n}`,
                spa:`server {\n    listen 80;\n    server_name ${d};\n    root ${dir};\n    index index.html;\n    access_log /var/log/nginx/${d}.access.log;\n    error_log /var/log/nginx/${d}.error.log;\n    gzip on;\n    gzip_vary on;\n    gzip_proxied any;\n    gzip_comp_level 6;\n    gzip_min_length 1024;\n    gzip_types application/javascript application/json application/xml font/opentype image/svg+xml text/css text/javascript text/plain text/xml;\n    add_header X-Frame-Options "SAMEORIGIN" always;\n    add_header X-XSS-Protection "1; mode=block" always;\n    add_header X-Content-Type-Options "nosniff" always;\n    add_header Referrer-Policy "no-referrer-when-downgrade" always;\n    location = /index.html {\n        add_header Cache-Control "no-cache, no-store, must-revalidate";\n        add_header Pragma "no-cache";\n        add_header Expires "0";\n    }\n    location ~* \\.(css|js)$ {\n        access_log off;\n        add_header Cache-Control "public, max-age=31536000, immutable";\n        expires 1y;\n    }\n    location ~* \\.(?:jpg|jpeg|gif|png|ico|webp|svg|woff|woff2|ttf|eot|otf)$ {\n        access_log off;\n        add_header Cache-Control "public, max-age=2592000";\n        expires 30d;\n    }\n    location ~ /\\. { deny all; }\n    location / { try_files $uri $uri/ /index.html; }\n}`
              };
              if(presets[sampleSel.value])options.raw_conf.value=presets[sampleSel.value];
            };
            const upRows=block.querySelector('.upstream-rows'),addUp=block.querySelector('.add-upstream-srv');
            function syncUpstream(){
              if(options.kind.value!=='upstream')return;
              const vals=[...upRows.querySelectorAll('.up-row')].map(r=>{
                const h=r.querySelector('.up-host').value.trim();if(!h)return '';
                const w=r.querySelector('.up-w').value.trim(),mf=r.querySelector('.up-mf').value.trim(),ft=r.querySelector('.up-ft').value.trim();
                return h+(w?' weight='+w:'')+(mf?' max_fails='+mf:'')+(ft?' fail_timeout='+ft:'');
              }).filter(Boolean);
              options.backend.value=vals.join(', ');
              updatePreview();
            }
            function addUpRow(hp='127.0.0.1:4003'){
              const row=document.createElement('div');row.className='up-row';row.style.cssText='display:grid;grid-template-columns:2fr 1fr 1fr 1fr auto;gap:6px;align-items:center';
              row.innerHTML='<input class="up-host" placeholder="171.244.21.247:4003" value="'+escapeHTML(hp)+'"><input class="up-w" type="number" min="1" placeholder="weight (5)"><input class="up-mf" type="number" min="1" placeholder="max_fails (3)"><input class="up-ft" placeholder="timeout (10s)"><button type="button" class="button small" data-tone="remove">×</button>';
              row.querySelector('button').onclick=()=>{row.remove();syncUpstream();};
              row.oninput=syncUpstream;
              upRows.append(row);syncUpstream();
            }
            if(addUp){addUp.onclick=()=>addUpRow('');addUpRow('127.0.0.1:4003');}
            options.kind.onchange();updatePreview();
            attachProcesses(options.port,pm2);
          }
          add.onclick=()=>{const block=template.cloneNode(true);add.before(block);bindDraft(block);renumber();block.elements.domain.focus();};
          bindDraft(first);renumber();
        }
        if(operation==='certificate'){
          const method=form.elements.method,token=form.elements.token;
          form.elements.email.value=localStorage.getItem('vps-ssl-email')||'';
          method.value=localStorage.getItem('vps-ssl-method')||'http';
          token.value=localStorage.getItem('vps-ssl-token')||'';
          $('#show-cf-token').onclick=()=>{const show=token.type==='password';token.type=show?'text':'password';$('#show-cf-token').setAttribute('aria-pressed',String(show));};
          method.onchange=()=>{const dns=method.value==='cloudflare';$('#credential').hidden=!dns;token.disabled=!dns;token.required=dns;};
          method.onchange();
          if(!token.value)api('vps/cloudflare-token').then(saved=>{if(token.isConnected&&!token.value&&saved?.token){token.value=saved.token;localStorage.setItem('vps-ssl-token',saved.token);}}).catch(()=>{});
        }
        if(operation==='edit')attachProcesses(form.elements.port,api(path+'/pm2'));
        function attachProcesses(port,request){
          request.then(processes=>{
            if(!port.isConnected)return;
            const uniq=Array.from(new Map((processes||[]).map(x=>[x.port,x])).values());
            if(!uniq.length)return;
            const row=document.createElement('div');row.style.cssText='display:flex;gap:6px;align-items:center;width:100%';
            const sel=document.createElement('select');sel.setAttribute('aria-label','PM2');sel.style.cssText='width:auto;max-width:165px;flex-shrink:0';
            sel.append(new Option('PM2…',''),...uniq.map(p=>new Option((p.name&&String(p.name)!==String(p.port)?p.name+' · ':'')+p.port,p.port)));
            sel.onchange=()=>{if(sel.value){port.value=sel.value;port.dispatchEvent(new Event('input',{bubbles:true}));}};
            port.replaceWith(row);row.append(port,sel);
          }).catch(()=>{});
        }
      }
      $('#find-site').oninput=e=>{
        const term=e.target.value.toLowerCase().trim();
        for(const row of list.querySelectorAll('[data-row]'))row.hidden=!row.querySelector('.domain-info').textContent.toLowerCase().includes(term);
        const none=groups.length&&![...list.querySelectorAll('[data-row]')].some(row=>!row.hidden);
        let empty=list.querySelector('.domain-empty');
        if(none&&!empty){empty=document.createElement('p');empty.className='domain-empty';empty.textContent=vt('Không tìm thấy tên miền.','No matching domain.');list.append(empty);}
        if(empty)empty.hidden=!none;
      };
      $('#create-site').onclick=()=>openSite('create');
      const delBulk=$('#delete-selected-sites'),pickAll=$('#select-all-sites');
      function syncBulk(){
        const count=list.querySelectorAll('.site-pick:checked').length;
        if(delBulk){delBulk.hidden=!count;delBulk.textContent=vt('Xóa đã chọn ('+count+')','Delete selected ('+count+')');}
      }
      if(pickAll)pickAll.onchange=()=>{list.querySelectorAll('.site-pick').forEach(c=>{if(!c.closest('tr').hidden)c.checked=pickAll.checked;});syncBulk();};
      list.addEventListener('change',e=>{if(e.target.classList.contains('site-pick'))syncBulk();});
      if(delBulk)delBulk.onclick=()=>{
        const picks=[...list.querySelectorAll('.site-pick:checked')].map(c=>representative(groups[Number(c.value)]));
        if(!picks.length)return;
        modal(vt('Xóa các cấu hình đã chọn','Delete selected configurations'),'<p>'+escapeHTML($('#hosts').selectedOptions[0].textContent)+'</p><ul>'+picks.map(s=>'<li><strong>'+escapeHTML(s.domain)+'</strong> · <small>'+escapeHTML(s.source)+'</small></li>').join('')+'</ul><p>'+vt('Xóa các cấu hình này khỏi Nginx trên VPS?','Remove these configurations from Nginx on this server?')+'</p>',()=>{
          if($('dialog')?.open)$('dialog').close();
          (async()=>{
            const banner=document.createElement('div');banner.className='fw-job-banner';banner.innerHTML='<span class="spinner"></span><span></span><button type="button" class="banner-close" aria-label="Đóng">×</button>';
            banner.querySelector('.banner-close').onclick=()=>banner.remove();
            vpsToastStack().append(banner);
            const msg=banner.querySelector('span:not(.spinner)');banner.dataset.state='running';
            try{
              for(const [idx,s] of picks.entries()){
                msg.textContent=vt('Đang xóa ','Deleting ')+(idx+1)+'/'+picks.length+' · '+s.domain;
                const job=s.managed?await api(endpoint()+'/site',{domain:s.primary||s.domain,operation:'delete',revision:s.revision||'',names:[],port:Number(s.port||3000)}):await api(endpoint()+'/lifecycle',{file_id:s.file_id,revision:s.revision,operation:'delete'});
                for(let i=0;i<120;i++){
                  await new Promise(r=>setTimeout(r,500));
                  const j=await api('vps/jobs/'+encodeURIComponent(job.id)).catch(()=>null);
                  if(!j||j.status==='succeeded')break;
                  if(j.status==='failed'||j.status==='interrupted')throw new Error((s.domain||'')+': '+(j.error||vt('Xóa thất bại','Delete failed')));
                }
              }
              banner.remove();vpsGetCache.clear();await render();
              const ok=document.createElement('div');ok.className='fw-job-banner';ok.dataset.state='ok';
              ok.innerHTML='<span>✓ '+escapeHTML(vt('Đã xóa '+picks.length+' cấu hình Nginx','Deleted '+picks.length+' Nginx configs'))+'</span><button type="button" class="banner-close" aria-label="Đóng">×</button>';
              ok.querySelector('.banner-close').onclick=()=>ok.remove();
              vpsToastStack().append(ok);setTimeout(()=>ok.remove(),5000);
            }catch(err){
              banner.remove();vpsGetCache.clear();await render();
              modal('✗ '+vt('Xóa thất bại','Delete failed'),'<div class="callout error" style="white-space:pre-wrap">'+escapeHTML(err.message)+'</div>',async()=>{});
            }
          })();
        });
      };
      $('#refresh-nginx').onclick=()=>{vpsGetCache.clear();render();};
      if($('#cf-token-btn'))$('#cf-token-btn').onclick=()=>{
        modal(vt('Token Cloudflare cho các VPS','Cloudflare API Token for servers'),
          machineChoices(true)
          +'<label class="field">'+vt('Cloudflare API Token (Zone:DNS:Edit)','Cloudflare API Token (Zone:DNS:Edit)')+'<span class="input-eye-wrap"><input name="token" type="password" required autocomplete="off" placeholder="cfut_…" value="'+escapeHTML(localStorage.getItem('vps-ssl-token')||'')+'"><button type="button" id="show-cf-batch-token" class="input-eye" aria-label="Hiện token"><svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg></button></span></label>'
          +'<label class="field">'+vt('Tên tệp credential (/etc/letsencrypt/zm-credentials/<tên>.ini)','Credential name (/etc/letsencrypt/zm-credentials/<name>.ini)')+'<input name="name" value="default" placeholder="default"></label>'
          +'<label><input type="checkbox" name="update_renewal" checked> '+vt('Cập nhật cho các hồ sơ Certbot Cloudflare hiện có (/etc/letsencrypt/renewal/*.conf)','Update existing Cloudflare Certbot renewal credentials')+'</label>',
          form=>{
            const token=(form.get('token')||'').trim();
            localStorage.setItem('vps-ssl-token',token);
            return submitTargets(form,'cloudflare-token',{token,name:(form.get('name')||'default').trim(),update_renewal:!!form.get('update_renewal')});
          });
        const cfForm=$('#popup'),cfInput=cfForm.elements.token,cfEye=$('#show-cf-batch-token');
        cfEye.onclick=()=>{const show=cfInput.type==='password';cfInput.type=show?'text':'password';cfEye.setAttribute('aria-pressed',String(show));};
        api('vps/cloudflare-token').then(saved=>{
          if(!cfInput.isConnected||!saved)return;
          if(saved.token){cfInput.value=saved.token;localStorage.setItem('vps-ssl-token',saved.token);}
          if(saved.name&&cfForm.elements.name)cfForm.elements.name.value=saved.name;
        }).catch(()=>{});
      };
      if($('#enable-ssl-renew'))$('#enable-ssl-renew').onclick=()=>modal(vt('Bật tự gia hạn SSL','Enable SSL auto-renew'),'<p>'+escapeHTML($('#hosts').selectedOptions[0].textContent)+'</p><p>'+vt('Kích hoạt systemd timer (certbot.timer / certbot-renew.timer / snap.certbot.renew.timer) hoặc cron định kỳ để tự động gia hạn chứng chỉ SSL trước khi hết hạn và reload Nginx.','Enable the systemd timer or periodic cron job to automatically renew SSL certificates before expiry and reload Nginx.')+'</p>',()=>submit('ssl-renew-enable',{}));
      if($('#test-ssl-renew'))$('#test-ssl-renew').onclick=()=>modal(vt('Thử gia hạn SSL','Test SSL renewal'),'<p>'+escapeHTML($('#hosts').selectedOptions[0].textContent)+'</p><p>'+vt('Chạy certbot renew --dry-run cho toàn bộ chứng chỉ trên VPS (không làm gián đoạn dịch vụ).','Run certbot renew --dry-run for all certificates on this server.')+'</p>',()=>submit('ssl-renew-test',{}));
      $('#reload-nginx').onclick=async()=>{
        modal('nginx -t & Reload Nginx','<p>'+escapeHTML($('#hosts').selectedOptions[0].textContent)+'</p><div id="nginx-t-box"><span class="spinner"></span> '+vt('Đang chạy nginx -t…','Running nginx -t…')+'</div>',()=>submit('nginx-reload',{}));
        const confirmBtn=$('#popup button[type=submit]'),box=$('#nginx-t-box');
        confirmBtn.disabled=true;
        try{
          const res=await api(path+'/nginx/test?t='+Date.now());
          if(!box.isConnected)return;
          box.innerHTML=res.ok
            ?'<div class="callout" style="margin:0">✓ '+escapeHTML(res.output||'nginx -t · OK')+'</div>'
            :'<div class="callout error" style="margin:0;white-space:pre-wrap">✗ '+escapeHTML(res.output||'nginx -t thất bại')+'</div>';
          confirmBtn.disabled=!res.ok;
        }catch(err){if(box.isConnected)box.innerHTML='<div class="callout error" style="margin:0">✗ '+escapeHTML(err.message)+'</div>';}
      };
      $('#copy-sites').onclick=()=>openNginxCopy();
      list.onclick=e=>{const button=e.target.closest('[data-action]');if(!button)return;const routes=groups[Number(button.closest('[data-row]').dataset.row)];const site=representative(routes);if(button.dataset.action==='renew-ssl'&&routes.filter(r=>r.https).length>1){const tls=routes.filter(r=>r.https);modal(labels['renew-ssl'],'<label class="field">Domain<select name="route">'+tls.map((r,i)=>'<option value="'+i+'">'+escapeHTML(r.domain+' · '+(r.renewal_names||[]).join(', '))+'</option>').join('')+'</select></label>',form=>{const r=tls[Number(form.get('route'))];return submit('renew-ssl',{file_id:r.file_id,domain:r.domain,revision:r.revision});});return;}if(button.dataset.action==='detail'||(button.dataset.action==='edit'&&!(site.managed&&site.port))){showWebsite(site,path,rev).catch(err=>{if(revision===rev)view.textContent=err.message;});}else openSite(button.dataset.action,site);};
      return;
    }
    const target=section==='software'?softwarePage(view,path,$('#hosts').value):view;
    if(!target)return;
    const snapKey='vps-snap:'+path;
    let info;
    try{
      const saved=JSON.parse(localStorage.getItem(snapKey)||'null');
      if(saved&&!vpsGetCache.has(path)){
        info=saved;
        if(section==='overview')overviewPage(view,info,path);else softwareCenter(target,info);
      }else{
        target.innerHTML='<div class="loading"><span class="spinner"></span>'+escapeHTML(vt('Đang đọc thông tin VPS…','Reading server information…'))+'</div>';
      }
    }catch{target.innerHTML='<div class="loading"><span class="spinner"></span>'+escapeHTML(vt('Đang đọc thông tin VPS…','Reading server information…'))+'</div>';}
    try{
      const fresh=await api(path);
      localStorage.setItem(snapKey,JSON.stringify(fresh));
      if(rev!==revision)return;
      if(info&&JSON.stringify(info)===JSON.stringify(fresh))return;
      info=fresh;
    }catch(err){
      if(section!=='software')throw err;
      const catalog=await api('vps/catalog');
      info={...catalog,packages:{},checkError:err.message};
    }
    if(rev!==revision)return;
    if(section==='overview'){
      overviewPage(view,info,path);
    }else{
      softwareCenter(target,info);
      if(info.active_install)setTimeout(()=>{if(rev===revision)render();},5000);
    }
    if(info.checked_at||info.checkError){
      const bar=document.createElement('div');bar.className='snapshot-status';
      const state=document.createElement('span'), refresh=document.createElement('button');
      state.textContent=info.checkError?vt('Chưa xác minh','Unverified')+' · '+info.checkError:(vpsEnglish?'Last checked · ':'Kiểm tra gần nhất · ')+new Date(info.checked_at*1000).toLocaleString();
      refresh.className='button small';refresh.type='button';refresh.textContent=vpsEnglish?'Refresh':'Làm mới';
      bar.append(state,refresh);$('#heading-actions').append(bar);
      async function update(background){
        refresh.disabled=true;
        try{
          await api(path+'?refresh=true');
          if(rev!==revision)return;
          await render();
        }catch(err){
          if(rev===revision){
            state.textContent=vt('Chưa xác minh','Unverified')+' · '+err.message;
            if(section==='software'){
              softwareCenter(target,{...info,packages:{}});
              if($('#account'))$('#account').onclick=()=>accountDialog().catch(e=>modal('SSH',escapeHTML(e.message),async()=>{}));
            }
          }
        }
        finally{refresh.disabled=false;}
      }
      refresh.onclick=()=>update(false);
      if(info.stale)update(true);
      else if(section==='overview' && !info.disk_total && !legacySnapshots.has(path)){
        legacySnapshots.add(path);update(true);
      }
    }
    if($('#account'))$('#account').onclick=()=>accountDialog().catch(err=>modal('Tài khoản & SSH','<p>'+escapeHTML(err.message)+'</p>',async()=>{}));
  }catch(err){if(rev===revision)view.textContent=err.message;}
}
$('#view').onclick=e=>{if(e.target.closest('[data-job]')){selectedJob=e.target.closest('[data-job]').dataset.job;sessionStorage.setItem('vps-selected-job',selectedJob);location.hash='jobs';render();}};
async function loadHosts(id){
 const hosts=(await api('vps/machines')).slice().sort((a,b)=>String(a.name||a.host||'').localeCompare(String(b.name||b.host||''),undefined,{numeric:true,sensitivity:'base'}));$('#hosts').replaceChildren(...hosts.map(m=>new Option(m.name,m.id)));const savedId=id||localStorage.getItem('vps-selected-machine');if(hosts.some(m=>m.id===savedId))$('#hosts').value=savedId;if($('#hosts').value)localStorage.setItem('vps-selected-machine',$('#hosts').value);await render();
}
$('#add').onclick=()=>addVps();
$('dialog').addEventListener('close',()=>{for(const input of $('#popup').querySelectorAll('input[type=password],input[autocomplete=new-password]'))input.value='';});
$('#hosts').onchange=()=>{selectedJob='';sessionStorage.removeItem('vps-selected-job');localStorage.setItem('vps-selected-machine',$('#hosts').value);const u=new URL(location.href);u.searchParams.set('machine',$('#hosts').value);history.replaceState(null,'',u);render();};
function toggleMenu(open){document.body.classList.toggle('nav-open',open);$('#menu').setAttribute('aria-expanded',String(open));}
$('#menu').onclick=()=>toggleMenu(true);
$('#navigation').onclick=e=>{if(e.target.closest('a'))toggleMenu(false);};
document.addEventListener('click',e=>{if(document.body.classList.contains('nav-open')&&!e.target.closest('#sidebar,#menu'))toggleMenu(false);});
const desktopMenu=matchMedia('(min-width:681px)');
function syncSidebar(){
  const collapsed=desktopMenu.matches&&localStorage.getItem('vps-sidebar-collapsed')==='1';
  document.body.classList.toggle('sidebar-hidden',collapsed);
  const toggle=$('#close-menu');
  toggle.textContent=collapsed?'»':'«';
  toggle.setAttribute('aria-expanded',String(!collapsed));
  const label=desktopMenu.matches?(collapsed?(vpsEnglish?'Expand menu':'Mở rộng menu'):(vpsEnglish?'Collapse menu':'Thu gọn menu')):(vpsEnglish?'Close menu':'Đóng menu');
  toggle.title=label;toggle.setAttribute('aria-label',label);
  for(const link of $('#navigation').querySelectorAll('a')){
    const text=link.querySelector('span').textContent;
    link.title=vpsEnglish?(englishLabels[text]||text):text;
    link.setAttribute('aria-label',link.title);
  }
}
$('#close-menu').onclick=()=>{
  if(!desktopMenu.matches){toggleMenu(false);return;}
  localStorage.setItem('vps-sidebar-collapsed',document.body.classList.contains('sidebar-hidden')?'0':'1');
  syncSidebar();
};
desktopMenu.addEventListener('change',()=>{toggleMenu(false);syncSidebar();});
syncSidebar();
window.onhashchange=()=>{toggleMenu(false);render();};
$('#logout').onclick=async()=>{await api('auth/logout',{});location.reload();};
async function start(){
 const auth=await api('auth/status');
 if(!auth.authenticated){managerLogin();return;}
 currentAuth=auth;
 csrf=auth.csrf;
 $('#shell').hidden=false;
 $('#admin-username').textContent=auth.username;
 $('#manager-account .avatar').textContent=(auth.username||'AD').slice(0,2).toUpperCase();
 $('#manager-account').title=vt('Tài khoản của tôi','My account')+' · '+auth.username;
 $('#manager-account').setAttribute('aria-label',$('#manager-account').title);
 $('#manager-account').onclick=()=>managerLogin(true);
 const topActions=$('.top-actions');
 topActions.querySelectorAll('.zm-extra-btn').forEach(el=>el.remove());
 const nav=$('#navigation');
 nav.querySelectorAll('.zm-nav-users').forEach(el=>el.remove());
 if(auth.workspace_owner&&auth.workspace_owner.id&&auth.workspace_owner.id!==auth.user_id){
   const wsBtn=document.createElement('button');
   wsBtn.type='button';wsBtn.className='button small zm-extra-btn';wsBtn.dataset.tone='warning';
   wsBtn.textContent='Workspace: '+auth.workspace_owner.username+' ✕';
   wsBtn.onclick=()=>window.zmWorkspaceHelper.setTarget('');
   topActions.insertBefore(wsBtn,$('#manager-account'));
 }
 const preview=$('#preview-mode'),banner=$('#demo-banner');
 preview.textContent=previewMode?(vpsEnglish?'● Preview mode':'● Đang xem thử'):(vpsEnglish?'Preview':'Xem thử giao diện');
 preview.setAttribute('aria-pressed',String(previewMode));
 preview.onclick=()=>{localStorage.setItem('mongo-manager-demo',String(!previewMode));location.reload();};
 banner.hidden=!previewMode;
 banner.textContent=vpsEnglish?'Sample data · VPS actions are simulated.':'Dữ liệu minh họa · Các thao tác xem thử không thay đổi VPS.';
 const links=await api('manager-links').catch(()=>({mongo:'/'}));const url=new URL(links.mongo||'/',location.href);url.hash=sessionStorage.getItem('zm-mongo-route')||'';$('#mongo').href=$('#mobile-mongo').href=url;
 await loadHosts(new URLSearchParams(location.search).get('machine'));
 resumeActiveJobs();
}
$('#language').value=vpsEnglish?'en':'vi';
$('#language').onchange=e=>{localStorage.setItem('mongo-manager-language',e.target.value);location.reload();};
start().catch(err=>{document.body.textContent=err.message;});
setInterval(()=>{if(!document.hidden&&!$('#shell').hidden&&location.hash==='#jobs')render();},5000);

function openNginxCopy(){
  const opts=Array.from($('#hosts').options);
  const srcOpts=opts.map(o=>'<option value="'+escapeHTML(o.value)+'" '+(o.selected?'selected':'')+'>'+escapeHTML(o.textContent)+'</option>').join('');
  modal(vt('Copy Nginx & SSL giữa các VPS','Copy Nginx & SSL across servers'),
    '<div class="copy-split">'
    +'<section class="copy-pane"><h3>'+vt('1. VPS nguồn','1. Source server')+'</h3>'
    +'<label class="field">'+vt('Chọn VPS nguồn','Select source')+'<select name="source_machine" id="copy-src">'+srcOpts+'</select></label>'
    +'<div id="copy-src-sites" class="copy-list">'+vt('Đang đọc danh sách site…','Loading sites…')+'</div>'
    +'<label><input type="checkbox" name="include_ssl" checked> '+vt('Copy kèm chứng chỉ SSL (/etc/letsencrypt)','Include SSL certificates (/etc/letsencrypt)')+'</label>'
    +'<label><input type="checkbox" name="reissue_ssl" checked> '+vt('Tự tạo hồ sơ tự gia hạn Certbot (Cloudflare DNS-01)','Auto-create Certbot renewal profile (Cloudflare DNS-01)')+'</label>'
    +'<label class="field" id="copy-ssl-email-wrap">'+vt('Email Certbot','Certbot Email')+'<input name="email" type="email" value="'+escapeHTML(localStorage.getItem('vps-ssl-email')||'admin@zm.io.vn')+'" placeholder="admin@zm.io.vn"></label>'
    +'</section>'
    +'<section class="copy-pane"><h3>'+vt('2. VPS đích','2. Target servers')+' · <label style="font-weight:500;font-size:12px;cursor:pointer"><input type="checkbox" id="copy-targets-all"> '+vt('Chọn tất cả','Select all')+'</label></h3>'
    +'<div id="copy-targets" class="copy-list"></div>'
    +'<label><input type="checkbox" name="overwrite"> '+vt('Ghi đè nếu file .conf đã tồn tại','Overwrite existing .conf files')+'</label>'
    +'</section></div><pre id="copy-conf-preview" class="nginx-highlight" hidden style="margin-top:12px;max-height:240px;overflow:auto;font-size:12px"></pre>',
    async form=>{
      const file_ids=form.getAll('file_ids'),target_machines=form.getAll('target_machines');
      if(!file_ids.length)throw new Error(vt('Chọn ít nhất một site để copy.','Select at least one site.'));
      if(!target_machines.length)throw new Error(vt('Chọn ít nhất một VPS đích.','Select at least one target server.'));
      const email=(form.get('email')||'').trim();
      if(form.get('reissue_ssl')&&email)localStorage.setItem('vps-ssl-email',email);
      const results=await api('vps/nginx/copy',{source_machine:form.get('source_machine'),target_machines,file_ids,include_ssl:!!form.get('include_ssl'),overwrite:!!form.get('overwrite'),reissue_ssl:!!form.get('reissue_ssl'),email});
      const names=new Map(opts.map(o=>[o.value,o.textContent]));
      sessionStorage.setItem('vps-batch',JSON.stringify(results.map(r=>({...r,name:names.get(r.machine)}))));
      if($('dialog')?.open)$('dialog').close();
      for(const row of results){
        const name=names.get(row.machine)||row.machine;
        if(!row.job){
          if(row.error){
            const errBanner=document.createElement('div');errBanner.className='fw-job-banner';errBanner.dataset.state='error';
            errBanner.innerHTML='<span>✗ '+escapeHTML(name+' · '+row.error)+'</span><button type="button" class="banner-close" aria-label="Đóng">×</button>';
            errBanner.querySelector('.banner-close').onclick=()=>errBanner.remove();
            vpsToastStack().append(errBanner);
          }
          continue;
        }
        trackJobBanner(row.job,{prefix:name+' · '});
      }
    });
  const srcSel=$('#copy-src'),srcList=$('#copy-src-sites'),tgtList=$('#copy-targets'),tgtAll=$('#copy-targets-all');
  const reissueBox=$('#popup').elements.reissue_ssl,emailWrap=$('#copy-ssl-email-wrap');
  if(reissueBox&&emailWrap){reissueBox.onchange=()=>{emailWrap.hidden=!reissueBox.checked;};reissueBox.onchange();}
  if(tgtAll)tgtAll.onchange=()=>{tgtList.querySelectorAll('input[name="target_machines"]').forEach(c=>{c.checked=tgtAll.checked;});};
  function renderTargets(){
    const sId=srcSel.value;
    tgtList.innerHTML=opts.filter(o=>o.value!==sId).map(o=>'<label><input type="checkbox" name="target_machines" value="'+escapeHTML(o.value)+'"> '+escapeHTML(o.textContent)+'</label>').join('')||'<small>'+vt('Không có VPS đích khác.','No other servers.')+'</small>';
    if(tgtAll)tgtAll.checked=false;
  }
  async function loadSrc(){
    renderTargets();
    srcList.textContent=vt('Đang đọc danh sách site…','Loading sites…');
    try{
      const inv=await api('vps/machines/'+encodeURIComponent(srcSel.value)+'/nginx');
      const seen=new Set(),unique=inv.sites.filter(x=>{if(seen.has(x.file_id))return false;seen.add(x.file_id);return true;});
      srcList.innerHTML=unique.map(x=>'<div style="display:flex;align-items:center;justify-content:space-between;gap:6px"><label style="flex:1;min-width:0"><input type="checkbox" name="file_ids" value="'+escapeHTML(x.file_id)+'"> <strong>'+escapeHTML(x.domain)+'</strong> <small>'+escapeHTML(x.source.split('/').pop())+'</small></label><button type="button" class="icon-button copy-preview-btn" data-fid="'+escapeHTML(x.file_id)+'" title="'+vt('Xem file .conf','View .conf')+'" aria-label="'+vt('Xem file .conf','View .conf')+'"><svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg></button></div>').join('')||'<small>'+vt('Chưa có site Nginx nào.','No Nginx sites found.')+'</small>';
    }catch(err){srcList.textContent=err.message;}
  }
  srcList.onclick=async e=>{
    const btn=e.target.closest('.copy-preview-btn');if(!btn)return;
    const pre=$('#copy-conf-preview');pre.hidden=false;pre.textContent=vt('Đang đọc file .conf…','Loading .conf…');
    try{
      const d=await api('vps/machines/'+encodeURIComponent(srcSel.value)+'/nginx/'+encodeURIComponent(btn.dataset.fid)+'/detail');
      if(pre.isConnected)pre.textContent=d.source||vt('(Trống)','(Empty)');
    }catch(err){if(pre.isConnected)pre.textContent='✗ '+err.message;}
  };
  srcSel.onchange=()=>{$('#copy-conf-preview').hidden=true;loadSrc();};
  loadSrc();
}

function setupSshKeyDropzone(root){
  if(!root)return;
  for(const inp of root.querySelectorAll('input[name="identity"],input[name$="_identity"]')){
    if(inp.dataset.sshDropReady)continue;
    inp.dataset.sshDropReady='1';
    const wrap=document.createElement('span');wrap.className='ssh-key-drop';
    inp.parentNode.insertBefore(wrap,inp);wrap.append(inp);
    const btn=document.createElement('button');btn.type='button';btn.className='button small ssh-key-import';btn.textContent=vt('Nhập file','Import');
    const picker=document.createElement('input');picker.type='file';picker.hidden=true;document.body.append(picker);
    const status=document.createElement('small');status.className='ssh-key-hint';
    wrap.append(btn);
    const field=inp.closest('label,.field');
    if(field){const existing=field.querySelector('small');if(existing)existing.after(status);else field.append(status);}
    const importText=async(filename,content)=>{
      if(previewMode){status.textContent=vt('Chế độ minh họa không lưu key thật.','Demo mode does not store real keys.');return;}
      status.textContent=vt('Đang nhập SSH key…','Importing SSH key…');status.classList.remove('is-error');
      try{
        const res=await api('vps/ssh-keys/import',{filename:filename||'id_key',content});
        inp.value=res.path;inp.dispatchEvent(new Event('input',{bubbles:true}));
        const isPub=/^(ssh-|ecdsa-sha2-|sk-ssh-|-----BEGIN PUBLIC KEY)/.test(content.trim());
        status.textContent=vt('Đã nhập: ','Imported: ')+res.name+(isPub?vt(' (Lưu ý: đây là public key, SSH thường cần private key)',' (Note: this is a public key; SSH usually needs the private key)'):' (0600)');
      }catch(err){status.textContent=err.message;status.classList.add('is-error');}
    };
    const handleFile=async file=>{
      if(!file)return;
      if(file.size>65536){status.textContent=vt('File quá lớn (tối đa 64 KB).','File too large (max 64 KB).');status.classList.add('is-error');return;}
      await importText(file.name,await file.text());
    };
    btn.onclick=e=>{e.preventDefault();e.stopPropagation();picker.click();};
    picker.onchange=()=>{if(picker.files[0])handleFile(picker.files[0]);picker.value='';};
    root.closest('dialog')?.addEventListener('close',()=>picker.remove(),{once:true});
    const target=field||wrap;
    for(const ev of ['dragenter','dragover']){target.addEventListener(ev,e=>{e.preventDefault();e.stopPropagation();wrap.classList.add('is-dragover');});}
    target.addEventListener('dragleave',e=>{if(!target.contains(e.relatedTarget))wrap.classList.remove('is-dragover');});
    target.addEventListener('drop',e=>{e.preventDefault();e.stopPropagation();wrap.classList.remove('is-dragover');const f=e.dataTransfer?.files?.[0];if(f)handleFile(f);});
    inp.addEventListener('paste',e=>{const txt=e.clipboardData?.getData('text')||'';if(txt.includes('PRIVATE KEY')){e.preventDefault();importText('pasted_key',txt);}});
  }
}

function openVpsUsersModal(){
  location.hash='users';
}

async function settingsPageVps(view,rev){
  let info={backend:'sqlite',database:'zm_manager',sqlite_count:0,mongo_count:null,uri_masked:''};
  let hostInfo=null;
  const hasHost=Boolean($('#hosts')?.value);
  try{if(!previewMode)info=await api('storage/config');}catch{}
  if(hasHost){
    try{hostInfo=await api(endpoint());}catch{}
  }
  if(rev!==revision)return;
  const usersBtn=currentAuth?.can_manage_users?'<button type="button" class="button small" data-tone="info" id="vps-manage-users">'+vt('Quản lý người dùng →','Manage users →')+'</button>':'';
  const hostName=hostInfo?.host||$('#hosts')?.selectedOptions?.[0]?.textContent||'';
  const hostMeta=hostInfo?[hostInfo.os,hostInfo.arch,hostInfo.manager].filter(Boolean).join(' · '):vt('Máy chủ đang chọn','Selected server');
  const vpsPanel=hasHost?('<article class="vps-box" id="settings-vps-box" style="margin-bottom:12px"><header class="vps-machine"><div><h2>'+escapeHTML(hostName)+'</h2><p>'+escapeHTML(hostMeta)+'</p></div><button type="button" class="button small" data-tone="configure" id="settings-account">'+vt('Tài khoản & SSH','Account & SSH')+'</button></header><form class="hostname-form"><label>'+vt('Hostname mới','New hostname')+'<input name="hostname" required maxlength="63" placeholder="web-01" autocomplete="off" autocapitalize="none" spellcheck="false"></label><button type="submit" class="button small" data-tone="configure">'+vt('Đổi hostname','Change hostname')+'</button><output class="hostname-status" aria-live="polite"></output></form></article>'):'';
  view.innerHTML=vpsPanel
    +'<section class="panel"><div class="panel-head"><div><h2>'+vt('Lưu trữ dữ liệu ứng dụng (SQLite / MongoDB)','App Data Storage (SQLite / MongoDB)')+'</h2><p>'+vt('Chọn lưu toàn bộ danh sách VPS, tác vụ, tài khoản OCI vào SQLite cục bộ hoặc một database MongoDB riêng biệt.','Choose to store VPS records, jobs and OCI accounts in local SQLite or a dedicated MongoDB database.')+'</p></div><div class="actions"><button type="button" class="button small" data-tone="create" id="vps-open-storage">'+vt('Cấu hình lưu trữ','Configure storage')+'</button></div></div>'
    +'<div class="panel-body"><div class="key-value"><span>'+vt('Chế độ đang dùng','Active backend')+'</span><strong>'+(info.backend==='mongodb'?'MongoDB ('+escapeHTML(info.database)+')':'SQLite (manager.sqlite3)')+'</strong></div>'
    +'<div class="key-value"><span>'+vt('Số bản ghi SQLite','SQLite records')+'</span><strong>'+info.sqlite_count+'</strong></div>'
    +(info.mongo_count!=null?'<div class="key-value"><span>'+vt('Số bản ghi MongoDB','MongoDB records')+'</span><strong>'+info.mongo_count+'</strong></div>':'')
    +(info.uri_masked?'<div class="key-value"><span>MongoDB URI</span><strong class="mono">'+escapeHTML(info.uri_masked)+'</strong></div>':'')
    +'</div></section>'
    +'<section class="panel"><div class="panel-head"><div><h2>'+vt('Tài khoản & Phân quyền','Account & Roles')+'</h2><p>'+vt('Tài khoản đăng nhập giao diện web ZM VPS Manager & MongoDB Manager.','Web login account for ZM VPS Manager & MongoDB Manager.')+'</p></div><div class="actions">'+usersBtn+'<button type="button" class="button small" data-tone="configure" id="vps-edit-admin">'+vt('Tài khoản của tôi','My account')+'</button></div></div></section>';
  if(hasHost){
    const vpsBox=$('#settings-vps-box');
    if(vpsBox)hostnameControls(vpsBox,endpoint());
    if($('#settings-account'))$('#settings-account').onclick=()=>accountDialog();
  }
  $('#vps-open-storage').onclick=()=>window.zmStorageModal({csrfToken:csrf,en:vpsEnglish,openModal:modal,closeModal:()=>$('dialog').close(),onSwitched:()=>location.reload()}).catch(err=>modal('Storage',escapeHTML(err.message),async()=>{}));
  $('#vps-edit-admin').onclick=()=>managerLogin(true);
  if($('#vps-manage-users'))$('#vps-manage-users').onclick=()=>{location.hash='users';};
}
