const softwareDrafts=new Map();
const packagePages=new Map();
const VALID_SC_TABS=new Set(['kits','services','installed','repository']);

function getSoftwareTab(host){
  if(packagePages.has(host))return packagePages.get(host);
  let tab='kits';
  try{const saved=localStorage.getItem('vps-sc-tab:'+host);if(VALID_SC_TABS.has(saved))tab=saved;}catch{}
  packagePages.set(host,tab);
  return tab;
}

function setSoftwareTab(host,tab){
  const next=VALID_SC_TABS.has(tab)?tab:'kits';
  packagePages.set(host,next);
  try{localStorage.setItem('vps-sc-tab:'+host,next);}catch{}
}

function bindSoftwareTabs(view,host){
  for(const btn of view.querySelectorAll('[data-sc-tab]'))btn.onclick=()=>{setSoftwareTab(host,btn.dataset.scTab);render();};
}

function softwareToolbarHtml(activeTab,tr,extraHtml=''){
  const tabBtn=(id,label)=>`<button type="button" data-sc-tab="${id}" aria-pressed="${activeTab===id}">${label}</button>`;
  return `<header class="sc-toolbar">
    <div class="sc-modes" role="tablist" aria-label="Software Center">
      ${tabBtn('kits',tr('Bộ cài của tôi','My kits'))}
      ${tabBtn('services',tr('Dịch vụ','Services'))}
      ${tabBtn('installed',tr('Gói hệ điều hành','System packages'))}
      ${tabBtn('repository',tr('Kho phần mềm','Repository'))}
    </div>
    ${extraHtml}
    <button type="button" class="button small" data-tone="configure" id="pkg-maintain">${tr('Bảo trì gói','Package maintenance')}</button>
  </header>`;
}

function bindPackageMaintenance(){
  const btn=$('#pkg-maintain');
  if(!btn)return;
  btn.onclick=()=>{
    const host=$('#hosts').selectedOptions[0].textContent;
    modal('Bảo trì gói','<p>'+escapeHTML(host)+'</p><label class="field">Thao tác<select name="task"><option value="update-index">Cập nhật danh mục gói</option><option value="upgrade-packages">Nâng cấp các gói hệ thống</option><option value="refresh-ca">Làm mới kho chứng chỉ CA</option><option value="repair-ca">Cài lại OpenSSL và chứng chỉ CA</option></select></label>',form=>submit('maintain',{operation:form.get('task')}));
  };
}

