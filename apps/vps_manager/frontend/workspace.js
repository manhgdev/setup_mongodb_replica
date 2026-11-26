const vt=(vi,en)=>vpsEnglish?en:vi;

async function accountDialog(){
  const path=endpoint(), rev=revision, btn=$('#account')||$('#settings-account'), orig=btn?.textContent;
  if(btn){btn.disabled=true;btn.textContent=vt('Đang tải…','Loading…');}
  let state;
  try{state=await api(path+'/account');}
  finally{if(btn){btn.disabled=false;if(orig)btn.textContent=orig;}}
  if(rev!==revision)return;
  const target=state.user+'@'+state.host+':'+state.port;
  const canChange=state.sudo&&state.user!=='root'&&state.auth==='key';
  const fields='<p><strong>'+escapeHTML(target)+'</strong> · '+escapeHTML(state.auth)+'</p><p>sudo -n · '+(state.sudo?'✓':'—')+'　 SSH PasswordAuthentication · '+escapeHTML(state.password||'—')+'</p>';
  if(!canChange){modal('Tài khoản & SSH',fields+'<p>Chọn user thường dùng SSH key và có quyền sudo -n để đặt mật khẩu.</p>',async()=>{});return;}
  modal('Tài khoản & SSH',fields+'<div class="form-grid"><label class="field">Mật khẩu Linux mới<input name="password" type="password" autocomplete="new-password" required></label><label class="field">Nhập lại mật khẩu<input name="repeat" type="password" autocomplete="new-password" required></label></div><p><label><input id="show-secret" type="checkbox"> Hiện mật khẩu</label></p><p><label><input name="enable" type="checkbox"> Cho phép user này đăng nhập SSH bằng mật khẩu</label></p><p><label><input name="set_root" type="checkbox"> '+vt('Đặt mật khẩu này cho cả root (và cho phép SSH root nếu bật ở trên)','Also set this password for root (and allow root SSH if enabled above)')+'</label></p>',async form=>{
    if(form.get('password')!==form.get('repeat'))throw new Error('Hai mật khẩu chưa khớp.');
    await submit('password',{password:form.get('password'),enable:form.has('enable'),set_root:form.has('set_root')});
  });
  $('#show-secret').onchange=e=>{for(const input of $('#popup').querySelectorAll('[autocomplete=new-password]'))input.type=e.target.checked?'text':'password';};
}

const hostnameChanges=new Map();
function hostnameControls(view,path){
  const form=view.querySelector('.hostname-form'), input=form.elements.hostname;
  const status=view.querySelector('.hostname-status'), button=form.querySelector('button');
  const current=view.querySelector('.vps-machine h2');
  function sync(){
    const result=hostnameChanges.get(path);
    if(result?.name)current.textContent=result.name;
    status.textContent=result?.message||'';
    button.disabled=input.disabled=Boolean(result?.running);
  }
  sync();
  form.onsubmit=e=>{
    e.preventDefault();
    const name=input.value.trim().toLowerCase(),expected=current.textContent;
    if(!name||name.length>63||/^[0-9.]+$/.test(name)||name.split('.')[0]==='localhost'||name.endsWith('.localhost')||
       !name.split('.').every(part=>/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(part))){
      input.setCustomValidity(vt('Nhập hostname hợp lệ, dùng chữ, số và dấu gạch ngang.','Enter a valid hostname using letters, numbers and hyphens.'));
      input.reportValidity();return;
    }
    input.value=name;
    modal(vt('Xác nhận đổi hostname','Confirm hostname change'),
      '<p>'+escapeHTML($('#hosts').selectedOptions[0].textContent)+'</p><strong>'+escapeHTML(expected)+' → '+escapeHTML(name)+'</strong><p>'+vt('Cập nhật tên hệ thống, /etc/hosts và cấu hình cloud-init.','Update the system hostname, /etc/hosts and cloud-init configuration.')+'</p>',
      async()=>{
        const job=await api(path+'/hostname',{hostname:name,expected,confirmed:true});
        hostnameChanges.set(path,{running:true,message:vt('Đang đổi hostname…','Changing hostname…')});sync();
        async function follow(){
          let result;
          try{
            while(true){
              result=await api('vps/jobs/'+encodeURIComponent(job.id));
              if(!['queued','running'].includes(result.status))break;
              await new Promise(resolve=>setTimeout(resolve,700));
            }
            if(result.status!=='succeeded')throw new Error(result.error||result.status);
            hostnameChanges.set(path,{name:result.result.hostname,message:vt('Đã đổi hostname thành ','Hostname changed to ')+result.result.hostname});vpsGetCache.clear();loadHosts($('#hosts').value);
          }catch(error){hostnameChanges.set(path,{message:error.message+' · '+vt('Xem lịch sử tác vụ.','See job history.')});}
          if(form.isConnected){input.value='';sync();}
          else if(endpoint()===path&&(location.hash==='#overview'||location.hash==='#settings'))render();
        }
        follow();
      });
  };
  input.oninput=()=>input.setCustomValidity('');
}

