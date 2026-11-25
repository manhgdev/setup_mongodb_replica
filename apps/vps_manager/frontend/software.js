const softwareDrafts=new Map();

function softwareCenter(view,info){
  const tr=(vi,en)=>vpsEnglish?en:vi;
  const catalog=info.catalog, ids=Object.keys(catalog);
  const host=$('#hosts').value;
  if(!softwareDrafts.has(host)){let saved={};try{saved=JSON.parse(sessionStorage.getItem('vps-sc:'+host)||'{}');}catch{}softwareDrafts.set(host,{selected:new Set(),mode:saved.mode||'kits',group:saved.group||'',kit:saved.kit||'',search:saved.search||'',filter:saved.filter??'no'});}
  const draft=softwareDrafts.get(host), selected=draft.selected;
  for(const id of selected)if(!Object.hasOwn(catalog,id))selected.delete(id);
  const presets={'*':ids,...info.kits};
  const kits=Object.keys(presets);
  if(!kits.includes(draft.kit))draft.kit='*';
  const groupName=name=>name==='*'?tr('Tất cả','All'):(vpsEnglish?(englishLabels[name]||({'Công cụ VPS':'VPS tools','Web cơ bản':'Basic web'})[name]||name):name);
  const status=id=>info.probe_errors?.[id]||!Object.hasOwn(info.packages,id)?'unknown':info.packages[id]?'yes':'no';
  view.innerHTML=`<article class="sc-workbench">
    <header class="sc-toolbar"><strong>${tr('Bộ cài của tôi','My kits')}</strong>
      <input type="search" id="pkg-search" placeholder="${tr('Tìm gói phần mềm…','Find a package…')}" aria-label="${tr('Tìm gói phần mềm','Find a package')}"></header>
    <div class="sc-columns"><div class="sc-index" id="sc-index"></div><section class="sc-detail">
      <div class="sc-title"><h2 id="sc-title"></h2><button id="sc-all" class="text-button"></button>
      <select id="pkg-filter" aria-label="${tr('Trạng thái','Status')}"><option value="">${tr('Mọi trạng thái','Any status')}</option>
      <option value="yes">${tr('Đã cài','Installed')}</option><option value="no">${tr('Còn thiếu','Missing')}</option><option value="unknown">${tr('Chưa xác minh','Unverified')}</option></select></div>
      <div id="pkg-list"></div></section></div>
    <footer class="sc-order"><button class="text-button" id="pkg-count"></button>
      <button class="button primary small" id="install">${tr('Tiếp tục →','Continue →')}</button></footer>
  </article><div class="sc-utils"><details><summary>${tr('Công cụ VPS','Server tools')}</summary>
  <button class="button small" data-tool="installed">${tr('Gói hệ điều hành','System packages')}</button>
  <button class="button small" data-tool="repository">${tr('Kho phần mềm','Repository')}</button>
  <button class="button small" id="pkg-maintain">${tr('Bảo trì gói','Package maintenance')}</button>
  <button class="button small" id="account">${tr('Tài khoản & SSH','Account & SSH')}</button></details></div>`;
  $('#pkg-search').value=draft.search;
  $('#pkg-filter').value=draft.filter;
  function draw(){
    try{sessionStorage.setItem('vps-sc:'+host,JSON.stringify({mode:draft.mode,group:draft.group,kit:draft.kit,search:draft.search,filter:draft.filter}));}catch{}
    const query=draft.search.trim().toLowerCase();
    const selectionMode=draft.mode==='selection';
    const included=key=>presets[key].filter(id=>id in catalog);
    const index=$('#sc-index'), scroll=index.scrollLeft;index.replaceChildren();
    for(const key of kits){
      const btn=document.createElement('button');
      btn.type='button';btn.setAttribute('aria-pressed',String(key===draft.kit&&!selectionMode));
      btn.innerHTML='<span>'+escapeHTML(groupName(key))+'</span><small>'+included(key).filter(id=>status(id)==='yes').length+'/'+included(key).length+'</small>';
      btn.onclick=()=>{draft.mode='kits';draft.kit=key;draw();};index.append(btn);
    }
    index.scrollLeft=scroll;
    const active=index.querySelector('[aria-pressed=true]');
    if(active&&index.scrollWidth>index.clientWidth){
      const offset=active.getBoundingClientRect().right-index.getBoundingClientRect().right;
      if(offset>0)index.scrollLeft+=offset+6;
    }
    const rows=selectionMode?[...selected]:included(draft.kit);
    $('#sc-title').textContent=selectionMode?tr('Đã chọn','Selection'):groupName(draft.kit);
    const visible=rows.filter(id=>(!draft.filter||status(id)===draft.filter)&&(id+' '+catalog[id]).toLowerCase().includes(query));
    const all=$('#sc-all');
    const allSelected=visible.length>0&&visible.every(id=>selected.has(id));
    all.textContent=allSelected?tr('Bỏ chọn tất cả','Deselect all'):tr('Chọn tất cả','Select all');
    all.disabled=!visible.length;
    all.onclick=()=>{for(const id of visible){if(allSelected)selected.delete(id);else selected.add(id);}draw();};
    const list=$('#pkg-list');list.replaceChildren();
    for(const id of visible){
      const label=document.createElement('label');label.className='sc-package';
      const box=document.createElement('input');box.type='checkbox';box.checked=selected.has(id);
      const title=document.createElement('span');title.textContent=catalog[id];
      const version=document.createElement('small');version.textContent=status(id)==='unknown'?tr('Chưa xác minh','Unverified'):info.packages[id]||tr('Chưa cài','Not installed');
      if(info.packages[id])version.className='sc-installed';
      box.onchange=()=>{if(box.checked)selected.add(id);else selected.delete(id);draw();list.querySelectorAll('input')[visible.indexOf(id)]?.focus({preventScroll:true});};
      label.append(box,title,version);list.append(label);
    }
    if(!visible.length)list.textContent=tr('Không có gói phù hợp.','No matching packages.');
    $('#pkg-count').textContent=selected.size+tr(' gói đã chọn',' selected');
    $('#pkg-count').disabled=$('#install').disabled=!selected.size;
  }
  function changeMode(mode){
    draft.mode=mode;draft.search='';$('#pkg-search').value='';draw();
  }
  for(const btn of view.querySelectorAll('[data-tool]'))btn.onclick=()=>{packagePages.set(host,btn.dataset.tool);render();};
  $('#pkg-count').onclick=()=>changeMode('selection');
  $('#pkg-search').oninput=e=>{draft.search=e.target.value;draw();};
  $('#pkg-filter').onchange=e=>{draft.filter=e.target.value;draw();};
  $('#pkg-maintain').onclick=()=>{
    const host=$('#hosts').selectedOptions[0].textContent;
    modal('Bảo trì gói','<p>'+escapeHTML(host)+'</p><label class="field">Thao tác<select name="task"><option value="update-index">Cập nhật danh mục gói</option><option value="upgrade-packages">Nâng cấp các gói hệ thống</option><option value="refresh-ca">Làm mới kho chứng chỉ CA</option><option value="repair-ca">Cài lại OpenSSL và chứng chỉ CA</option></select></label>',form=>submit('maintain',{operation:form.get('task')}));
  };
  $('#install').onclick=()=>reviewInstall([...selected]);
  function reviewInstall(packages){
    let reviewed='',targets=[];
    modal('Cài phần mềm',machineChoices()+'<div id="pkg-review"></div>',form=>{if(!reviewed||reviewed!==JSON.stringify(form.getAll('machines')))throw new Error('Chờ kiểm tra các máy đã chọn.');form.delete('machines');for(const id of targets)form.append('machines',id);return submitTargets(form,'install',{packages});});
    const review=$('#pkg-review'), form=$('#popup'), confirm=form.querySelector('[type=submit]');
    let version=0;
    async function refresh(){
      const current=++version;
      const boxes=[...form.querySelectorAll('[name=machines]:checked')];
      reviewed='';confirm.disabled=true;review.textContent='Đang đọc thông tin VPS…';
      const rows=await Promise.all(boxes.map(async b=>{
        const host=b.parentElement.textContent.trim();
        try{
          const state=(b.value===$('#hosts').value&&info.packages&&Object.keys(info.packages).length&&!info.checkError)?info:await api('vps/machines/'+encodeURIComponent(b.value));
          const needed=new Set();
          function include(id){
            if(needed.has(id))return;
            needed.add(id);
            for(const dep of state.dependencies?.[id]||[])include(dep);
          }
          packages.forEach(include);
          const unknown=[...needed].filter(id=>state.probe_errors?.[id]||!Object.hasOwn(state.packages,id));
          if(unknown.length)throw new Error(tr('Chưa xác minh','Unverified')+' · '+unknown.join(', '));
          const missing=[...needed].filter(id=>!state.packages[id]);
          const installed=[...needed].filter(id=>state.packages[id]);
          const dependencies=[...needed].filter(id=>!packages.includes(id));
          return {host,missing,lines:[
            [tr('Cần cài','To install'),missing],
            [tr('Đã có','Installed'),installed.map(id=>id+' '+state.packages[id])],
            [tr('Phụ thuộc','Dependencies'),dependencies]
          ].filter(([,items])=>items.length)};
        }catch(err){return {host,error:err.message};}
      }));
      if(version!==current||!review.isConnected)return;
      review.replaceChildren();
      for(const row of rows){
        const block=document.createElement('section'),title=document.createElement('strong');title.textContent=row.host;block.append(title);
        if(row.error){
          const message=document.createElement('p'), retry=document.createElement('button');message.textContent=row.error;
          retry.type='button';retry.className='button small';retry.textContent=tr('Thử lại','Retry');retry.onclick=refresh;block.append(message,retry);
        }else for(const [label,items] of row.lines){
          const line=document.createElement('p');line.textContent=label+' · '+items.join(', ');block.append(line);
        }
        review.append(block);
      }
      confirm.disabled=!rows.length||rows.some(r=>r.error)||rows.every(r=>!r.missing?.length);
      if(!confirm.disabled){
        targets=boxes.filter((box,i)=>rows[i].missing.length).map(box=>box.value);
        reviewed=JSON.stringify(boxes.map(b=>b.value));
      }
    }
    for(const box of form.querySelectorAll('[name=machines]'))box.onchange=refresh;
    refresh();
  };
  draw();
}

