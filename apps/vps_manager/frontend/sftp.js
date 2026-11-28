// Termius-style multi-pane, multi-tab SFTP file manager with inline editor, chmod matrix, drag-drop, and transfer queue.
const sftpTabs=[];
let activeSftpTabId='',sftpTabSeq=0,sftpPaneSeq=0,sftpXferSeq=0;
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

function sftpOsMeta(s){
  const hay=[s.os,s.name,s.host,s.user].filter(Boolean).join(' ').toLowerCase();
  if(/win|windows|administrator/.test(hay)){
    return {
      key:'windows',label:'Windows',color:'#0284c7',bg:'#e0f2fe',
      svg:'<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M3 5.5 10.5 4.4v7.1H3V5.5zm8.5-1.2L21 3v8.5h-9.5V4.3zM3 12.5h7.5v7.1L3 18.5v-6zm8.5 0H21V21l-9.5-1.3v-7.2z"/></svg>'
    };
  }
  if(/redhat|rhel|centos|rocky|alma|fedora|oracle|opc|ec2-user/.test(hay)){
    return {
      key:'redhat',label:/oracle|opc/.test(hay)?'Oracle/RHEL':'Red Hat',color:'#dc2626',bg:'#fee2e2',
      svg:'<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M5 14c1.5-4.5 4-7 7-7s5.5 2.5 7 7"/><path d="M3 15c2.5 2 5.5 3 9 3s6.5-1 9-3"/><path d="M9 11.5c1.8-.6 4.2-.6 6 0"/></svg>'
    };
  }
  if(/ubuntu/.test(hay)){
    return {
      key:'ubuntu',label:'Ubuntu',color:'#ea580c',bg:'#ffedd5',
      svg:'<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="5"/><circle cx="12" cy="4" r="1.5" fill="currentColor"/><circle cx="5.2" cy="16" r="1.5" fill="currentColor"/><circle cx="18.8" cy="16" r="1.5" fill="currentColor"/></svg>'
    };
  }
  if(/debian/.test(hay)){
    return {
      key:'debian',label:'Debian',color:'#be123c',bg:'#ffe4e6',
      svg:'<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M12 12a2 2 0 1 0-2-2c0 2.2 1.8 4 4 4a5 5 0 0 0 5-5c0-3.5-3-6-7-6-4.5 0-8 3.5-8 8 0 5 3.8 9 9 9"/></svg>'
    };
  }
  if(s.mode==='local'||/mac|darwin/.test(hay)){
    return {
      key:'local',label:'Local',color:'#475569',bg:'#f1f5f9',
      svg:'<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="12" rx="2"/><path d="M2 20h20"/></svg>'
    };
  }
  return {
    key:'linux',label:'Linux',color:'#15803d',bg:'#dcfce7',
    svg:'<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="m7 10 3 2.5L7 15"/><path d="M13 15h4"/></svg>'
  };
}

function buildSftpAutoRects(count){
  if(count<=0)return [];
  if(count===1)return [{x:0,y:0,w:100,h:100}];
  const cols=count<=4?2:3;
  const rows=Math.ceil(count/cols);
  const rects=[];
  for(let i=0;i<count;i++){
    const r=Math.floor(i/cols),c=i%cols;
    const rowCount=(r===rows-1&&count%cols!==0)?(count%cols):cols;
    const w=100/rowCount,h=100/rows;
    rects.push({x:c*w,y:r*h,w,h});
  }
  return rects;
}

function createSftpPaneState(machineId,rect){
  return {
    id:'sftp-pane-'+(++sftpPaneSeq),
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
    error:'',
    el:null,
    rect:rect?{...rect}:{x:0,y:0,w:50,h:100}
  };
}

