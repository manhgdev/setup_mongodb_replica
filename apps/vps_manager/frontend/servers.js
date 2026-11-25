// "Máy chủ": list and manage saved SSH machines (shared records with MongoDB Manager).
async function serversPage(view,path,rev){
  const list=(await api('vps/servers')).sort((a,b)=>Number(Boolean(a.profile_id))-Number(Boolean(b.profile_id)));
  if(rev!==revision)return;
  const add=document.createElement('button');add.type='button';add.className='button';add.dataset.tone='create';add.textContent='+ '+vt('Thêm máy chủ','Add server');add.onclick=()=>addVps();
  const bulkAdd=document.createElement('button');bulkAdd.type='button';bulkAdd.className='button';bulkAdd.dataset.tone='info';bulkAdd.textContent='+ '+vt('Thêm từ Seed list','Add from Seed list');bulkAdd.onclick=()=>addFromSeeds();
  const copyIps=document.createElement('button');copyIps.type='button';copyIps.className='button';copyIps.dataset.tone='configure';copyIps.textContent=vt('Copy IP VPS','Copy VPS IPs');
  copyIps.onclick=async()=>{
    const ips=[...new Set(list.filter(m=>m.mode==='ssh'&&m.host).map(m=>m.host))];
    if(!ips.length)return;
    await navigator.clipboard?.writeText(ips.join('\n'));
    copyIps.textContent='✓ '+vt('Đã copy '+ips.length+' IP','Copied '+ips.length+' IPs');
    setTimeout(()=>{copyIps.textContent=vt('Copy IP VPS','Copy VPS IPs');},2500);
  };
  const bulkCheck=document.createElement('button');bulkCheck.type='button';bulkCheck.className='button';bulkCheck.dataset.tone='create';bulkCheck.hidden=true;
  const bulkDel=document.createElement('button');bulkDel.type='button';bulkDel.className='button';bulkDel.dataset.tone='remove';bulkDel.hidden=true;
  $('#heading-actions').append(bulkCheck,bulkDel,copyIps,bulkAdd,add);
  view.innerHTML='<section class="panel"><div class="panel-head"><div><h2>'+vt('Danh sách máy chủ','Servers')+'</h2></div><input class="search-box" type="search" id="find-server" placeholder="'+vt('Tìm máy chủ, IP…','Find server, IP…')+'"></div><div class="table-wrap"><table><thead><tr><th><input type="checkbox" id="select-all-servers" aria-label="Chọn tất cả"></th><th>#</th><th>'+vt('MÁY CHỦ','SERVER')+'</th><th>'+vt('KẾT NỐI','CONNECTION')+'</th><th>'+vt('XÁC THỰC','AUTH')+'</th><th></th></tr></thead><tbody></tbody></table></div></section>';
  const body=view.querySelector('tbody');
  if(!list.length)body.innerHTML='<tr><td colspan="6">'+vt('Chưa có máy chủ.','No servers yet.')+'</td></tr>';
  for(const m of list){
    const tr=document.createElement('tr');
    const icon='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true"><path d="M4 4h16v6H4z M4 14h16v6H4z M7 7h.01 M7 17h.01"/></svg>';
    const badge=(t,c)=>'<span class="badge '+c+'">'+t+'</span>';
    tr.innerHTML='<td><input type="checkbox" class="srv-pick" value="'+escapeHTML(m.id)+'"></td><td class="row-number">'+(list.indexOf(m)+1)+'</td><td><div class="host-cell"><span class="server-icon">'+icon+'</span><div><strong>'+escapeHTML(m.name)+'</strong>'+(m.mongo_endpoint?'<small class="mongo-address">'+escapeHTML(m.mongo_endpoint)+'</small>':'')+(m.profile_id?'<small>'+vt('Thuộc cụm MongoDB','In a MongoDB cluster')+'</small>':'')+'</div></div></td><td>'+badge(m.mode==='ssh'?'SSH':'LOCAL','dark')+' '+(m.mode==='ssh'?'<span class="mono ssh-address">'+escapeHTML(m.user+'@'+(m.host.includes(':')?'['+m.host+']':m.host)+':'+m.port)+'</span>':'')+'</td><td>'+(m.mode==='local'?'—':m.ssh_auth==='password'?vt('Mật khẩu SSH','SSH password')+(m.has_ssh_password?' ✓':''):'SSH key / Agent')+'</td><td><div class="actions"></div></td>';
    const act=tr.querySelector('.actions');
    const mk=(text,tone,fn)=>{const b=document.createElement('button');b.type='button';b.className='button small';b.dataset.tone=tone;b.textContent=text;b.onclick=fn;act.append(b);};
    mk(vt('Tổng quan','Overview'),'info',()=>{$('#hosts').value=m.id;localStorage.setItem('vps-selected-machine',m.id);location.hash='overview';});
    mk('Nginx','configure',()=>{$('#hosts').value=m.id;localStorage.setItem('vps-selected-machine',m.id);location.hash='domains';});
    mk('Firewall','warning',()=>{$('#hosts').value=m.id;localStorage.setItem('vps-selected-machine',m.id);location.hash='firewall';});
    mk(vt('Kiểm tra','Check'),'create',async()=>{
      modal(vt('Kiểm tra VPS · ','Check VPS · ')+escapeHTML(m.name),'<div id="srv-chk"><span class="spinner"></span> '+vt('Đang kiểm tra kết nối & tài nguyên…','Checking connection & resources…')+'</div>',async()=>{});
      try{
        const info=await api('vps/machines/'+encodeURIComponent(m.id)+'?refresh=true');
        const box=$('#srv-chk');if(!box?.isConnected)return;
        const gb=n=>n?(n/1073741824).toFixed(1)+' GB':'—';
        box.innerHTML='<div class="callout" style="margin:0"><strong>'+escapeHTML(info.host)+'</strong> · '+escapeHTML(info.os)+' ('+escapeHTML(info.arch)+')<br>'
          +'CPU: '+escapeHTML(info.cpu)+' · RAM: '+gb(info.memory_available)+' / '+gb(info.memory_total)+' · Disk trống: '+gb(info.disk_free)+'<br>'
          +'Nginx: '+escapeHTML(info.nginx||'—')+' · Load: '+escapeHTML((info.load_average||[]).join(', '))+'</div>';
      }catch(err){const box=$('#srv-chk');if(box?.isConnected)box.innerHTML='<div class="callout error" style="margin:0">✗ '+escapeHTML(err.message)+'</div>';}
    });
    mk(vt('Sửa','Edit'),'configure',()=>addVps(m));
    if(!m.profile_id)mk(vt('Xóa','Delete'),'remove',()=>modal(vt('Xóa hồ sơ máy chủ','Delete server record'),'<p>'+escapeHTML(m.name)+' · '+escapeHTML(vt('Hồ sơ chỉ bị xóa khỏi Manager. Dữ liệu và dịch vụ trên VPS giữ nguyên.','Only the Manager record is removed. Data and services on the VPS stay untouched.'))+'</p>',async()=>{await api('vps/servers/'+encodeURIComponent(m.id),undefined,'DELETE');setTimeout(()=>loadHosts(),0);}));
    body.append(tr);
  }
  const pickAll=$('#select-all-servers');
  function picked(){return [...body.querySelectorAll('.srv-pick:checked')].map(c=>list.find(m=>m.id===c.value)).filter(Boolean);}
  function syncBulk(){
    const n=picked().length;
    bulkCheck.hidden=bulkDel.hidden=!n;
    bulkCheck.textContent=vt('Kiểm tra ('+n+')','Check ('+n+')');
    bulkDel.textContent=vt('Xóa ('+n+')','Delete ('+n+')');
  }
  if(pickAll)pickAll.onchange=()=>{body.querySelectorAll('.srv-pick').forEach(c=>{if(!c.closest('tr').hidden)c.checked=pickAll.checked;});syncBulk();};
  body.addEventListener('change',e=>{if(e.target.classList.contains('srv-pick'))syncBulk();});
  bulkCheck.onclick=async()=>{
    const items=picked();if(!items.length)return;
    modal(vt('Kiểm tra '+items.length+' máy chủ','Check '+items.length+' servers'),'<div id="bulk-srv-chk"><span class="spinner"></span> '+vt('Đang kiểm tra song song…','Checking in parallel…')+'</div>',async()=>{});
    const rows=await Promise.all(items.map(async m=>{
      try{
        const info=await api('vps/machines/'+encodeURIComponent(m.id)+'?refresh=true');
        const gb=n=>n?(n/1073741824).toFixed(1)+' GB':'—';
        return '<li><strong>'+escapeHTML(m.name)+'</strong> · '+escapeHTML(info.host)+' · '+escapeHTML(info.os)+' · RAM '+gb(info.memory_available)+'/'+gb(info.memory_total)+' · Disk '+gb(info.disk_free)+'</li>';
      }catch(err){return '<li><strong>'+escapeHTML(m.name)+'</strong> · <span style="color:var(--red)">✗ '+escapeHTML(err.message)+'</span></li>';}
    }));
    const box=$('#bulk-srv-chk');if(box?.isConnected)box.innerHTML='<ul style="margin:0;padding-left:18px;display:grid;gap:6px">'+rows.join('')+'</ul>';
  };
  bulkDel.onclick=()=>{
    const items=picked().filter(m=>!m.profile_id);
    if(!items.length){modal(vt('Xóa máy chủ','Delete servers'),'<p>'+vt('Các máy đã chọn đều thuộc cụm MongoDB. Hãy xóa trong MongoDB Manager.','Selected servers belong to a MongoDB cluster.')+'</p>',async()=>{});return;}
    modal(vt('Xóa '+items.length+' máy chủ','Delete '+items.length+' servers'),'<p>'+vt('Chỉ xóa hồ sơ khỏi Manager. Dữ liệu và dịch vụ trên VPS giữ nguyên.','Only Manager records are removed.')+'</p><ul>'+items.map(m=>'<li><strong>'+escapeHTML(m.name)+'</strong> ('+escapeHTML(m.host)+')</li>').join('')+'</ul>',async()=>{
      for(const m of items)await api('vps/servers/'+encodeURIComponent(m.id),undefined,'DELETE');
      await loadHosts();render();
    });
  };
  $('#find-server').oninput=e=>{
    const q=e.target.value.toLowerCase().trim();
    for(const tr of body.querySelectorAll('tr'))tr.hidden=!tr.textContent.toLowerCase().includes(q);
  };
}