function servicesView(view,path,host,tr){
  view.innerHTML=`<article class="sc-workbench">${softwareToolbarHtml('services',tr)}
    <section class="vps-box" style="border:0;border-radius:0 0 12px 12px">
      <div class="vps-search">
        <input type="search" id="svc-search" maxlength="100" placeholder="${tr('Tìm tên hoặc mô tả dịch vụ…','Filter by service name or description…')}">
        <select id="svc-filter" aria-label="${tr('Trạng thái','Status')}">
          <option value="">${tr('Tất cả dịch vụ','All services')}</option>
          <option value="active">${tr('Đang chạy','Running')}</option>
          <option value="enabled">${tr('Tự khởi động (enabled)','Enabled at boot')}</option>
          <option value="inactive">${tr('Đã dừng','Stopped')}</option>
          <option value="failed">${tr('Lỗi (failed)','Failed')}</option>
        </select>
        <label class="svc-check"><input type="checkbox" id="svc-sys"> ${tr('Hiện dịch vụ khác','Show other services')}</label>
        <button type="button" class="button small" data-tone="info" id="svc-refresh" style="margin-left:auto">${tr('Làm mới','Refresh')}</button>
      </div>
      <div id="svc-summary" class="svc-summary"></div>
      <div class="table-wrap"><table class="svc-table"><thead><tr>
        <th>${tr('Dịch vụ','Service')}</th>
        <th>${tr('Trạng thái','State')}</th>
        <th>${tr('Khởi động','Boot')}</th>
        <th>${tr('RAM / PID','RAM / PID')}</th>
        <th>${tr('Thao tác','Actions')}</th>
      </tr></thead><tbody id="svc-body"></tbody></table></div>
    </section></article>`;
  bindSoftwareTabs(view,host);
  bindPackageMaintenance();
  const body=$('#svc-body'),summary=$('#svc-summary'),search=$('#svc-search'),filter=$('#svc-filter'),showSys=$('#svc-sys');
  try{
    const saved=JSON.parse(localStorage.getItem('vps-sc-svc:'+host)||'{}');
    if(typeof saved.search==='string')search.value=saved.search;
    if(typeof saved.filter==='string')filter.value=saved.filter;
    if(typeof saved.showSys==='boolean')showSys.checked=saved.showSys;
  }catch{}
  let items=[];
  const fmtMem=b=>b==null?'—':b>=1073741824?(b/1073741824).toFixed(2)+' GiB':(b/1048576).toFixed(1)+' MiB';
  function drawServices(){
    try{localStorage.setItem('vps-sc-svc:'+host,JSON.stringify({search:search.value,filter:filter.value,showSys:showSys.checked}));}catch{}
    const q=search.value.trim().toLowerCase(),f=filter.value,sys=showSys.checked;
    const pool=sys?items:items.filter(s=>(s.category?s.category==='app':!s.protected));
    const filtered=pool.filter(s=>{
      if(f==='active'&&s.active!=='active')return false;
      if(f==='inactive'&&s.active==='active')return false;
      if(f==='failed'&&s.active!=='failed')return false;
      if(f==='enabled'&&s.enabled!=='enabled')return false;
      return !q||(s.name+' '+(s.description||'')).toLowerCase().includes(q);
    });
    const activeCount=pool.filter(s=>s.active==='active').length;
    const enabledCount=pool.filter(s=>s.enabled==='enabled').length;
    summary.textContent=`${activeCount} ${tr('đang chạy','running')} · ${enabledCount} ${tr('tự khởi động','enabled')} · ${filtered.length}/${pool.length} ${tr('hiển thị','shown')}`;
    body.replaceChildren();
    if(!filtered.length){
      body.innerHTML=`<tr><td colspan="5">${escapeHTML(tr('Không có dịch vụ phù hợp.','No matching services.'))}</td></tr>`;
      return;
    }
    for(const s of filtered){
      const trEl=document.createElement('tr');
      const stateCls=s.active==='active'?'success':s.active==='failed'?'error':'';
      const bootCls=s.enabled==='enabled'?'blue':s.enabled==='masked'?'warn':'';
      const badges=(s.kind==='timer'?' <span class="badge">timer</span>':'')+(s.protected?' <span class="badge warn">'+tr('Hệ thống','System')+'</span>':'');
      trEl.innerHTML=`<td><strong>${escapeHTML(s.name)}</strong>${badges}${s.description?'<br><small style="color:#56685c">'+escapeHTML(s.description)+'</small>':''}</td>
        <td><span class="badge ${stateCls}">${escapeHTML(s.active)} · ${escapeHTML(s.sub)}</span></td>
        <td><span class="badge ${bootCls}">${escapeHTML(s.enabled)}</span></td>
        <td><code>${escapeHTML(fmtMem(s.memory_bytes))}</code>${s.pid?'<br><small>PID '+escapeHTML(String(s.pid))+'</small>':''}</td>
        <td><div class="actions"></div></td>`;
      const act=trEl.querySelector('.actions');
      const addAct=(label,op,tone)=>{
        const b=document.createElement('button');b.type='button';b.className='button small';b.dataset.tone=tone;b.textContent=label;
        b.onclick=()=>modal(tr('Quản lý dịch vụ','Service control'),
          `<p><strong>${escapeHTML(s.name)}</strong> · ${escapeHTML(label)}</p><p>${escapeHTML(tr('Thực hiện lệnh systemctl trên VPS đang chọn?','Run systemctl on the selected server?'))}</p>`,
          ()=>submit('service-control',{name:s.name,operation:op}));
        act.append(b);
      };
      if(s.active==='active'){
        addAct(tr('Khởi động lại','Restart'),'restart','configure');
        if(!s.protected)addAct(tr('Dừng','Stop'),'stop','remove');
      }else{
        addAct(tr('Chạy','Start'),'start','create');
      }
      if(s.enabled==='enabled'){
        if(!s.protected)addAct(tr('Tắt tự chạy','Disable'),'disable','warning');
      }else if(s.enabled==='disabled'){
        addAct(tr('Bật tự chạy','Enable'),'enable','info');
      }
      body.append(trEl);
    }
  }
  async function loadServices(){
    body.innerHTML=`<tr><td colspan="5"><span class="spinner"></span> ${escapeHTML(tr('Đang đọc danh sách dịch vụ…','Reading services…'))}</td></tr>`;
    summary.textContent='';
    try{
      const data=await api(path+'/services');
      if(!body.isConnected)return;
      items=data.items||[];
      drawServices();
    }catch(err){
      if(body.isConnected)body.innerHTML=`<tr><td colspan="5">${escapeHTML(err.message)}</td></tr>`;
    }
  }
  search.oninput=drawServices;
  filter.onchange=drawServices;
  showSys.onchange=drawServices;
  $('#svc-refresh').onclick=loadServices;
  loadServices();
  return null;
}

