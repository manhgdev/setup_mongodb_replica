// Termius-style dual-pane multi-tab SFTP file manager with inline editor, chmod matrix, drag-drop, and transfer queue.
const sftpTabs=[];
let activeSftpTabId='',sftpTabSeq=0,sftpXferSeq=0;
const sftpTransfers=[];
let sftpDrawerOpen=true,sftpPendingMachineId='';

window.openSftpForMachine=function(machineId){
  sftpPendingMachineId=machineId||'';
  location.hash='#sftp';
};

function sftpFmtBytes(bytes){
  const n=Number(bytes||0);
  if(n<1024)return n+' B';
  if(n<1048576)return (n/1024).toFixed(1)+' KB';
  if(n<1073741824)return (n/1048576).toFixed(1)+' MB';
  return (n/1073741824).toFixed(2)+' GB';
}

function sftpFmtTime(ts){
  if(!ts)return '—';
  const d=new Date(ts*1000);
  const pad=v=>String(v).padStart(2,'0');
  return d.getFullYear()+'-'+pad(d.getMonth()+1)+'-'+pad(d.getDate())+' '+pad(d.getHours())+':'+pad(d.getMinutes());
}

function sftpParentPath(p){
  if(!p||p==='/')return '/';
  const clean=p.replace(/\/+$/,'');
  const idx=clean.lastIndexOf('/');
  if(idx<=0)return '/';
  return clean.slice(0,idx);
}

function sftpJoinPath(base,name){
  if(!base||base==='/')return '/'+name;
  return base.replace(/\/+$/,'')+'/'+name;
}

function sftpIcon(entry){
  if(entry.type==='dir')return '<span class="sftp-ico is-dir" title="Folder">📁</span>';
  if(entry.type==='symlink')return '<span class="sftp-ico is-link" title="Symlink">🔗</span>';
  const ext=(entry.name.split('.').pop()||'').toLowerCase();
  if(['zip','gz','tar','tgz','bz2','xz','7z'].includes(ext))return '<span class="sftp-ico">🗜️</span>';
  if(['png','jpg','jpeg','gif','webp','svg','ico'].includes(ext))return '<span class="sftp-ico">🖼️</span>';
  if(['sh','py','js','ts','json','yml','yaml','conf','env','md','txt','log','css','html'].includes(ext))return '<span class="sftp-ico">📄</span>';
  return '<span class="sftp-ico">📃</span>';
}

function createSftpPaneState(machineId){
  return {
    machineId:machineId||'',
    cwd:'',
    home:'',
    entries:[],
    selected:new Set(),
    showHidden:false,
    filter:'',
    sortBy:'name',
    sortDir:'asc',
    loading:false,
    error:''
  };
}

function createSftpTab(servers,primaryId){
  const id='sftp-tab-'+(++sftpTabSeq);
  const first=primaryId||servers[0]?.id||'';
  const second=servers.find(s=>s.id!==first)?.id||first;
  const tab={
    id,
    title:'',
    dualPane:true,
    activeSide:'left',
    left:createSftpPaneState(first),
    right:createSftpPaneState(second)
  };
  sftpTabs.push(tab);
  activeSftpTabId=id;
  return tab;
}