function createSftpTab(servers,primaryOrList){
  const id='sftp-tab-'+(++sftpTabSeq);
  let panes;
  if(Array.isArray(primaryOrList)&&primaryOrList.length){
    const rects=buildSftpAutoRects(primaryOrList.length);
    panes=primaryOrList.map((mid,i)=>createSftpPaneState(mid,rects[i]));
  }else{
    const first=primaryOrList||'';
    panes=[
      createSftpPaneState(first,{x:0,y:0,w:50,h:100}),
      createSftpPaneState('',{x:50,y:0,w:50,h:100})
    ];
  }
  const tab={
    id,
    title:'',
    dualPane:true,
    activePaneId:panes[0]?.id||'',
    maximizedPaneId:'',
    panes
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
  const byHost=(a,b)=>String(a.name||a.host||'').localeCompare(String(b.name||b.host||''),undefined,{numeric:true,sensitivity:'base'});
  servers.sort((a,b)=>(Number(Boolean(a.profile_id))-Number(Boolean(b.profile_id)))||byHost(a,b));
  if(!servers.some(s=>s.id==='__local__'||s.mode==='local')){
    servers.unshift({id:'__local__',name:vt('Local (máy hiện tại)','Local (this machine)'),mode:'local',host:'localhost'});
  }
  const currentHost=$('#hosts')?.value||servers.find(s=>s.id!=='__local__')?.id||servers[0]?.id||'';
  if(sftpPendingMachineId){
    const targetId=sftpPendingMachineId;
    sftpPendingMachineId='';
    createSftpTab(servers,targetId);
  }else if(!sftpTabs.length){
    createSftpTab(servers,'');
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
        <button type="button" class="button small" id="sftp-tile" title="${vt('Xếp đều các khung thành lưới','Auto-tile panes into grid')}">⊞</button>
        <button type="button" class="button small" id="sftp-fullscreen" title="${vt('Toàn màn hình','Fullscreen')}">⛶ ${vt('Toàn màn hình','Fullscreen')}</button>
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
      const prevCwd=pane.cwd;
      pane.cwd=res.cwd;
      pane.home=res.home||res.cwd;
      pane.entries=res.entries||[];
      pane.selected.clear();
      if(prevCwd&&res.cwd!==prevCwd)pane.filter='';
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

  async function pollTransferJob(xfer,jobId,onSucceeded){
    xfer.serverTransferId=jobId;
    for(let i=0;i<1800;i++){
      const st=await api('vps/sftp/transfers/'+encodeURIComponent(jobId));
      xfer.loaded=st.bytes_transferred||0;
      xfer.total=st.total_bytes||1;
      xfer.detail=(st.current_file?st.current_file+' · ':'')+sftpFmtBytes(xfer.loaded)+' / '+sftpFmtBytes(st.total_bytes||0);
      if(st.status==='succeeded'||st.status==='failed'||st.status==='cancelled'){
        xfer.status=st.status;
        if(st.error)xfer.detail=st.error;
        renderDrawer();
        if(st.status==='succeeded'&&onSucceeded)onSucceeded();
        return;
      }
      renderDrawer();
      await new Promise(r=>setTimeout(r,500));
    }
  }

  async function transferBetweenPanes(srcPane,dstPane,paths,op,{awaitDone=true}={}){
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
      const poll=pollTransferJob(xfer,job.id,()=>{
        loadPane(dstPane,dstPane.cwd);
        if(op==='move')loadPane(srcPane,srcPane.cwd);
      });
      if(awaitDone)await poll;
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

  function applySftpRect(pane,maximized,single){
    if(!pane?.el)return;
    if(maximized||single){
      pane.el.style.left='0%';pane.el.style.top='0%';pane.el.style.width='100%';pane.el.style.height='100%';
    }else{
      const r=pane.rect||{x:0,y:0,w:50,h:100};
      pane.el.style.left=r.x+'%';pane.el.style.top=r.y+'%';pane.el.style.width=r.w+'%';pane.el.style.height=r.h+'%';
    }
  }

  function startSftpPointerOp(e,pane,tab,mode){
    if(e.button!==0||e.target.closest('button,select,input'))return;
    if(!tab||tab.panes.length<=1||tab.maximizedPaneId===pane.id)return;
    e.preventDefault();
    const canvas=stageEl.querySelector('.sftp-canvas');
    if(!canvas)return;
    const stageRect=canvas.getBoundingClientRect();
    const startX=e.clientX,startY=e.clientY;
    const orig={...pane.rect};
    const origRight=orig.x+orig.w,origBottom=orig.y+orig.h;
    const others=tab.panes.filter(p=>p.id!==pane.id);
    const linkedE=mode.includes('e')?others.filter(p=>Math.abs(p.rect.x-origRight)<2&&p.rect.y<origBottom-1&&(p.rect.y+p.rect.h)>orig.y+1).map(p=>({p,orig:{...p.rect}})):[];
    const linkedW=mode.includes('w')?others.filter(p=>Math.abs((p.rect.x+p.rect.w)-orig.x)<2&&p.rect.y<origBottom-1&&(p.rect.y+p.rect.h)>orig.y+1).map(p=>({p,orig:{...p.rect}})):[];
    const linkedS=mode.includes('s')?others.filter(p=>Math.abs(p.rect.y-origBottom)<2&&p.rect.x<origRight-1&&(p.rect.x+p.rect.w)>orig.x+1).map(p=>({p,orig:{...p.rect}})):[];
    const linkedN=mode.includes('n')?others.filter(p=>Math.abs((p.rect.y+p.rect.h)-orig.y)<2&&p.rect.x<origRight-1&&(p.rect.x+p.rect.w)>orig.x+1).map(p=>({p,orig:{...p.rect}})):[];
    const minW=18,minH=22;
    const maxDxE=linkedE.length?Math.min(100-origRight,...linkedE.map(item=>item.orig.w-minW)):(100-origRight),minDxE=minW-orig.w;
    const minDxW=linkedW.length?Math.max(-orig.x,...linkedW.map(item=>minW-item.orig.w)):(-orig.x),maxDxW=orig.w-minW;
    const maxDyS=linkedS.length?Math.min(100-origBottom,...linkedS.map(item=>item.orig.h-minH)):(100-origBottom),minDyS=minH-orig.h;
    const minDyN=linkedN.length?Math.max(-orig.y,...linkedN.map(item=>minH-item.orig.h)):(-orig.y),maxDyN=orig.h-minH;
    pane.el.classList.add('is-moving');
    const onMove=ev=>{
      const rawDx=((ev.clientX-startX)/Math.max(stageRect.width,1))*100;
      const rawDy=((ev.clientY-startY)/Math.max(stageRect.height,1))*100;
      if(mode==='move'){
        pane.rect.x=Math.max(0,Math.min(100-orig.w,orig.x+rawDx));
        pane.rect.y=Math.max(0,Math.min(100-orig.h,orig.y+rawDy));
      }else{
        if(mode.includes('e')){
          const dx=Math.max(minDxE,Math.min(maxDxE,rawDx));
          pane.rect.w=orig.w+dx;
          for(const item of linkedE){item.p.rect.x=item.orig.x+dx;item.p.rect.w=item.orig.w-dx;applySftpRect(item.p,false,false);}
        }
        if(mode.includes('w')){
          const dx=Math.max(minDxW,Math.min(maxDxW,rawDx));
          pane.rect.x=orig.x+dx;pane.rect.w=orig.w-dx;
          for(const item of linkedW){item.p.rect.w=item.orig.w+dx;applySftpRect(item.p,false,false);}
        }
        if(mode.includes('s')){
          const dy=Math.max(minDyS,Math.min(maxDyS,rawDy));
          pane.rect.h=orig.h+dy;
          for(const item of linkedS){item.p.rect.y=item.orig.y+dy;item.p.rect.h=item.orig.h-dy;applySftpRect(item.p,false,false);}
        }
        if(mode.includes('n')){
          const dy=Math.max(minDyN,Math.min(maxDyN,rawDy));
          pane.rect.y=orig.y+dy;pane.rect.h=orig.h-dy;
          for(const item of linkedN){item.p.rect.h=item.orig.h+dy;applySftpRect(item.p,false,false);}
        }
      }
      applySftpRect(pane,false,false);
    };
    const onUp=()=>{
      pane.el?.classList.remove('is-moving');
      window.removeEventListener('pointermove',onMove);
      window.removeEventListener('pointerup',onUp);
    };
    window.addEventListener('pointermove',onMove);
    window.addEventListener('pointerup',onUp);
  }

  function pickTargetPaneAndTransfer(srcPane,connectedOthers,paths,op){
    if(connectedOthers.length===1){
      const dst=connectedOthers[0];
      if(op==='move'){
        modal(vt('Di chuyển sang khung khác','Move to another pane'),
          '<p>'+vt('Di chuyển ','Move ')+'<strong>'+paths.length+'</strong>'+vt(' mục sang ',' item(s) to ')+'<code>'+escapeHTML(serverName(dst.machineId)+':'+(dst.cwd||'~'))+'</code>?</p>',
          async()=>{await transferBetweenPanes(srcPane,dst,paths,'move',{awaitDone:false});});
      }else{
        transferBetweenPanes(srcPane,dst,paths,'copy',{awaitDone:false});
      }
      return;
    }
    const opts=connectedOthers.map(p=>`<option value="${escapeHTML(p.id)}">${escapeHTML(serverName(p.machineId)+' · '+(p.cwd||'~'))}</option>`).join('');
    modal(op==='move'?vt('Chọn khung đích để di chuyển','Select target pane to move'):vt('Chọn khung đích để chép','Select target pane to copy'),
      `<label class="field">${vt('Khung đang mở','Open pane')}<select name="pane_id">${opts}</select></label>`,
      async form=>{
        const dst=connectedOthers.find(p=>p.id===form.get('pane_id'));
        if(dst)await transferBetweenPanes(srcPane,dst,paths,op,{awaitDone:false});
      });
  }

  function renderPane(pane,tab){
    const isMax=tab.maximizedPaneId===pane.id;
    const single=!tab.dualPane||tab.panes.length<=1;
    const el=document.createElement('article');
    el.className='sftp-pane'+(tab.activePaneId===pane.id?' is-active':'')+(isMax?' is-maximized':'');
    pane.el=el;
    applySftpRect(pane,isMax,single);
    const connected=Boolean(pane.machineId);
    const connectedOthers=tab.dualPane?tab.panes.filter(p=>p.id!==pane.id&&p.machineId):[];
    const firstOther=connectedOthers[0]||tab.panes.find(p=>p.id!==pane.id)||null;
    const selectedArr=[...pane.selected];
    const firstSelected=selectedArr.length===1?pane.entries.find(e=>e.path===selectedArr[0]):null;
    el.innerHTML=`
      <div class="sftp-pane-head" title="${vt('Kéo tiêu đề để di chuyển khung tự do','Drag header to move pane freely')}">
        <span class="sftp-drag-grip" aria-hidden="true">⋮⋮</span>
        <select class="sftp-host-select" aria-label="${vt('Chọn VPS','Select VPS')}">
          <option value="" ${!connected?'selected':''}>${vt('Chọn máy chủ…','Select host…')}</option>
          ${servers.map(s=>`<option value="${escapeHTML(s.id)}" ${s.id===pane.machineId?'selected':''}>${escapeHTML(s.name)}</option>`).join('')}
        </select>
        <div class="sftp-nav-btns">
          <button type="button" class="button small sftp-home" ${connected?'':'disabled'} title="${vt('Thư mục Home','Home directory')}">~</button>
          <button type="button" class="button small sftp-up" ${connected?'':'disabled'} title="${vt('Lên 1 cấp','Parent directory')}">..</button>
          <button type="button" class="button small sftp-refresh" ${connected?'':'disabled'} title="${vt('Làm mới','Refresh')}">↻</button>
        </div>
        <form class="sftp-path-form">
          <input type="text" class="sftp-path-input mono" ${connected?'':'disabled'} value="${escapeHTML(connected?(pane.cwd||'~'):'')}" placeholder="${connected?'':vt('Chưa kết nối','Not connected')}" aria-label="${vt('Đường dẫn','Path')}">
        </form>
        <button type="button" class="button small sftp-pane-max" title="${isMax?vt('Thu về vị trí cũ','Restore size'):vt('Phóng to khung này','Maximize pane')}">${isMax?'🗗':'⛶'}</button>
        <button type="button" class="button small sftp-pane-close" ${single?'hidden':''} title="${vt('Đóng khung này','Close pane')}">×</button>
      </div>
      <div class="sftp-pane-tools">
        <button type="button" class="button small sftp-mkdir" data-tone="create" ${connected?'':'disabled'}>+ ${vt('Thư mục','Folder')}</button>
        <button type="button" class="button small sftp-touch" ${connected?'':'disabled'}>+ ${vt('File','File')}</button>
        <button type="button" class="button small sftp-upload" data-tone="info" ${connected?'':'disabled'}>↑ ${vt('Tải lên','Upload')}</button>
        <input type="file" class="sftp-file-input" multiple hidden>
        <button type="button" class="button small sftp-download" ${selectedArr.length?'':'disabled'}>↓ ${vt('Tải xuống','Download')}</button>
        <button type="button" class="button small sftp-copy-other" data-tone="configure" ${selectedArr.length&&connectedOthers.length?'':'disabled'}>${vt('Chép sang…','Copy to…')}</button>
        <button type="button" class="button small sftp-move-other" ${selectedArr.length&&connectedOthers.length?'':'disabled'}>${vt('Di chuyển…','Move to…')}</button>
        <button type="button" class="button small sftp-edit" ${firstSelected&&firstSelected.type!=='dir'?'':'disabled'}>${vt('Sửa','Edit')}</button>
        <button type="button" class="button small sftp-rename" ${firstSelected?'':'disabled'}>${vt('Đổi tên','Rename')}</button>
        <button type="button" class="button small sftp-chmod" ${firstSelected?'':'disabled'}>Chmod</button>
        <button type="button" class="button small sftp-delete" data-tone="remove" ${selectedArr.length?'':'disabled'}>${vt('Xóa','Delete')}</button>
        <label class="sftp-hidden-toggle"><input type="checkbox" ${pane.showHidden?'checked':''} ${connected?'':'disabled'}> ${vt('File ẩn','Hidden')}</label>
        <input type="search" class="sftp-filter" ${connected?'':'disabled'} value="${escapeHTML(pane.filter)}" placeholder="${vt('Lọc…','Filter…')}">
      </div>
      <div class="sftp-pane-body"></div>
      <div class="sftp-pane-foot">
        <span>${connected?(pane.entries.length+' '+vt('mục','items')):vt('Chưa kết nối','Not connected')}</span>
        <span>${selectedArr.length?selectedArr.length+' '+vt('đã chọn','selected'):escapeHTML(pane.cwd||'')}</span>
      </div>
      <div class="sftp-resize-n"></div>
      <div class="sftp-resize-w"></div>
      <div class="sftp-resize-e"></div>
      <div class="sftp-resize-s"></div>
      <div class="sftp-resize-se" title="${vt('Kéo góc để đổi kích thước','Drag corner to resize')}">◢</div>
    `;

    el.onpointerdown=()=>{
      if(tab.activePaneId!==pane.id){tab.activePaneId=pane.id;for(const p of stageEl.querySelectorAll('.sftp-pane'))p.classList.toggle('is-active',p===el);}
    };
    el.querySelector('.sftp-pane-head').addEventListener('pointerdown',e=>startSftpPointerOp(e,pane,tab,'move'));
    el.querySelector('.sftp-resize-n').addEventListener('pointerdown',e=>startSftpPointerOp(e,pane,tab,'n'));
    el.querySelector('.sftp-resize-w').addEventListener('pointerdown',e=>startSftpPointerOp(e,pane,tab,'w'));
    el.querySelector('.sftp-resize-e').addEventListener('pointerdown',e=>startSftpPointerOp(e,pane,tab,'e'));
    el.querySelector('.sftp-resize-s').addEventListener('pointerdown',e=>startSftpPointerOp(e,pane,tab,'s'));
    el.querySelector('.sftp-resize-se').addEventListener('pointerdown',e=>startSftpPointerOp(e,pane,tab,'se'));
    el.querySelector('.sftp-pane-max').onclick=e=>{
      e.stopPropagation();
      tab.maximizedPaneId=tab.maximizedPaneId===pane.id?'':pane.id;
      tab.activePaneId=pane.id;
      renderStage();
    };
    el.querySelector('.sftp-pane-close').onclick=e=>{
      e.stopPropagation();
      if(tab.panes.length<=1)return;
      tab.panes=tab.panes.filter(p=>p.id!==pane.id);
      if(tab.maximizedPaneId===pane.id)tab.maximizedPaneId='';
      if(tab.activePaneId===pane.id)tab.activePaneId=tab.panes[0]?.id||'';
      const rects=buildSftpAutoRects(tab.panes.length);
      tab.panes.forEach((p,i)=>{p.rect={...rects[i]};});
      renderTabs();renderStage();
    };
    el.querySelector('.sftp-host-select').onchange=e=>{
      pane.machineId=e.target.value;
      pane.cwd='';
      pane.filter='';
      pane.entries=[];
      pane.selected.clear();
      pane.error='';
      if(pane.machineId)loadPane(pane,'');
      else{renderTabs();renderStage();}
    };
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
    el.querySelector('.sftp-copy-other').onclick=()=>pickTargetPaneAndTransfer(pane,connectedOthers,selectedArr,'copy');
    el.querySelector('.sftp-move-other').onclick=()=>pickTargetPaneAndTransfer(pane,connectedOthers,selectedArr,'move');
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
          const srcPane=tab.panes.find(p=>p.id===payload.paneId);
          if(srcPane&&srcPane.id!==pane.id&&Array.isArray(payload.paths)&&payload.paths.length){
            transferBetweenPanes(srcPane,pane,payload.paths,'copy');
          }
        }catch{}
      }
    });

    function renderBody(){
      if(!pane.machineId){
        body.innerHTML=`
          <div class="sftp-connect-empty">
            <div class="sftp-connect-icon" aria-hidden="true">
              <svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor"><path d="M3 6a2 2 0 0 1 2-2h4.6l2 2H19a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6z"/></svg>
            </div>
            <h3>${vt('Kết nối máy chủ','Connect to host')}</h3>
            <p>${vt('Chọn một máy chủ đã lưu để bắt đầu quản lý file qua SFTP.','Start by connecting to a saved host to manage your files with SFTP.')}</p>
            <button type="button" class="button small sftp-pick-host">${vt('Chọn máy chủ','Select host')}</button>
          </div>
        `;
        body.querySelector('.sftp-pick-host').onclick=()=>{
          modal(vt('Chọn máy chủ SFTP','Select SFTP host'),
            '<div class="sftp-host-picker-list">'+servers.map(s=>{
              const os=sftpOsMeta(s);
              const addr=s.mode==='ssh'?((s.user||'root')+'@'+(s.host||'')+':'+(s.port||22)):'local';
              const authLabel=s.mode==='local'?'Local':(s.ssh_auth==='password'?vt('Mật khẩu','Password'):'SSH Key');
              return `<button type="button" class="button sftp-host-pick-btn" data-id="${escapeHTML(s.id)}">
                <span class="sftp-os-badge" style="color:${os.color};background:${os.bg}" title="${escapeHTML(os.label)}">${os.svg}</span>
                <span class="sftp-host-pick-main">
                  <strong>${escapeHTML(s.name)}</strong>
                  <small>${escapeHTML(os.label)}${s.profile_id?' · MongoDB':''}</small>
                </span>
                <span class="sftp-host-pick-right">
                  <code class="mono">${escapeHTML(addr)}</code>
                  <span class="badge">${escapeHTML(authLabel)}</span>
                </span>
              </button>`;
            }).join('')+'</div>',
            async()=>{});
          for(const btn of document.querySelectorAll('.sftp-host-pick-btn')){
            btn.onclick=()=>{
              pane.machineId=btn.dataset.id;
              pane.cwd='';
              pane.filter='';
              $('dialog').close();
              loadPane(pane,'');
            };
          }
        };
        return;
      }
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
          e.dataTransfer?.setData('application/x-zm-sftp',JSON.stringify({paneId:pane.id,paths}));
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
      let label='';
      if(t.panes.length===1){
        label=t.panes[0].machineId?serverName(t.panes[0].machineId):vt('Chưa kết nối','Select host');
      }else if(t.panes.length===2){
        const l=t.panes[0].machineId?serverName(t.panes[0].machineId):vt('Chọn máy chủ','Select host');
        const r=t.panes[1].machineId?serverName(t.panes[1].machineId):vt('Chọn máy chủ','Select host');
        label=l+' ↔ '+r;
      }else{
        label=t.panes.length+' '+vt('khung SFTP','SFTP panes');
      }
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
    const addTabBtn=document.createElement('button');
    addTabBtn.type='button';
    addTabBtn.className='sftp-tab-add';
    addTabBtn.title=vt('Mở tab SFTP mới','Open new SFTP tab');
    addTabBtn.textContent='+';
    addTabBtn.onclick=()=>{
      createSftpTab(servers,'');
      renderTabs();
      renderStage();
    };
    tabsEl.append(addTabBtn);
  }

  function renderStage(){
    const tab=getTab();
    const isDual=tab.dualPane!==false;
    $('#sftp-toggle-dual').textContent=isDual?vt('Chế độ 1 khung','Single-pane'):vt('Chế độ 2 khung','Dual-pane');
    $('#sftp-swap').hidden=!isDual||tab.panes.length<2;
    $('#sftp-tile').hidden=!isDual||tab.panes.length<=1;
    stageEl.replaceChildren();
    const canvas=document.createElement('div');
    canvas.className='sftp-canvas';
    const baseList=isDual?tab.panes:[tab.panes[0]];
    const visible=tab.maximizedPaneId?baseList.filter(p=>p.id===tab.maximizedPaneId):baseList;
    for(const p of (visible.length?visible:baseList)){
      canvas.append(renderPane(p,tab));
    }
    stageEl.append(canvas);
  }

  $('#sftp-new-tab').onclick=()=>{
    const tab=createSftpTab(servers,'');
    renderTabs();
    renderStage();
  };
  $('#sftp-toggle-dual').onclick=()=>{
    const tab=getTab();
    tab.dualPane=!(tab.dualPane!==false);
    tab.maximizedPaneId='';
    renderTabs();
    renderStage();
    if(tab.dualPane&&tab.panes[1]?.machineId&&!tab.panes[1].cwd)loadPane(tab.panes[1],'');
  };
  $('#sftp-swap').onclick=()=>{
    const tab=getTab();
    if(tab.panes.length<2)return;
    const tmp=tab.panes[0];tab.panes[0]=tab.panes[1];tab.panes[1]=tmp;
    const tmpRect={...tab.panes[0].rect};tab.panes[0].rect={...tab.panes[1].rect};tab.panes[1].rect=tmpRect;
    renderTabs();renderStage();
  };
  $('#sftp-tile').onclick=()=>{
    const tab=getTab();
    tab.maximizedPaneId='';
    const rects=buildSftpAutoRects(tab.panes.length);
    tab.panes.forEach((p,i)=>{p.rect={...rects[i]};});
    renderStage();
  };
  $('#sftp-fullscreen').onclick=()=>{
    shell.classList.toggle('is-fullscreen');
    const isFs=shell.classList.contains('is-fullscreen');
    $('#sftp-fullscreen').textContent=isFs?('🗗 '+vt('Thoát toàn màn hình','Exit fullscreen')):('⛶ '+vt('Toàn màn hình','Fullscreen'));
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
  for(const p of activeTab.panes)if(p.machineId&&!p.cwd&&!p.loading)loadPane(p,'');
  renderStage();
}