function addFromSeeds(){
  modal(vt('Thêm nhiều máy chủ từ Seed list','Add servers from Seed list'),
    '<div class="form-grid">'
    +'<label class="field wide">'+vt('Seed list (mỗi dòng 1 IP hoặc IP:port)','Seed list (one IP or IP:port per line)')+'<textarea name="seeds" rows="5" required placeholder="171.244.21.247:27017\n160.191.87.38:27017"></textarea></label>'
    +'<label class="field">User SSH<input name="user" value="root" required></label>'
    +'<label class="field">Port SSH<input name="port" type="number" value="22" min="1" max="65535"></label>'
    +'<label class="field">'+vt('Xác thực SSH','SSH authentication')+'<select name="ssh_auth"><option value="password">'+vt('Mật khẩu SSH','SSH password')+'</option><option value="key">SSH key / Agent</option></select></label>'
    +'<label class="field">'+vt('Mật khẩu SSH','SSH password')+'<input name="ssh_password" type="password" autocomplete="new-password"></label>'
    +'<label class="field wide" hidden>'+vt('SSH private key (tùy chọn)','SSH private key (optional)')+'<input name="identity" placeholder="~/.ssh/id_ed25519"></label>'
    +'</div>',
    async form=>{
      const raw=Object.fromEntries(form);
      const lines=[...new Set(raw.seeds.split(/[\n,]+/).map(s=>s.trim()).filter(Boolean))];
      const existing=new Set((await api('vps/servers')).filter(m=>m.mode==='ssh').map(m=>m.host+':'+m.port));
      if(!lines.length)throw new Error(vt('Nhập ít nhất một seed.','Enter at least one seed.'));
      for(const line of lines){
        const m=line.match(/^\[?([^\]]+?)\](?::(\d+))?$/)||line.match(/^([^:]+)(?::(\d+))?$/);
        const host=m[1],sshPort=Number(raw.port||22),mongo_endpoint=line.includes(':')?line:(host+':27017');
        if(existing.has(host+':'+sshPort))continue;
        existing.add(host+':'+sshPort);
        const payload={mode:'ssh',host,port:Number(raw.port||22),user:raw.user.trim(),ssh_auth:raw.ssh_auth,ssh_password:raw.ssh_auth==='password'?raw.ssh_password:'',identity:raw.ssh_auth==='key'?raw.identity.trim():'',auto_name:true,name:host,mongo_endpoint,votes:1,priority:1};
        let test=await api('vps/connection-test',{...payload,expected:''});
        if(test.fingerprint)test=await api('vps/connection-test',{...payload,expected:test.fingerprint});
        payload.name=test.hostname||host;
        await api('vps/machines',payload);
      }
      await loadHosts();render();
    });
  const f=$('#popup'),auth=f.elements.ssh_auth;
  const sync=()=>{const pw=auth.value==='password';f.elements.ssh_password.closest('label').hidden=!pw;f.elements.ssh_password.disabled=!pw;f.elements.identity.closest('label').hidden=pw;f.elements.identity.disabled=pw;};
  auth.onchange=sync;sync();
}