async function sftpPage(view,path,rev){
  let servers=[];
  try{
    servers=await api('vps/servers');
  }catch{
    servers=Array.from($('#hosts').options,o=>({id:o.value,name:o.textContent}));
  }
  if(rev!==revision)return;
  if(!servers.length){
    view.innerHTML='<section class="vps-box vps-empty"><h2>'+vt('Chưa có máy chủ','No servers yet')+'</h2><button class="button primary" id="sftp-add-vps">+ '+vt('Thêm VPS','Add server')+'</button></section>';
    $('#sftp-add-vps').onclick=()=>addVps();
    return;
  }

  const currentHost=$('#hosts')?.value||servers[0].id;
  if(sftpPendingMachineId){
    const targetId=sftpPendingMachineId;
    sftpPendingMachineId='';
    createSftpTab(servers,targetId);
  }else if(!sftpTabs.length){
    createSftpTab(servers,currentHost);
  }
  if(!sftpTabs.some(t=>t.id===activeSftpTabId)){
    activeSftpTabId=sftpTabs[0].id;
  }

  const shell=document.createElement('section');
  shell.className='sftp-shell';
  shell.innerHTML=`
    <div class="sftp-topbar">
      <div class="sftp-tabs" id="sftp-tabs"></div>
      <div class="sftp-top-actions">
        <button type="button" class="button small" id="sftp-new-tab" data-tone="create">+ ${vt('Tab SFTP','New SFTP tab')}</button>
        <button type="button" class="button small" id="sftp-toggle-dual" data-tone="info"></button>
        <button type="button" class="button small" id="sftp-swap" title="${vt('Đổi vị trí 2 khung','Swap panes')}">⇄ ${vt('Đảo khung','Swap')}</button>
      </div>
    </div>
    <div class="sftp-stage" id="sftp-stage"></div>
    <div class="sftp-drawer" id="sftp-drawer">
      <div class="sftp-drawer-head">
        <strong>${vt('Hàng đợi truyền file','Transfer queue')} (<span id="sftp-xfer-count">0</span>)</strong>
        <div class="actions">
          <button type="button" class="button small" id="sftp-xfer-clear">${vt('Xóa đã xong','Clear finished')}</button>
          <button type="button" class="button small" id="sftp-xfer-toggle">${sftpDrawerOpen?vt('Thu gọn','Collapse'):vt('Mở rộng','Expand')}</button>
        </div>
      </div>
      <div class="sftp-drawer-body" id="sftp-drawer-body" ${sftpDrawerOpen?'':'hidden'}></div>
    </div>
  `;
  view.replaceChildren(shell);

  const tabsEl=$('#sftp-tabs'),stageEl=$('#sftp-stage'),drawerBody=$('#sftp-drawer-body'),xferCount=$('#sftp-xfer-count');
  const getTab=()=>sftpTabs.find(t=>t.id===activeSftpTabId)||sftpTabs[0];
  const serverName=id=>servers.find(s=>s.id===id)?.name||id||'VPS';

  function renderDrawer(){
    xferCount.textContent=String(sftpTransfers.length);
    if(!sftpTransfers.length){
      drawerBody.innerHTML='<div class="sftp-xfer-empty">'+vt('Chưa có tác vụ truyền file nào. Kéo thả file vào khung hoặc dùng nút Tải lên / Chép giữa 2 khung.','No file transfers yet. Drag & drop files or use Upload / Copy between panes.')+'</div>';
      return;
    }
    drawerBody.replaceChildren();
    for(const x of sftpTransfers.slice().reverse()){
      const pct=x.total>0?Math.min(100,Math.round((x.loaded/x.total)*100)):(x.status==='succeeded'?100:0);
      const row=document.createElement('div');
      row.className='sftp-xfer-row';
      row.dataset.state=x.status;
      row.innerHTML=`
        <div class="sftp-xfer-meta">
          <strong>${escapeHTML(x.label)}</strong>
          <small>${escapeHTML(x.detail||'')}</small>
        </div>
        <div class="sftp-xfer-bar"><i style="width:${pct}%"></i></div>
        <span class="sftp-xfer-pct">${x.status==='running'?(pct+'%'):(x.status==='succeeded'?'✓':x.status==='cancelled'?vt('Đã hủy','Cancelled'):'✗')}</span>
        ${x.status==='running'&&x.serverTransferId?'<button type="button" class="button small" data-tone="remove">'+vt('Hủy','Cancel')+'</button>':''}
      `;
      const cancelBtn=row.querySelector('button');
      if(cancelBtn){
        cancelBtn.onclick=async()=>{
          await api('vps/sftp/transfers/'+encodeURIComponent(x.serverTransferId)+'/cancel',{}).catch(()=>{});
          x.status='cancelled';
          renderDrawer();
        };
      }
      drawerBody.append(row);
    }
  }

  async function loadPane(pane,targetPath){
    if(!pane.machineId)return;
    pane.loading=true;
    pane.error='';
    renderStage();
    try{
      const q=new URLSearchParams();
      if(targetPath!==undefined&&targetPath!=='')q.set('path',targetPath);
      else if(pane.cwd)q.set('path',pane.cwd);
      if(pane.showHidden)q.set('show_hidden','true');
      const res=await api('vps/machines/'+encodeURIComponent(pane.machineId)+'/sftp/list?'+q.toString());
      if(rev!==revision)return;
      pane.cwd=res.cwd;
      pane.home=res.home||res.cwd;
      pane.entries=res.entries||[];
      pane.selected.clear();
    }catch(err){
      pane.error=err.message||vt('Không đọc được thư mục.','Failed to list directory.');
    }finally{
      pane.loading=false;
      renderTabs();
      renderStage();
    }
  }

  function sortedEntries(pane){
    const q=(pane.filter||'').trim().toLowerCase();
    const list=q?pane.entries.filter(e=>e.name.toLowerCase().includes(q)):pane.entries.slice();
    const dirMul=pane.sortDir==='desc'?-1:1;
    list.sort((a,b)=>{
      if(a.type==='dir'&&b.type!=='dir')return -1;
      if(a.type!=='dir'&&b.type==='dir')return 1;
      if(pane.sortBy==='size')return (a.size-b.size)*dirMul;
      if(pane.sortBy==='mtime')return (a.mtime-b.mtime)*dirMul;
      return a.name.localeCompare(b.name)*dirMul;
    });
    return list;
  }

  function uploadFilesToPane(pane,files){
    if(!files?.length)return;
    if(previewMode){
      modal(vt('Chế độ xem thử','Preview mode'),'<p>'+vt('Đang xem dữ liệu minh họa. Chuyển sang dữ liệu thật để tải file lên VPS.','Preview mode uses sample data. Switch to live data to upload files.')+'</p>',async()=>{});
      return;
    }
    const destDir=pane.cwd||'~';
    const wsHeaders=window.zmWorkspaceHelper?window.zmWorkspaceHelper.headers():{};
    for(const file of files){
      const xfer={id:'x-'+(++sftpXferSeq),label:'↑ '+file.name+' → '+serverName(pane.machineId),detail:destDir,loaded:0,total:file.size||1,status:'running'};
      sftpTransfers.push(xfer);
      renderDrawer();
      const xhr=new XMLHttpRequest();
      const url='/api/vps/machines/'+encodeURIComponent(pane.machineId)+'/sftp/upload?path='+encodeURIComponent(destDir)+'&filename='+encodeURIComponent(file.name);
      xhr.open('POST',url,true);
      xhr.setRequestHeader('X-MongoDB-Manager','1');
      xhr.setRequestHeader('X-CSRF-Token',csrf);
      for(const [k,v]of Object.entries(wsHeaders))xhr.setRequestHeader(k,v);
      xhr.upload.onprogress=ev=>{
        if(ev.lengthComputable){xfer.loaded=ev.loaded;xfer.total=ev.total;xfer.detail=sftpFmtBytes(ev.loaded)+' / '+sftpFmtBytes(ev.total);renderDrawer();}
      };
      xhr.onload=()=>{
        if(xhr.status>=200&&xhr.status<300){
          xfer.status='succeeded';xfer.loaded=xfer.total;xfer.detail=destDir+' · '+sftpFmtBytes(file.size);
          loadPane(pane,pane.cwd);
        }else{
          let msg='HTTP '+xhr.status;
          try{msg=JSON.parse(xhr.responseText).detail||msg;}catch{}
          xfer.status='failed';xfer.detail=msg;
        }
        renderDrawer();
      };
      xhr.onerror=()=>{xfer.status='failed';xfer.detail=vt('Lỗi mạng khi tải lên','Network error');renderDrawer();};
      xhr.send(file);
    }
  }

  async function transferBetweenPanes(srcPane,dstPane,paths,op){
    if(!paths.length)return;
    if(previewMode){
      modal(vt('Chế độ xem thử','Preview mode'),'<p>'+vt('Đang xem dữ liệu minh họa. Chuyển sang dữ liệu thật để truyền file giữa 2 VPS.','Preview mode uses sample data. Switch to live data to transfer files.')+'</p>',async()=>{});
      return;
    }
    const label=(op==='move'?'⇄ ':'→ ')+paths.length+' '+vt('mục','item(s)')+': '+serverName(srcPane.machineId)+' → '+serverName(dstPane.machineId);
    const xfer={id:'x-'+(++sftpXferSeq),label,detail:dstPane.cwd||'~',loaded:0,total:1,status:'running',serverTransferId:''};
    sftpTransfers.push(xfer);
    renderDrawer();
    try{
      const job=await api('vps/sftp/transfer',{
        source_machine:srcPane.machineId,
        target_machine:dstPane.machineId,
        paths,
        target_dir:dstPane.cwd||'~',
        op
      });
      xfer.serverTransferId=job.id;
      for(let i=0;i<1800;i++){
        const st=await api('vps/sftp/transfers/'+encodeURIComponent(job.id));
        xfer.loaded=st.bytes_transferred||0;
        xfer.total=st.total_bytes||1;
        xfer.detail=(st.current_file?st.current_file+' · ':'')+sftpFmtBytes(xfer.loaded)+' / '+sftpFmtBytes(st.total_bytes||0);
        if(st.status==='succeeded'||st.status==='failed'||st.status==='cancelled'){
          xfer.status=st.status;
          if(st.error)xfer.detail=st.error;
          renderDrawer();
          if(st.status==='succeeded'){
            loadPane(dstPane,dstPane.cwd);
            if(op==='move')loadPane(srcPane,srcPane.cwd);
          }
          return;
        }
        renderDrawer();
        await new Promise(r=>setTimeout(r,500));
      }
    }catch(err){
      xfer.status='failed';
      xfer.detail=err.message;
      renderDrawer();
    }
  }

  function openEditorModal(pane,entry){
    api('vps/machines/'+encodeURIComponent(pane.machineId)+'/sftp/file?path='+encodeURIComponent(entry.path)).then(data=>{
      modal(vt('Sửa file: ','Edit file: ')+entry.name,
        '<div class="sftp-editor-meta"><code>'+escapeHTML(data.path)+'</code><span>'+sftpFmtBytes(data.size)+' · '+escapeHTML(data.octal||'')+'</span></div>'
        +'<textarea name="content" class="sftp-editor-area" spellcheck="false">'+escapeHTML(data.content)+'</textarea>',
        async form=>{
          await api('vps/machines/'+encodeURIComponent(pane.machineId)+'/sftp/file',{path:data.path,content:String(form.get('content')||'')},'PUT');
          await loadPane(pane,pane.cwd);
        });
    }).catch(err=>{
      modal(vt('Không mở được file','Cannot open file'),'<div class="callout error">'+escapeHTML(err.message)+'</div>',async()=>{});
    });
  }

  function openChmodModal(pane,entry){
    const modeNum=entry.mode??0o644;
    const bit=(mask)=>((modeNum&mask)?'checked':'');
    modal(vt('Phân quyền (chmod): ','Permissions (chmod): ')+entry.name,
      `<p class="mono" style="margin-bottom:10px">${escapeHTML(entry.path)}</p>
      <label class="field">${vt('Mã Octal (ví dụ 0755, 0644)','Octal mode (e.g. 0755, 0644)')}<input name="mode" id="chmod-octal" value="${escapeHTML(entry.octal||'0644')}" maxlength="4" required></label>
      <div class="sftp-chmod-grid" id="chmod-grid">
        <div></div><strong>Read (4)</strong><strong>Write (2)</strong><strong>Exec (1)</strong>
        <span>Owner</span><input type="checkbox" data-bit="256" ${bit(0o400)}><input type="checkbox" data-bit="128" ${bit(0o200)}><input type="checkbox" data-bit="64" ${bit(0o100)}>
        <span>Group</span><input type="checkbox" data-bit="32" ${bit(0o040)}><input type="checkbox" data-bit="16" ${bit(0o020)}><input type="checkbox" data-bit="8" ${bit(0o010)}>
        <span>Other</span><input type="checkbox" data-bit="4" ${bit(0o004)}><input type="checkbox" data-bit="2" ${bit(0o002)}><input type="checkbox" data-bit="1" ${bit(0o001)}>
      </div>
      ${entry.type==='dir'?'<label class="field checkbox" style="margin-top:10px"><input type="checkbox" name="recursive"> '+vt('Áp dụng đệ quy cho tất cả file/thư mục bên trong','Apply recursively to contents')+'</label>':''}`,
      async form=>{
        await api('vps/machines/'+encodeURIComponent(pane.machineId)+'/sftp/chmod',{
          path:entry.path,
          mode:String(form.get('mode')||'').trim(),
          recursive:form.has('recursive')
        });
        await loadPane(pane,pane.cwd);
      });
    const oct=$('#chmod-octal'),grid=$('#chmod-grid');
    if(oct&&grid){
      const boxes=[...grid.querySelectorAll('input[type="checkbox"]')];
      grid.onchange=()=>{
        const val=boxes.reduce((acc,b)=>acc+(b.checked?Number(b.dataset.bit):0),0);
        oct.value=val.toString(8).padStart(4,'0');
      };
      oct.oninput=()=>{
        const raw=oct.value.trim();
        if(/^[0-7]{3,4}$/.test(raw)){
          const val=parseInt(raw,8);
          for(const b of boxes)b.checked=Boolean(val&Number(b.dataset.bit));
        }
      };
    }
  }

  function renderPane(side,pane,otherPane){
    const tab=getTab();
    const el=document.createElement('article');
    el.className='sftp-pane'+(tab.activeSide===side?' is-active':'');
    const selectedArr=[...pane.selected];
    const firstSelected=selectedArr.length===1?pane.entries.find(e=>e.path===selectedArr[0]):null;
    const arrowDir=side==='left'?'→':'←';
    el.innerHTML=`
      <div class="sftp-pane-head">
        <select class="sftp-host-select" aria-label="${vt('Chọn VPS','Select VPS')}">
          ${servers.map(s=>`<option value="${escapeHTML(s.id)}" ${s.id===pane.machineId?'selected':''}>${escapeHTML(s.name)}</option>`).join('')}
        </select>
        <div class="sftp-nav-btns">
          <button type="button" class="button small sftp-home" title="${vt('Thư mục Home','Home directory')}">~</button>
          <button type="button" class="button small sftp-up" title="${vt('Lên 1 cấp','Parent directory')}">..</button>
          <button type="button" class="button small sftp-refresh" title="${vt('Làm mới','Refresh')}">↻</button>
        </div>
        <form class="sftp-path-form">
          <input type="text" class="sftp-path-input mono" value="${escapeHTML(pane.cwd||'~')}" aria-label="${vt('Đường dẫn','Path')}">
        </form>
      </div>
      <div class="sftp-pane-tools">
        <button type="button" class="button small sftp-mkdir" data-tone="create">+ ${vt('Thư mục','Folder')}</button>
        <button type="button" class="button small sftp-touch">+ ${vt('File','File')}</button>
        <button type="button" class="button small sftp-upload" data-tone="info">↑ ${vt('Tải lên','Upload')}</button>
        <input type="file" class="sftp-file-input" multiple hidden>
        <button type="button" class="button small sftp-download" ${selectedArr.length?'':'disabled'}>↓ ${vt('Tải xuống','Download')}</button>
        ${tab.dualPane?`<button type="button" class="button small sftp-copy-other" data-tone="configure" ${selectedArr.length?'':'disabled'}>${vt('Chép','Copy')} ${arrowDir}</button>`:''}
        ${tab.dualPane?`<button type="button" class="button small sftp-move-other" ${selectedArr.length?'':'disabled'}>${vt('Di chuyển','Move')} ${arrowDir}</button>`:''}
        <button type="button" class="button small sftp-edit" ${firstSelected&&firstSelected.type!=='dir'?'':'disabled'}>${vt('Sửa','Edit')}</button>
        <button type="button" class="button small sftp-rename" ${firstSelected?'':'disabled'}>${vt('Đổi tên','Rename')}</button>
        <button type="button" class="button small sftp-chmod" ${firstSelected?'':'disabled'}>Chmod</button>
        <button type="button" class="button small sftp-delete" data-tone="remove" ${selectedArr.length?'':'disabled'}>${vt('Xóa','Delete')}</button>
        <label class="sftp-hidden-toggle"><input type="checkbox" ${pane.showHidden?'checked':''}> ${vt('File ẩn','Hidden')}</label>
        <input type="search" class="sftp-filter" value="${escapeHTML(pane.filter)}" placeholder="${vt('Lọc…','Filter…')}">
      </div>
      <div class="sftp-pane-body"></div>
      <div class="sftp-pane-foot">
        <span>${pane.entries.length} ${vt('mục','items')}</span>
        <span>${selectedArr.length?selectedArr.length+' '+vt('đã chọn','selected'):escapeHTML(pane.cwd||'')}</span>
      </div>
    `;

    el.onpointerdown=()=>{
      if(tab.activeSide!==side){tab.activeSide=side;for(const p of stageEl.querySelectorAll('.sftp-pane'))p.classList.toggle('is-active',p===el);}
    };
    el.querySelector('.sftp-host-select').onchange=e=>{pane.machineId=e.target.value;pane.cwd='';loadPane(pane,'');};
    el.querySelector('.sftp-home').onclick=()=>loadPane(pane,'~');
    el.querySelector('.sftp-up').onclick=()=>loadPane(pane,sftpParentPath(pane.cwd));
    el.querySelector('.sftp-refresh').onclick=()=>loadPane(pane,pane.cwd);
    el.querySelector('.sftp-path-form').onsubmit=e=>{
      e.preventDefault();
      loadPane(pane,el.querySelector('.sftp-path-input').value.trim()||'~');
    };
    el.querySelector('.sftp-hidden-toggle input').onchange=e=>{pane.showHidden=e.target.checked;loadPane(pane,pane.cwd);};
    el.querySelector('.sftp-filter').oninput=e=>{pane.filter=e.target.value;renderBody();};

    const fileInput=el.querySelector('.sftp-file-input');
    el.querySelector('.sftp-upload').onclick=()=>fileInput.click();
    fileInput.onchange=()=>{if(fileInput.files.length)uploadFilesToPane(pane,[...fileInput.files]);fileInput.value='';};

    el.querySelector('.sftp-mkdir').onclick=()=>{
      modal(vt('Tạo thư mục mới','New folder'),'<label class="field">'+vt('Tên thư mục','Folder name')+'<input name="name" required autofocus></label>',async form=>{
        const name=String(form.get('name')||'').trim();
        if(!name||name.includes('/'))throw new Error(vt('Tên thư mục không hợp lệ.','Invalid folder name.'));
        await api('vps/machines/'+encodeURIComponent(pane.machineId)+'/sftp/mkdir',{path:sftpJoinPath(pane.cwd,name)});
        await loadPane(pane,pane.cwd);
      });
    };
    el.querySelector('.sftp-touch').onclick=()=>{
      modal(vt('Tạo file mới','New file'),'<label class="field">'+vt('Tên file','File name')+'<input name="name" required autofocus></label>',async form=>{
        const name=String(form.get('name')||'').trim();
        if(!name||name.includes('/'))throw new Error(vt('Tên file không hợp lệ.','Invalid file name.'));
        await api('vps/machines/'+encodeURIComponent(pane.machineId)+'/sftp/touch',{path:sftpJoinPath(pane.cwd,name)});
        await loadPane(pane,pane.cwd);
      });
    };
    el.querySelector('.sftp-download').onclick=()=>{
      if(!selectedArr.length)return;
      if(previewMode){
        modal(vt('Chế độ xem thử','Preview mode'),'<p>'+vt('Đang xem dữ liệu minh họa. Chuyển sang dữ liệu thật để tải file xuống.','Preview mode uses sample data. Switch to live data to download.')+'</p>',async()=>{});
        return;
      }
      const q=selectedArr.map(p=>'paths='+encodeURIComponent(p)).join('&');
      const wsTarget=window.zmWorkspaceHelper?window.zmWorkspaceHelper.getTarget():'';
      window.open('/api/vps/machines/'+encodeURIComponent(pane.machineId)+'/sftp/download?'+q+(wsTarget?'&workspace_user='+encodeURIComponent(wsTarget):''),'_blank');
    };
    const copyBtn=el.querySelector('.sftp-copy-other');
    if(copyBtn)copyBtn.onclick=()=>transferBetweenPanes(pane,otherPane,selectedArr,'copy');
    const moveBtn=el.querySelector('.sftp-move-other');
    if(moveBtn)moveBtn.onclick=()=>{
      modal(vt('Di chuyển sang khung bên','Move to other pane'),
        '<p>'+vt('Di chuyển ','Move ')+'<strong>'+selectedArr.length+'</strong>'+vt(' mục sang ',' item(s) to ')+'<code>'+escapeHTML(serverName(otherPane.machineId)+':'+(otherPane.cwd||'~'))+'</code>?</p>',
        async()=>{await transferBetweenPanes(pane,otherPane,selectedArr,'move');});
    };
    el.querySelector('.sftp-edit').onclick=()=>{if(firstSelected)openEditorModal(pane,firstSelected);};
    el.querySelector('.sftp-rename').onclick=()=>{
      if(!firstSelected)return;
      modal(vt('Đổi tên','Rename'),'<label class="field">'+vt('Tên mới','New name')+'<input name="name" value="'+escapeHTML(firstSelected.name)+'" required autofocus></label>',async form=>{
        const name=String(form.get('name')||'').trim();
        if(!name||name.includes('/'))throw new Error(vt('Tên không hợp lệ.','Invalid name.'));
        await api('vps/machines/'+encodeURIComponent(pane.machineId)+'/sftp/rename',{
          old_path:firstSelected.path,
          new_path:sftpJoinPath(sftpParentPath(firstSelected.path),name)
        });
        await loadPane(pane,pane.cwd);
      });
    };
    el.querySelector('.sftp-chmod').onclick=()=>{if(firstSelected)openChmodModal(pane,firstSelected);};
    el.querySelector('.sftp-delete').onclick=()=>{
      if(!selectedArr.length)return;
      modal(vt('Xóa file / thư mục','Delete items'),
        '<p>'+vt('Bạn chắc chắn muốn xóa ','Delete ')+'<strong>'+selectedArr.length+'</strong>'+vt(' mục đã chọn? Thao tác này không thể hoàn tác.',' selected item(s)? This cannot be undone.')+'</p>'
        +'<pre class="mono" style="max-height:140px;overflow:auto">'+escapeHTML(selectedArr.join('\n'))+'</pre>',
        async()=>{
          await api('vps/machines/'+encodeURIComponent(pane.machineId)+'/sftp/delete',{paths:selectedArr});
          await loadPane(pane,pane.cwd);
        });
    };

    const body=el.querySelector('.sftp-pane-body');
    body.addEventListener('dragover',e=>{e.preventDefault();body.classList.add('is-dragover');});
    body.addEventListener('dragleave',()=>body.classList.remove('is-dragover'));
    body.addEventListener('drop',e=>{
      e.preventDefault();
      body.classList.remove('is-dragover');
      if(e.dataTransfer?.files?.length){
        uploadFilesToPane(pane,[...e.dataTransfer.files]);
        return;
      }
      const raw=e.dataTransfer?.getData('application/x-zm-sftp');
      if(raw){
        try{
          const payload=JSON.parse(raw);
          if(payload.side!==side&&Array.isArray(payload.paths)&&payload.paths.length){
            transferBetweenPanes(otherPane,pane,payload.paths,'copy');
          }
        }catch{}
      }
    });

    function renderBody(){
      if(pane.loading){
        body.innerHTML='<div class="sftp-state"><span class="spinner"></span> '+vt('Đang tải thư mục…','Loading directory…')+'</div>';
        return;
      }
      if(pane.error){
        body.innerHTML='<div class="sftp-state"><div class="callout error">'+escapeHTML(pane.error)+'</div></div>';
        return;
      }
      const list=sortedEntries(pane);
      const hasParent=Boolean(pane.cwd&&pane.cwd!=='/');
      if(!list.length&&!hasParent){
        body.innerHTML='<div class="sftp-state">'+vt('Thư mục trống. Kéo thả file vào đây để tải lên.','Empty directory. Drag & drop files here to upload.')+'</div>';
        return;
      }
      const sortArrow=col=>pane.sortBy===col?(pane.sortDir==='asc'?' ↑':' ↓'):'';
      const table=document.createElement('table');
      table.className='sftp-table';
      table.innerHTML=`
        <thead><tr>
          <th style="width:28px"><input type="checkbox" class="sftp-chk-all"></th>
          <th data-sort="name" class="is-sortable">${vt('Tên','Name')}${sortArrow('name')}</th>
          <th data-sort="size" class="is-sortable" style="width:82px">${vt('Kích thước','Size')}${sortArrow('size')}</th>
          <th style="width:66px">${vt('Quyền','Perms')}</th>
          <th data-sort="mtime" class="is-sortable" style="width:126px">${vt('Cập nhật','Modified')}${sortArrow('mtime')}</th>
        </tr></thead>
        <tbody></tbody>
      `;
      const chkAll=table.querySelector('.sftp-chk-all');
      chkAll.checked=list.length>0&&list.every(e=>pane.selected.has(e.path));
      chkAll.onchange=()=>{
        if(chkAll.checked)list.forEach(e=>pane.selected.add(e.path));
        else pane.selected.clear();
        renderStage();
      };
      for(const th of table.querySelectorAll('th.is-sortable')){
        th.onclick=()=>{
          const col=th.dataset.sort;
          if(pane.sortBy===col)pane.sortDir=pane.sortDir==='asc'?'desc':'asc';
          else{pane.sortBy=col;pane.sortDir='asc';}
          renderBody();
        };
      }
      const tbody=table.querySelector('tbody');
      if(hasParent){
        const upTr=document.createElement('tr');
        upTr.className='sftp-parent-row';
        upTr.title=vt('Nhấp đúp để quay về thư mục cha','Double-click to go to parent directory');
        upTr.innerHTML='<td></td><td class="sftp-name-cell"><span class="sftp-ico is-dir">📁</span><span>..</span></td><td class="mono">—</td><td class="mono">—</td><td class="mono">—</td>';
        upTr.ondblclick=()=>loadPane(pane,sftpParentPath(pane.cwd));
        tbody.append(upTr);
      }
      if(!list.length){
        const emptyTr=document.createElement('tr');
        emptyTr.innerHTML='<td colspan="5" class="sftp-empty-row">'+vt('Thư mục trống. Kéo thả file vào đây để tải lên.','Empty directory. Drag & drop files here to upload.')+'</td>';
        tbody.append(emptyTr);
      }
      for(const entry of list){
        const tr=document.createElement('tr');
        tr.draggable=true;
        if(pane.selected.has(entry.path))tr.classList.add('is-selected');
        tr.innerHTML=`
          <td><input type="checkbox" class="sftp-chk" ${pane.selected.has(entry.path)?'checked':''}></td>
          <td class="sftp-name-cell">${sftpIcon(entry)}<span>${escapeHTML(entry.name)}</span></td>
          <td class="mono">${entry.type==='dir'?'—':sftpFmtBytes(entry.size)}</td>
          <td class="mono">${escapeHTML(entry.octal)}</td>
          <td class="mono">${sftpFmtTime(entry.mtime)}</td>
        `;
        tr.querySelector('.sftp-chk').onchange=e=>{
          if(e.target.checked)pane.selected.add(entry.path);
          else pane.selected.delete(entry.path);
          renderStage();
        };
        tr.onclick=e=>{
          if(e.target.closest('input'))return;
          if(e.ctrlKey||e.metaKey){
            if(pane.selected.has(entry.path))pane.selected.delete(entry.path);
            else pane.selected.add(entry.path);
          }else{
            pane.selected.clear();
            pane.selected.add(entry.path);
          }
          renderStage();
        };
        tr.ondblclick=()=>{
          if(entry.type==='dir')loadPane(pane,entry.path);
          else openEditorModal(pane,entry);
        };
        tr.ondragstart=e=>{
          const paths=pane.selected.has(entry.path)?[...pane.selected]:[entry.path];
          e.dataTransfer?.setData('application/x-zm-sftp',JSON.stringify({side,paths}));
        };
        tbody.append(tr);
      }
      body.replaceChildren(table);
    }
    renderBody();
    return el;
  }

  function renderTabs(){
    tabsEl.replaceChildren();
    for(const t of sftpTabs){
      const label=t.dualPane?(serverName(t.left.machineId)+' ↔ '+serverName(t.right.machineId)):serverName(t.left.machineId);
      const btn=document.createElement('div');
      btn.className='sftp-tab'+(t.id===activeSftpTabId?' active':'');
      btn.innerHTML='<span>'+escapeHTML(label)+'</span><button type="button" class="sftp-tab-close" aria-label="Đóng">×</button>';
      btn.onclick=e=>{
        if(e.target.closest('.sftp-tab-close')){
          if(sftpTabs.length===1)return;
          const idx=sftpTabs.findIndex(x=>x.id===t.id);
          sftpTabs.splice(idx,1);
          if(activeSftpTabId===t.id)activeSftpTabId=sftpTabs[Math.max(0,idx-1)].id;
          renderTabs();renderStage();
          return;
        }
        activeSftpTabId=t.id;
        renderTabs();renderStage();
      };
      tabsEl.append(btn);
    }
  }

  function renderStage(){
    const tab=getTab();
    $('#sftp-toggle-dual').textContent=tab.dualPane?vt('Chế độ 1 khung','Single-pane'):vt('Chế độ 2 khung','Dual-pane');
    $('#sftp-swap').hidden=!tab.dualPane;
    stageEl.className='sftp-stage '+(tab.dualPane?'is-dual':'is-single');
    stageEl.replaceChildren();
    stageEl.append(renderPane('left',tab.left,tab.right));
    if(tab.dualPane)stageEl.append(renderPane('right',tab.right,tab.left));
  }

  $('#sftp-new-tab').onclick=()=>{
    const tab=createSftpTab(servers,$('#hosts')?.value||servers[0].id);
    renderTabs();
    loadPane(tab.left,'');
    if(tab.dualPane)loadPane(tab.right,'');
  };
  $('#sftp-toggle-dual').onclick=()=>{
    const tab=getTab();
    tab.dualPane=!tab.dualPane;
    renderTabs();
    renderStage();
    if(tab.dualPane&&!tab.right.cwd)loadPane(tab.right,'');
  };
  $('#sftp-swap').onclick=()=>{
    const tab=getTab();
    const tmp=tab.left;tab.left=tab.right;tab.right=tmp;
    renderTabs();renderStage();
  };
  $('#sftp-xfer-clear').onclick=()=>{
    for(let i=sftpTransfers.length-1;i>=0;i--){
      if(sftpTransfers[i].status!=='running')sftpTransfers.splice(i,1);
    }
    renderDrawer();
  };
  $('#sftp-xfer-toggle').onclick=()=>{
    sftpDrawerOpen=!sftpDrawerOpen;
    drawerBody.hidden=!sftpDrawerOpen;
    $('#sftp-xfer-toggle').textContent=sftpDrawerOpen?vt('Thu gọn','Collapse'):vt('Mở rộng','Expand');
  };

  renderTabs();
  renderDrawer();
  const activeTab=getTab();
  if(!activeTab.left.cwd&&!activeTab.left.loading)loadPane(activeTab.left,'');
  if(activeTab.dualPane&&!activeTab.right.cwd&&!activeTab.right.loading)loadPane(activeTab.right,'');
  renderStage();
}