function softwarePage(view,path,host){
  const page=getSoftwareTab(host);
  if(page==='kits')return view;
  const tr=(vi,en)=>vpsEnglish?en:vi;
  if(page==='services')return servicesView(view,path,host,tr);
  const remote=page==='repository';
  view.innerHTML=`<article class="sc-workbench">${softwareToolbarHtml(page,tr)}
    <section class="vps-box" style="border:0;border-radius:0 0 12px 12px"><form class="vps-search"><input type="search" maxlength="100" aria-label="${tr('Tên gói','Package name')}" placeholder="${remote?tr('Tên gói trong kho, ví dụ tree','Repository package, e.g. tree'):tr('Lọc theo tên gói…','Filter by package name…')}"><button class="button small" data-tone="info">${tr('Tìm','Search')}</button></form>
    <div class="vps-package-results" aria-live="polite"></div><div class="vps-pager"></div></section></article>`;
  bindSoftwareTabs(view,host);
  bindPackageMaintenance();
  const form=view.querySelector('form'),results=view.querySelector('.vps-package-results'),pager=view.querySelector('.vps-pager');
  results.classList.toggle('installed-grid',!remote);
  let generation=0,offset=0,query='';
  function capacity(){
    if(remote)return 30;
    const grid=getComputedStyle(results);
    const columns=grid.gridTemplateColumns.split(' ').length;
    const rowHeight=parseFloat(grid.gridAutoRows)+parseFloat(grid.rowGap);
    const top=form.getBoundingClientRect().bottom+window.scrollY;
    const available=window.innerHeight-top-parseFloat(grid.paddingTop)-parseFloat(grid.paddingBottom)-64;
    return Math.min(240,columns*Math.max(1,Math.floor(available/rowHeight)));
  }
  let limit=capacity();
  if(!remote){
    let timer;
    function resize(){
      clearTimeout(timer);
      if(!results.isConnected){
        observer.disconnect();
        window.removeEventListener('resize',resize);
        return;
      }
      timer=setTimeout(()=>{
        if(!results.isConnected)return;
        const next=capacity();
        if(next===limit)return;
        offset=Math.floor(offset/next)*next;
        limit=next;load();
      },150);
    }
    const observer=new ResizeObserver(resize);
    observer.observe(results);
    window.addEventListener('resize',resize);
  }
  async function load(){
    const current=++generation;
    pager.replaceChildren();
    if(remote&&!query){results.textContent=tr('Nhập tên để tìm trong kho của VPS.','Enter a name to search this server’s repositories.');return;}
    results.textContent=tr('Đang đọc danh sách gói…','Reading packages…');
    try{
      const data=await api(path+'/packages?'+new URLSearchParams({scope:page,query,offset,limit}));
      if(current!==generation||!results.isConnected)return;
      results.replaceChildren();
      for(const item of data.items){
        const row=document.createElement('div');row.className='vps-package';
        const title=document.createElement('strong');title.textContent=title.title=item.name;
        const version=document.createElement('code');version.textContent=version.title=item.version;row.append(title,version);
        if(remote){
          const btn=document.createElement('button');btn.className='button small';btn.dataset.tone='info';btn.textContent=tr('Xem kế hoạch','Preview');
          btn.onclick=async()=>{
            btn.disabled=true;
            try{
              const plan=await api(path+'/package-plan?'+new URLSearchParams({name:item.name}));
              if(!btn.isConnected)return;
              modal(tr('Cài gói từ kho','Install repository package'),'<p>'+escapeHTML($('#hosts').selectedOptions[0].textContent)+' · '+escapeHTML(plan.target)+'</p><pre>'+escapeHTML(plan.summary)+'</pre>',()=>submit('native-install',{name:item.name,target:plan.target}));
            }catch(err){if(btn.isConnected)row.append(document.createTextNode(err.message));}
            finally{btn.disabled=false;}
          };row.append(btn);
        }
        results.append(row);
      }
      if(!data.total){results.textContent=tr('Không tìm thấy gói.','No packages found.');return;}
      const count=document.createElement('span');count.textContent=(offset+1)+'–'+(offset+data.items.length)+' / '+data.total;pager.append(count);
      for(const [delta,label] of [[-limit,tr('Trước','Previous')],[limit,tr('Sau','Next')]]){
        const btn=document.createElement('button');btn.className='button small';btn.dataset.tone='info';btn.textContent=label;
        btn.disabled=offset+delta<0||offset+delta>=data.total;btn.onclick=()=>{offset+=delta;load();};pager.append(btn);
      }
    }catch(err){if(current===generation&&results.isConnected)results.textContent=err.message;}
  }
  form.onsubmit=e=>{e.preventDefault();offset=0;query=form.querySelector('input').value.trim();load();};
  load();
  return null;
}