function overviewPage(view,info,path){
  const gib=n=>(n/2**30).toFixed(1)+' GiB';
  const resource=(label,value,caption,ratio)=>`<section><small>${label}</small><strong>${escapeHTML(value)}</strong>
    ${Number.isFinite(ratio)?'<progress max="1" value="'+Math.max(0,Math.min(1,ratio))+'" aria-label="'+label+'"></progress>':''}
    <span>${escapeHTML(caption)}</span></section>`;
  const renderMeters=m=>{
    const memory=m.memory_total, available=m.memory_available, loads=m.load_average;
    return [
      resource(vt('Tải CPU · 1 phút','CPU load · 1 min'),loads?loads[0].toFixed(2):'—',m.cpu+' vCPU'+(loads?' · 5 min '+loads[1].toFixed(2)+' / 15 min '+loads[2].toFixed(2):''),loads?.[0]/m.cpu),
      resource(vt('RAM đang dùng','Memory used'),Number.isFinite(available)?gib(memory-available):'—',memory?vt('Tổng ','Total ')+gib(memory):m.memory,Number.isFinite(available)?1-available/memory:NaN),
      resource(vt('Dung lượng đã dùng · /','Disk used · /'),m.disk_total?gib(m.disk_used):'—',vt('Còn trống ','Free ')+gib(m.disk_free),m.disk_used/m.disk_total)
    ].join('');
  };
  const renderUptime=m=>{
    const uptime=m.uptime_seconds;
    return (m.kernel?'Kernel '+escapeHTML(m.kernel):'')+(Number.isFinite(uptime)?'<span>'+vt('Đã chạy ','Uptime ')+(uptime<3600?Math.floor(uptime/60)+vt(' phút',' min'):Math.floor(uptime/86400)+vt(' ngày ',' days ')+Math.floor(uptime/3600)%24+vt(' giờ',' hours'))+'</span>':'');
  };
  const panel=(id,title,route,action,extra='')=>`<section class="vps-box overview-panel"><header><div style="display:flex;align-items:center;gap:10px"><h2>${title}</h2>${extra}</div><a href="#${route}">${action} →</a></header><div id="${id}"></div></section>`;
  const quickSummary=[
    ['software',vt('Software Center','Software Center'),vt('Gói hệ điều hành & bộ cài','System packages & kits')],
    ['docker',vt('Docker & Compose','Docker & Compose'),info.docker?('Docker · '+info.docker):vt('Container & Compose YAML','Containers & Compose YAML')],
    ['firewall',vt('Firewall','Firewall'),vt('UFW & Oracle Cloud Security','UFW & Oracle Cloud Security')],
    ['sysadmin',vt('User & Ổ đĩa','Users & Disks'),vt('Tài khoản Linux, mount & phân quyền','Linux users, mounts & permissions')],
    ['git',vt('Git & SSH Key','Git & SSH Keys'),vt('Deploy key & đồng bộ repo','Deploy keys & repo sync')],
    ['servers',vt('Máy chủ & Cài đặt','Servers & Settings'),vt('Danh sách VPS, lưu trữ & phân quyền','VPS inventory, storage & roles')],
  ].map(([hash,title,sub])=>`<a href="#${hash}" style="display:flex;flex-direction:column;gap:4px;padding:10px 12px;border:1px solid var(--line,#e2e8f0);border-radius:8px;background:#fafcfa;text-decoration:none;color:inherit"><span style="display:flex;justify-content:space-between;align-items:center;gap:8px;font-weight:600;color:var(--green,#2f6e49)"><span>${title}</span><span>→</span></span><span style="font-size:12px;color:#576e60">${escapeHTML(sub)}</span></a>`).join('');
  view.innerHTML=`<article class="vps-box"><header class="vps-machine"><div><h2>${escapeHTML(info.host)}</h2><p>${escapeHTML([info.os,info.arch,info.manager].filter(Boolean).join(' · '))}</p></div><button class="button small" data-tone="configure" id="account">${vt('Tài khoản & SSH','Account & SSH')}</button></header>
    <form class="hostname-form"><label>${vt('Hostname mới','New hostname')}<input name="hostname" required maxlength="63" placeholder="web-01" autocomplete="off" autocapitalize="none" spellcheck="false"></label><button type="submit" class="button small" data-tone="configure">${vt('Đổi hostname','Change hostname')}</button><output class="hostname-status" aria-live="polite"></output></form>
    <div class="overview-meters" id="ov-meters">${renderMeters(info)}</div><div class="overview-system" id="ov-system">${renderUptime(info)}</div></article>
    <div class="overview-panels">${panel('ov-processes',vt('Tác vụ đang chạy · CPU & RAM','Running processes · CPU & RAM'),'terminal','SSH Terminal','<span class="ov-live"><i></i>Live · 3s</span>')}
    ${panel('ov-sites',vt('Website & chứng chỉ','Websites & certificates'),'domains','Nginx')}
    <section class="vps-box overview-panel"><header><h2>${vt('Lưu trữ dữ liệu ứng dụng (SQLite / MongoDB)','App Data Storage (SQLite / MongoDB)')}</h2><a href="#settings" id="ov-storage-cfg">${vt('Cấu hình','Configure')} →</a></header><div id="ov-storage"></div></section>
    <section class="vps-box overview-panel" style="grid-column:1/-1"><header><h2>${vt('Công cụ & dịch vụ trên VPS','VPS tools & services')}</h2><a href="#software">${vt('Mở Software Center','Open Software Center')} →</a></header><div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:10px;padding:12px 16px">${quickSummary}</div></section></div>`;
  if(!hostnameChanges.get(path)?.running && hostnameChanges.get(path)?.name!==info.host)hostnameChanges.delete(path);
  hostnameControls(view,path);
  const row=(title,value,job)=>`<${job?'button type="button" data-job="'+escapeHTML(job)+'"':'div'} class="overview-row"><strong>${escapeHTML(title)}</strong><span>${escapeHTML(value)}</span></${job?'button':'div'}>`;
  const renderProcs=list=>{
    if(!list.length)return escapeHTML(vt('Không có dữ liệu tiến trình.','No process data available.'));
    const rows=list.slice(0,5).map((p,idx)=>{
      const cpu=Number(p.cpu||0),mem=Number(p.mem||0),mib=Math.round((p.rss||0)/1048576);
      const tone=cpu>=50?' high':cpu>=15?' warn':'';
      const cmd=p.cmd||p.name||'';
      return `<tr><td class="proc-td-rank">${idx+1}</td><td class="proc-td-num">${escapeHTML(String(p.pid))}</td><td class="proc-td-user">${escapeHTML(p.user||'—')}</td><td class="proc-td-cpu${tone}">${cpu.toFixed(1)}%</td><td class="proc-td-num">${mem.toFixed(1)}%</td><td class="proc-td-num">${mib}M</td><td class="proc-td-num">${escapeHTML(p.time||'—')}</td><td class="proc-td-cmd" title="${escapeHTML(cmd)}">${escapeHTML(cmd)}</td></tr>`;
    }).join('');
    return `<div class="proc-table-wrap"><table class="proc-table"><thead><tr><th>#</th><th>PID</th><th>USER</th><th>CPU%</th><th>MEM%</th><th>RES</th><th>TIME+</th><th>Command</th></tr></thead><tbody>${rows}</tbody></table></div>`;
  };
  const applyMetrics=m=>{
    const meters=$('#ov-meters'),sys=$('#ov-system'),procsEl=$('#ov-processes');
    if(meters)meters.innerHTML=renderMeters({...info,...m});
    if(sys)sys.innerHTML=renderUptime({...info,...m});
    if(procsEl&&m.top_processes)procsEl.innerHTML=renderProcs(m.top_processes);
  };
  if(info.top_processes===undefined){
    populate($('#ov-processes'),path+'/metrics',fresh=>renderProcs(fresh.top_processes||[]));
  }else{
    $('#ov-processes').innerHTML=renderProcs(info.top_processes);
  }
  let polling=false;
  const timer=setInterval(async()=>{
    if(!view.isConnected||endpoint()!==path||(location.hash&&location.hash!=='#overview')){clearInterval(timer);return;}
    if(document.hidden||polling)return;
    polling=true;
    try{
      const m=await api(path+'/metrics');
      if(view.isConnected&&endpoint()===path)applyMetrics(m);
    }catch{}
    finally{polling=false;}
  },3000);
  async function populate(el,url,format){
    el.textContent=vt('Đang kiểm tra…','Checking…');
    try{const data=await api(url);if(el.isConnected)el.innerHTML=format(data);}
    catch(err){if(el.isConnected)el.textContent=err.message;}
  }
  const storageEl=$('#ov-storage');
  const renderStorage=s=>{
    const active=s.backend==='mongodb'?'MongoDB ('+s.database+')':'SQLite (manager.sqlite3)';
    return row(vt('Chế độ đang dùng','Active backend'),active)
      +row(vt('Số bản ghi SQLite','SQLite records'),String(s.sqlite_count??0))
      +(s.mongo_count!=null?row(vt('Số bản ghi MongoDB','MongoDB records'),String(s.mongo_count)):'')
      +(s.uri_masked?row('MongoDB URI',s.uri_masked):'');
  };
  if(previewMode){
    storageEl.innerHTML=renderStorage({backend:'sqlite',database:'zm_manager',sqlite_count:12,mongo_count:null,uri_masked:''});
  }else{
    populate(storageEl,'storage/config',renderStorage);
  }
  const cfgLink=$('#ov-storage-cfg');
  if(cfgLink && !previewMode && window.zmStorageModal){
    cfgLink.onclick=e=>{e.preventDefault();window.zmStorageModal({csrfToken:csrf,en:vpsEnglish,openModal:modal,closeModal:()=>$('dialog').close(),onSwitched:()=>location.reload()}).catch(err=>modal('Storage',escapeHTML(err.message),async()=>{}));};
  }
  const sites=$('#ov-sites');
  if(info.nginx!=='active'){sites.textContent='Nginx · '+(info.nginx||'—');return;}
  populate(sites,path+'/nginx',inventory=>{
    const items=[...inventory.sites].sort((a,b)=>(a.expires??Infinity)-(b.expires??Infinity));
    return (inventory.diagnostics||[]).map(m=>'<p class="overview-warning">'+escapeHTML(m)+'</p>').join('')+
      (items.slice(0,5).map(s=>row(s.domain==='_'?vt('Website mặc định','Default website'):s.domain,!s.enabled?vt('Đã tắt','Disabled'):!s.https?'HTTP':s.expires==null?'HTTPS · —':(certificateWarning(s.expires)||('HTTPS · '+s.expires+vt(' ngày',' days'))))).join('')||vt('Chưa tìm thấy website.','No websites found.'));
  });
}

