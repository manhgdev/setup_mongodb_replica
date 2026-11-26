// "Máy chủ": list and manage saved SSH machines (shared records with MongoDB Manager).
async function serversPage(view,path,rev){
  const byHost=(a,b)=>String(a.name||a.host||'').localeCompare(String(b.name||b.host||''),undefined,{numeric:true,sensitivity:'base'});
  const list=(await api('vps/servers')).sort((a,b)=>(Number(Boolean(a.profile_id))-Number(Boolean(b.profile_id)))||byHost(a,b));
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
    const ipLabel=m.host||(m.mongo_endpoint?m.mongo_endpoint.replace(/:\d+$/,''):'');
    tr.innerHTML='<td><input type="checkbox" class="srv-pick" value="'+escapeHTML(m.id)+'"></td><td class="row-number">'+(list.indexOf(m)+1)+'</td><td><div class="host-cell"><span class="server-icon">'+icon+'</span><div><strong>'+escapeHTML(m.name)+'</strong>'+(ipLabel?'<small class="mongo-address">'+escapeHTML(ipLabel)+'</small>':'')+(m.profile_id?'<small>'+vt('Thuộc cụm MongoDB','In a MongoDB cluster')+'</small>':'')+'</div></div></td><td>'+badge(m.mode==='ssh'?'SSH':'LOCAL','dark')+' '+(m.mode==='ssh'?'<span class="mono ssh-address">'+escapeHTML(m.user+'@'+(m.host.includes(':')?'['+m.host+']':m.host)+':'+m.port)+'</span>':'')+'</td><td>'+(m.mode==='local'?'—':m.ssh_auth==='password'?vt('Mật khẩu SSH','SSH password')+(m.has_ssh_password?' ✓':''):'SSH key / Agent')+'</td><td><div class="actions"></div></td>';
    const act=tr.querySelector('.actions');
    const mk=(text,tone,fn)=>{const b=document.createElement('button');b.type='button';b.className='button small';b.dataset.tone=tone;b.textContent=text;b.onclick=fn;act.append(b);};
    mk(vt('Tổng quan','Overview'),'info',()=>{$('#hosts').value=m.id;localStorage.setItem('vps-selected-machine',m.id);location.hash='overview';});
    mk('Terminal','create',()=>{$('#hosts').value=m.id;localStorage.setItem('vps-selected-machine',m.id);location.hash='terminal?machine='+encodeURIComponent(m.id);});
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
    +'</div>'
    +'<p><button type="button" class="button" id="seed-test-connection">'+vt('Kiểm tra kết nối','Test connection')+'</button></p><output id="seed-ssh-feedback"></output>',
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
  const f=$('#popup'),auth=f.elements.ssh_auth,testBtn=$('#seed-test-connection'),fb=$('#seed-ssh-feedback');
  const sync=()=>{const pw=auth.value==='password';f.elements.ssh_password.closest('label').hidden=!pw;f.elements.ssh_password.disabled=!pw;f.elements.identity.closest('label').hidden=pw;f.elements.identity.disabled=pw;};
  setupSshKeyDropzone(f);auth.onchange=sync;sync();
  testBtn.onclick=async()=>{
    const raw=Object.fromEntries(new FormData(f));
    const lines=[...new Set((raw.seeds||'').split(/[\n,]+/).map(s=>s.trim()).filter(Boolean))];
    if(!lines.length){fb.textContent=vt('Nhập ít nhất một seed.','Enter at least one seed.');return;}
    testBtn.disabled=true;fb.textContent=vt('Đang kiểm tra kết nối…','Testing connections…');
    const out=[];
    try{
      for(const line of lines){
        const m=line.match(/^\[?([^\]]+?)\](?::(\d+))?$/)||line.match(/^([^:]+)(?::(\d+))?$/);
        const host=m[1],port=Number(raw.port||22);
        const payload={mode:'ssh',host,port,user:(raw.user||'').trim(),ssh_auth:raw.ssh_auth,ssh_password:raw.ssh_auth==='password'?raw.ssh_password:'',identity:raw.ssh_auth==='key'?(raw.identity||'').trim():''};
        try{
          let res=await api('vps/connection-test',{...payload,expected:''});
          if(res.fingerprint)res=await api('vps/connection-test',{...payload,expected:res.fingerprint});
          out.push('✓ '+host+': '+(res.hostname||host)+' ('+res.user+' · sudo -n '+(res.sudo?'✓':'—')+')');
        }catch(err){out.push('✗ '+host+': '+err.message);}
        if(fb.isConnected)fb.innerHTML=out.map(escapeHTML).join('<br>');
      }
    }finally{testBtn.disabled=false;}
  };
}