function softwareCenter(view,info){
  const tr=(vi,en)=>vpsEnglish?en:vi;
  const catalog=info.catalog, hidden=new Set(info.hidden||[]);
  const ids=Object.keys(catalog).filter(id=>!hidden.has(id));
  const host=$('#hosts').value;
  if(!softwareDrafts.has(host)){
    let saved={};
    try{saved=JSON.parse(localStorage.getItem('vps-sc:'+host)||'{}');}catch{}
    softwareDrafts.set(host,{selected:new Set(),mode:saved.mode||'kits',kit:saved.kit||'',search:saved.search||'',filter:saved.filter??'no'});
  }
  const draft=softwareDrafts.get(host), selected=draft.selected;
  for(const id of selected)if(!Object.hasOwn(catalog,id)||hidden.has(id))selected.delete(id);
  const presets={'*':ids,...info.kits};
  const kits=Object.keys(presets);
  if(!kits.includes(draft.kit))draft.kit='*';
  const groupName=name=>name==='*'?tr('Tất cả','All'):(vpsEnglish?(englishLabels[name]||({'Công cụ VPS':'VPS tools','Web cơ bản':'Basic web'})[name]||name):name);
  const status=id=>info.probe_errors?.[id]||!Object.hasOwn(info.packages,id)?'unknown':info.packages[id]?'yes':'no';
  view.innerHTML=`<article class="sc-workbench">
    ${softwareToolbarHtml('kits',tr,`<input type="search" id="pkg-search" placeholder="${tr('Tìm gói phần mềm…','Find a package…')}" aria-label="${tr('Tìm gói phần mềm','Find a package')}">`)}
    <div class="sc-columns"><div class="sc-index" id="sc-index"></div><section class="sc-detail">
      <div class="sc-title"><h2 id="sc-title"></h2><button id="sc-all" class="text-button"></button>
      <select id="pkg-filter" aria-label="${tr('Trạng thái','Status')}"><option value="">${tr('Mọi trạng thái','Any status')}</option>
      <option value="yes">${tr('Đã cài','Installed')}</option><option value="no">${tr('Còn thiếu','Missing')}</option><option value="unknown">${tr('Chưa xác minh','Unverified')}</option></select></div>
      <div id="pkg-list"></div></section></div>
    <footer class="sc-order"><button class="text-button" id="pkg-count"></button>
      <div class="actions"><button class="button small" data-tone="remove" id="uninstall">${tr('Gỡ đã chọn','Uninstall')}</button>
      <button class="button primary small" id="install">${tr('Tiếp tục →','Continue →')}</button></div></footer>
  </article>`;
  $('#pkg-search').value=draft.search;
  $('#pkg-filter').value=draft.filter;
  function draw(){
    try{localStorage.setItem('vps-sc:'+host,JSON.stringify({mode:draft.mode,kit:draft.kit,search:draft.search,filter:draft.filter}));}catch{}
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
    $('#pkg-count').disabled=!selected.size;
    $('#install').disabled=![...selected].some(id=>status(id)!=='yes');
    $('#uninstall').disabled=![...selected].some(id=>status(id)==='yes');
  }
  bindSoftwareTabs(view,host);
  bindPackageMaintenance();
  $('#pkg-count').onclick=()=>{draft.mode='selection';draft.search='';$('#pkg-search').value='';draw();};
  $('#pkg-search').oninput=e=>{draft.search=e.target.value;draw();};
  $('#pkg-filter').onchange=e=>{draft.filter=e.target.value;draw();};
  $('#install').onclick=()=>reviewInstall([...selected]);
  $('#uninstall').onclick=()=>{
    const packages=[...selected].filter(id=>status(id)==='yes');
    if(!packages.length)return;
    modal(tr('Gỡ phần mềm','Uninstall packages'),
      machineChoices()+'<div class="callout error" style="margin-top:10px">'+tr('Sẽ gỡ bỏ các gói đã chọn trên các máy được đánh dấu: ','Will uninstall selected packages on checked servers: ')+'<strong>'+packages.map(id=>escapeHTML(catalog[id]||id)).join(', ')+'</strong></div>',
      form=>submitTargets(form,'uninstall',{packages}));
  };
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
        const hostName=b.parentElement.textContent.trim();
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
          return {host:hostName,missing,lines:[
            [tr('Cần cài','To install'),missing],
            [tr('Đã có','Installed'),installed.map(id=>id+' '+state.packages[id])],
            [tr('Phụ thuộc','Dependencies'),dependencies]
          ].filter(([,items])=>items.length)};
        }catch(err){return {host:hostName,error:err.message};}
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
  }
  draw();
}