async function accountDialog(){
  const path=endpoint(), rev=revision;
  const state=await api(path+'/account');
  if(rev!==revision)return;
  const target=state.user+'@'+state.host+':'+state.port;
  const canChange=state.sudo&&state.user!=='root'&&state.auth==='key';
  const fields='<p><strong>'+escapeHTML(target)+'</strong> · '+escapeHTML(state.auth)+'</p><p>sudo -n · '+(state.sudo?'✓':'—')+'　 SSH PasswordAuthentication · '+escapeHTML(state.password||'—')+'</p>';
  if(!canChange){modal('Tài khoản & SSH',fields+'<p>Chọn user thường dùng SSH key và có quyền sudo -n để đặt mật khẩu.</p>',async()=>{});return;}
  modal('Tài khoản & SSH',fields+'<div class="form-grid"><label class="field">Mật khẩu Linux mới<input name="password" type="password" autocomplete="new-password" required></label><label class="field">Nhập lại mật khẩu<input name="repeat" type="password" autocomplete="new-password" required></label></div><p><label><input id="show-secret" type="checkbox"> Hiện mật khẩu</label></p><label><input name="enable" type="checkbox"> Cho phép user này đăng nhập SSH bằng mật khẩu</label>',async form=>{
    if(form.get('password')!==form.get('repeat'))throw new Error('Hai mật khẩu chưa khớp.');
    await submit('password',{password:form.get('password'),enable:form.has('enable')});
  });
  $('#show-secret').onchange=e=>{for(const input of $('#popup').querySelectorAll('[autocomplete=new-password]'))input.type=e.target.checked?'text':'password';};
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
  $('#fields').oninput=update;update();
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