function addVps(record=null){
  let verified=false,expected='',detected='',autoConnect;
  const field=(name,label,value='',type='text',hint='',extra='')=>'<label class="field"'+(extra.includes('wide')?' data-wide':'')+'>'+label+'<input name="'+name+'" type="'+type+'" value="'+escapeHTML(value)+'"'+(type==='number'?' min="0"':'')+(extra==='placeholder'?' placeholder="'+vt('Tự đọc hostname','Detect hostname')+'"':'')+' autocomplete="'+(type==='password'?'new-password':'off')+'">'+(hint?'<small>'+hint+'</small>':'')+'</label>';
  const select=(name,label,options,value)=>'<label class="field">'+label+'<select name="'+name+'">'+options.map(o=>'<option value="'+o[0]+'"'+(o[0]===String(value)?' selected':'')+'>'+o[1]+'</option>').join('')+'</select></label>';
  // Same fields and order as the MongoDB Manager server form; both write the shared machine record.
  modal(record?vt('Sửa máy chủ','Edit server'):vt('Thêm máy chủ','Add server'),'<div class="form-grid">'
    +field('name',vt('Tên máy','Server name'),'','text','','placeholder')
    +field('mongo_host',vt('Địa chỉ IP public','Public IP address'),'','text','')
    +field('mongo_port',vt('Cổng MongoDB','MongoDB port'),27017,'number')
    +select('votes','Votes',[['1','1'],['0','0']],1)
    +field('priority',vt('Ưu tiên bầu primary','Primary election priority'),1,'number',vt('Áp dụng khi thêm Secondary.','Used when adding a secondary.'))
    +select('mode',vt('Kiểu kết nối','Connection type'),[['ssh','ssh'],['local','local']],'ssh')
    +field('user','User SSH','root')+field('port','Port SSH',22,'number')
    +select('ssh_auth',vt('Xác thực SSH','SSH authentication'),[['password',vt('Mật khẩu SSH','SSH password')],['key','SSH key / Agent']],'password')
    +'<label class="field">'+vt('Mật khẩu SSH','SSH password')+'<span class="input-eye-wrap"><input name="ssh_password" type="password" autocomplete="new-password"><button type="button" id="show-ssh-pw" class="input-eye" aria-label="'+vt('Hiện mật khẩu','Show password')+'"><svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg></button></span></label>'
    +field('identity',vt('SSH private key (tùy chọn)','SSH private key (optional)'),'','text',vt('Để trống để dùng SSH agent hoặc ~/.ssh/config.','Leave empty to use the SSH agent or ~/.ssh/config.'))
    +'<details class="field wide"><summary>'+vt('Địa chỉ SSH riêng','Separate SSH address')+'</summary>'+field('host',vt('Địa chỉ SSH (nếu khác)','SSH address (if different)'),'','text',vt('Để trống để dùng địa chỉ IP public ở trên.','Leave empty to use the public address above.'))+'</details></div>'
    +'<p><button type="button" class="button" id="test-connection">'+vt('Kiểm tra kết nối','Test connection')+'</button></p><output id="ssh-feedback"></output>',async form=>{
    let data=payload(form);
    const moved=record&&(data.host!==record.host||data.port!==record.port||data.user!==record.user||data.mode!==record.mode);
    if(data.mode==='ssh'&&(!record||moved)){await autoConnect();data=payload(form);}
    const saved=await api(record?'vps/servers/'+encodeURIComponent(record.id):'vps/machines',data,record?'PUT':undefined);await loadHosts(saved.id);
    if(location.hash==='#servers')render();
  });
  const form=$('#popup'), fields=form.elements, test=$('#test-connection'), feedback=$('#ssh-feedback');
  function payload(source){
    const raw=source instanceof FormData?Object.fromEntries(source):Object.fromEntries(new FormData(form));
    const v=k=>(raw[k]||'').trim(),ssh=v('mode')==='ssh',address=v('mongo_host').replace(/^\[|\]$/g,'');
    const mongoPort=Number(v('mongo_port')||27017);
    const data={mode:v('mode'),name:v('name'),auto_name:!v('name'),votes:Number(raw.votes),priority:Number(raw.priority||0),port:Number(v('port')||22),user:v('user'),
      ssh_auth:v('ssh_auth'),ssh_password:ssh&&v('ssh_auth')==='password'?(raw.ssh_password||null):'',identity:ssh&&v('ssh_auth')==='key'?v('identity'):'',
      host:ssh?(v('host')||address):'127.0.0.1',mongo_endpoint:address?(address.includes(':')?'['+address+']':address)+':'+mongoPort:''};
    if(!data.votes&&data.priority)throw new Error(vt('Votes = 0 yêu cầu ưu tiên bằng 0.','Votes = 0 requires priority 0.'));
    if(ssh&&!data.host)throw new Error(vt('Nhập địa chỉ IP public hoặc địa chỉ SSH.','Enter the public IP or an SSH address.'));
    if(ssh&&data.ssh_auth==='password'&&!data.ssh_password&&!record?.has_ssh_password)throw new Error(vt('Nhập mật khẩu SSH.','Enter the SSH password.'));
    data.name=data.name||detected||(ssh?data.host:'Local');
    return data;
  }
  let generation=0;
  function update(){
    generation++;verified=false;expected='';feedback.textContent='';test.textContent=vt('Kiểm tra kết nối','Test connection');
    const ssh=fields.mode.value==='ssh';test.hidden=!ssh;
    for(const name of ['user','port','ssh_auth','identity','ssh_password','host']){
      const visible=ssh&&(name!=='identity'||fields.ssh_auth.value==='key')&&(name!=='ssh_password'||fields.ssh_auth.value==='password');
      fields[name].disabled=!visible;fields[name].closest('label').hidden=!visible;
    }
    fields.votes.onchange=fields.votes.oninput=()=>{if(fields.votes.value==='0')fields.priority.value=0;fields.priority.readOnly=fields.votes.value==='0';};
    form.querySelector('details').hidden=!ssh;
  }
  if(record){
    const m=(record.mongo_endpoint||'').match(/^\[?([^\]]+?)\]?:(\d+)$/);
    Object.entries({name:record.auto_name?'':record.name,mongo_host:m?m[1]:'',mongo_port:m?m[2]:27017,votes:record.votes,priority:record.priority,mode:record.mode,user:record.user,port:record.port,ssh_auth:record.ssh_auth||'key',identity:record.identity||'',host:m&&m[1]===record.host?'':record.host}).forEach(([k,v])=>{fields[k].value=v;});
    if(!m&&record.mode==='ssh')fields.mongo_host.value=record.host;
    if(record.has_ssh_password)fields.ssh_password.placeholder='••••••••';
  }
  $('#show-ssh-pw').onclick=async()=>{
    const inp=fields.ssh_password,btn=$('#show-ssh-pw');
    if(inp.type==='password'){
      if(!inp.value&&record?.has_ssh_password){
        btn.disabled=true;
        try{const r=await api('vps/servers/'+encodeURIComponent(record.id)+'/reveal-password',{});inp.value=r.password||'';}
        finally{btn.disabled=false;}
      }
      inp.type='text';btn.setAttribute('aria-pressed','true');
    }else{inp.type='password';btn.setAttribute('aria-pressed','false');}
  };
  $('#fields').oninput=update;setupSshKeyDropzone(form);update();
  // Trust on first use, like the MongoDB Manager: the host key is stored on the first successful connection.
  async function connect(){
    const data=payload(),id=generation;
    let result=await api('vps/connection-test',{...data,expected});
    if(result.fingerprint){expected=result.fingerprint;result=await api('vps/connection-test',{...data,expected});}
    if(id!==generation)return false;
    verified=true;detected=result.hostname||'';
    feedback.textContent=result.user+' · sudo -n '+(result.sudo?'✓':'—')+' · '+expected;
    return true;
  }
  test.onclick=async()=>{
    test.disabled=true;feedback.textContent=vt('Đang kết nối…','Connecting…');
    try{await connect();}catch(err){feedback.textContent=err.message;}finally{test.disabled=false;}
  };
  autoConnect=async()=>{if(!verified&&!await connect())throw new Error(vt('Thông tin kết nối đã đổi, thử lại.','Connection details changed, try again.'));};
  form.closest('dialog').addEventListener('close',()=>{$('#fields').oninput=null;},{once:true});
}