function jobsPage(view,jobs,id){
  const labels={queued:vt('Đang chờ','Queued'),running:vt('Đang chạy','Running'),succeeded:vt('Hoàn tất','Completed'),failed:vt('Có lỗi','Failed'),interrupted:vt('Gián đoạn','Interrupted')};
  const badgeCls={queued:'warn',running:'blue',succeeded:'success',failed:'error',interrupted:'error'};
  const fmtDate=s=>s?new Date(s).toLocaleString(vpsEnglish?'en-GB':'vi-VN',{day:'2-digit',month:'2-digit',hour:'2-digit',minute:'2-digit'}):'—';
  const refBtn=document.createElement('button');refBtn.type='button';refBtn.className='button';refBtn.dataset.tone='info';refBtn.textContent=vt('Làm mới','Refresh');refBtn.onclick=()=>render();
  if(!$('#heading-actions').querySelector('.jobs-refresh')){refBtn.classList.add('jobs-refresh');$('#heading-actions').append(refBtn);}
  const openDetail=job=>{
    const logs=(job.events||[]).map(e=>e.message).filter(Boolean).join('\n')||'…';
    const errHtml=job.error?'<div class="callout error" style="margin-top:10px">'+escapeHTML(job.error)+'</div>':'';
    const resHtml=job.result?'<pre style="margin-top:10px;max-height:220px;overflow:auto">'+escapeHTML(JSON.stringify(job.result,null,2))+'</pre>':'';
    modal(escapeHTML(job.label)+' · '+(labels[job.status]||job.status),
      '<p><strong>'+escapeHTML(job.target||'')+'</strong> · '+escapeHTML(fmtDate(job.created_at))+'</p>'
      +'<pre style="max-height:280px;overflow:auto">'+escapeHTML(logs)+'</pre>'+errHtml+resHtml,
      async()=>{});
  };
  if(!jobs.length){
    view.innerHTML='<section class="panel"><div class="panel-head"><div><h2>'+vt('Tác vụ','Jobs')+'</h2></div></div><div class="panel-body"><p style="color:var(--muted);margin:0">'+vt('Chưa có tác vụ nào cho máy này.','No jobs recorded for this server.')+'</p></div></section>';
    return;
  }
  const rows=jobs.map(j=>'<tr class="job-row" data-id="'+escapeHTML(j.id)+'" style="cursor:pointer"><td><strong>'+escapeHTML(j.label)+'</strong></td><td>'+escapeHTML(j.target||'—')+'</td><td>'+escapeHTML(fmtDate(j.created_at))+'</td><td><span class="badge '+(badgeCls[j.status]||'')+'">'+escapeHTML(labels[j.status]||j.status)+'</span></td><td><button type="button" class="button small job-open-btn" data-tone="info" data-id="'+escapeHTML(j.id)+'">'+vt('Chi tiết','Details')+'</button></td></tr>').join('');
  view.innerHTML='<section class="panel"><div class="panel-head"><div><h2>'+vt('Tác vụ','Jobs')+'</h2></div></div><div class="table-wrap"><table><thead><tr><th>'+vt('TÁC VỤ','JOB')+'</th><th>'+vt('ĐÍCH','TARGET')+'</th><th>'+vt('THỜI GIAN','TIME')+'</th><th>'+vt('TRẠNG THÁI','STATUS')+'</th><th></th></tr></thead><tbody>'+rows+'</tbody></table></div></section>';
  for(const row of view.querySelectorAll('.job-row')){
    row.onclick=()=>{const j=jobs.find(x=>x.id===row.dataset.id);if(j)openDetail(j);};
  }
  if(id){const reqJob=jobs.find(x=>x.id===id);if(reqJob){selectedJob='';sessionStorage.removeItem('vps-selected-job');openDetail(reqJob);}}
}
