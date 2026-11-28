// Termius-style multi-tab, free-form split-pane & broadcast SSH terminal powered by xterm.js + WebSocket PTY.
const termWorkspaces=[];
const termPanes=new Map();
let activeWsId='',wsSeq=0,paneSeq=0,termFontSize=Number(localStorage.getItem('vps-term-font')||13),linkedResize=localStorage.getItem('vps-term-link-resize')!=='0';
const TERM_TPL_KEY='vps-term-templates';

function termWsUrl(machineId,cols,rows){
  const proto=location.protocol==='https:'?'wss:':'ws:';
  const wsTarget=window.zmWorkspaceHelper?window.zmWorkspaceHelper.getTarget():'';
  return proto+'//'+location.host+'/api/vps/machines/'+encodeURIComponent(machineId)+'/terminal?cols='+cols+'&rows='+rows+(wsTarget?'&workspace_user='+encodeURIComponent(wsTarget):'');
}

function loadTermTemplates(){
  try{const raw=JSON.parse(localStorage.getItem(TERM_TPL_KEY)||'[]');return Array.isArray(raw)?raw:[];}catch{return [];}
}
function saveTermTemplates(list){localStorage.setItem(TERM_TPL_KEY,JSON.stringify(list));}

function buildAutoRects(count){
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

function createPane(workspaceId,machine,rect){
  const id='pane-'+(++paneSeq);
  const subtitle=machine.mode==='ssh'?(machine.user+'@'+machine.host+':'+machine.port):'local';
  const pane={
    id,workspaceId,machineId:machine.id,
    title:machine.name||machine.host||'VPS',subtitle,
    status:'connecting',term:null,fitAddon:null,ws:null,
    el:null,bodyEl:null,dotEl:null,bcastBtn:null,maxBtn:null,
    broadcastIncluded:true,
    rect:rect?{...rect}:{x:0,y:0,w:100,h:100}
  };
  termPanes.set(id,pane);
  return pane;
}

function createWorkspace(machines,title){
  const id='ws-'+(++wsSeq);
  const rects=buildAutoRects(machines.length);
  const panes=machines.map((m,i)=>createPane(id,m,rects[i]));
  const wsTitle=title||(panes.length===1?panes[0].title:(panes.length+' VPS'));
  const ws={
    id,title:wsTitle,broadcast:false,maximizedPaneId:'',templateId:'',
    activePaneId:panes[0]?.id||'',
    paneIds:panes.map(p=>p.id)
  };
  termWorkspaces.push(ws);
  activeWsId=id;
  return ws;
}

function disposePane(paneId){
  const pane=termPanes.get(paneId);
  if(!pane)return;
  if(pane.ws){
    const old=pane.ws;pane.ws=null;
    old.onmessage=old.onerror=old.onclose=null;
    try{old.close();}catch{}
  }
  try{pane.term?.dispose();}catch{}
  pane.el?.remove();
  termPanes.delete(paneId);
}

function closeWorkspace(wsId){
  const idx=termWorkspaces.findIndex(w=>w.id===wsId);
  if(idx<0)return;
  const [ws]=termWorkspaces.splice(idx,1);
  for(const pid of ws.paneIds)disposePane(pid);
  if(activeWsId===wsId)activeWsId=termWorkspaces[Math.max(0,idx-1)]?.id||'';
}

function getActiveWorkspace(){
  return termWorkspaces.find(w=>w.id===activeWsId)||null;
}

function getActivePane(){
  const ws=getActiveWorkspace();
  if(!ws)return null;
  return termPanes.get(ws.activePaneId)||termPanes.get(ws.paneIds[0])||null;
}

function sendPaneInput(sourcePane,data){
  if(!sourcePane||!data)return;
  const ws=termWorkspaces.find(w=>w.id===sourcePane.workspaceId);
  const targets=(ws?.broadcast&&sourcePane.broadcastIncluded)
    ?ws.paneIds.map(id=>termPanes.get(id)).filter(p=>p&&p.broadcastIncluded)
    :[sourcePane];
  for(const p of targets){
    if(previewMode){p.demoInput?.(data);continue;}
    if(p.ws?.readyState===1)p.ws.send(JSON.stringify({type:'data',data}));
  }
}

function applyPaneRect(pane,maximized){
  if(!pane?.el)return;
  if(maximized){
    pane.el.style.left='0%';pane.el.style.top='0%';pane.el.style.width='100%';pane.el.style.height='100%';
  }else{
    const r=pane.rect;
    pane.el.style.left=r.x+'%';pane.el.style.top=r.y+'%';pane.el.style.width=r.w+'%';pane.el.style.height=r.h+'%';
  }
}

function fitWorkspacePanes(ws){
  if(!ws)return;
  const ids=ws.maximizedPaneId?[ws.maximizedPaneId]:ws.paneIds;
  for(const pid of ids){
    const p=termPanes.get(pid);
    if(p?.fitAddon&&p.el?.isConnected){
      try{p.fitAddon.fit();}catch{}
    }
  }
}

function syncPaneChrome(pane){
  if(!pane?.el)return;
  const ws=termWorkspaces.find(w=>w.id===pane.workspaceId);
  const isActive=ws?.activePaneId===pane.id;
  const isBcast=Boolean(ws?.broadcast&&pane.broadcastIncluded);
  const isMax=ws?.maximizedPaneId===pane.id;
  pane.el.classList.toggle('is-active',isActive);
  pane.el.classList.toggle('is-broadcast',isBcast);
  pane.el.classList.toggle('is-maximized',isMax);
  pane.el.hidden=Boolean(ws?.maximizedPaneId&&!isMax);
  applyPaneRect(pane,isMax);
  if(pane.dotEl)pane.dotEl.dataset.state=pane.status;
  if(pane.bcastBtn){
    pane.bcastBtn.hidden=!ws?.broadcast;
    pane.bcastBtn.classList.toggle('is-on',pane.broadcastIncluded);
    pane.bcastBtn.title=pane.broadcastIncluded?vt('Đang nhận Broadcast (bấm để loại trừ)','Receiving Broadcast (click to exclude)'):vt('Đang tắt Broadcast cho khung này','Broadcast muted for this pane');
  }
  if(pane.maxBtn){
    pane.maxBtn.textContent=isMax?'🗗':'⛶';
    pane.maxBtn.title=isMax?vt('Thu về vị trí cũ','Restore size'):vt('Phóng to khung này','Maximize pane');
  }
}

function connectPane(pane){
  if(!pane?.term)return;
  if(pane.ws){
    const old=pane.ws;pane.ws=null;
    old.onmessage=old.onerror=old.onclose=null;
    try{old.close();}catch{}
  }
  pane.status='connecting';
  pane.term.reset();
  pane.fitAddon?.fit();
  syncPaneChrome(pane);
  const cols=pane.term.cols||80,rows=pane.term.rows||24;
  if(previewMode){
    pane.status='connected';
    syncPaneChrome(pane);
    pane.term.writeln('\x1b[32m● Connected (Demo)\x1b[0m · '+pane.subtitle);
    pane.term.write('\r\nroot@'+pane.title+':~# ');
    let line='';
    pane.demoInput=d=>{
      if(d==='\r'){
        pane.term.write('\r\n');
        const cmd=line.trim();line='';
        if(cmd==='clear')pane.term.clear();
        else if(cmd==='uname -a')pane.term.writeln('Linux '+pane.title+' 6.8.0-generic aarch64 GNU/Linux');
        else if(cmd==='uptime')pane.term.writeln(' 18:40:00 up 12 days,  4:20,  1 user,  load average: 0.08, 0.12, 0.09');
        else if(cmd==='hostname')pane.term.writeln(pane.title);
        else if(cmd)pane.term.writeln('demo: '+cmd);
        pane.term.write('root@'+pane.title+':~# ');
      }else if(d==='\x7f'){
        if(line.length){line=line.slice(0,-1);pane.term.write('\b \b');}
      }else if(d>=' '){
        line+=d;pane.term.write(d);
      }
    };
    return;
  }
  const ws=new WebSocket(termWsUrl(pane.machineId,cols,rows));
  pane.ws=ws;
  pane.term.writeln('\x1b[90mĐang kết nối SSH tới '+pane.subtitle+'…\x1b[0m');
  ws.onmessage=ev=>{
    if(pane.ws!==ws)return;
    let msg;try{msg=JSON.parse(ev.data);}catch{return;}
    if(msg.type==='data')pane.term.write(msg.data);
    else if(msg.type==='status'&&msg.state==='connected'){
      pane.status='connected';syncPaneChrome(pane);updateTermHeader();
      pane.fitAddon?.fit();
      const activeWs=getActiveWorkspace();
      if(activeWs?.id===pane.workspaceId&&activeWs.activePaneId===pane.id)pane.term?.focus();
      if(ws.readyState===1)ws.send(JSON.stringify({type:'resize',cols:pane.term.cols,rows:pane.term.rows}));
    }else if(msg.type==='error'){
      pane.status='error';syncPaneChrome(pane);updateTermHeader();
      pane.term.writeln('\r\n\x1b[31m✗ '+msg.message+'\x1b[0m');
    }else if(msg.type==='exit'){
      pane.status='closed';syncPaneChrome(pane);updateTermHeader();
      pane.term.writeln('\r\n\x1b[33m[Phiên SSH đã đóng (code '+msg.code+')]\x1b[0m');
    }
  };
  ws.onerror=()=>{
    if(pane.ws!==ws)return;
    if(pane.status==='connecting')pane.term.writeln('\r\n\x1b[31m✗ '+vt('Không thể mở WebSocket SSH (kiểm tra proxy Nginx/Cloudflare cho WebSocket Upgrade).','Unable to open SSH WebSocket (check Nginx/Cloudflare WebSocket Upgrade proxy).')+'\x1b[0m');
    pane.status='error';syncPaneChrome(pane);updateTermHeader();
  };
  ws.onclose=ev=>{
    if(pane.ws!==ws)return;
    if(ev.code===4401){managerLogin();return;}
    if(pane.status==='connecting'){
      pane.status='error';syncPaneChrome(pane);updateTermHeader();
      pane.term.writeln('\r\n\x1b[31m✗ '+vt('WebSocket bị đóng trước khi kết nối (mã '+ev.code+(ev.reason?': '+ev.reason:'')+').','WebSocket closed before connecting (code '+ev.code+(ev.reason?': '+ev.reason:'')+').')+'\x1b[0m');
    }else if(pane.status==='connected'){
      pane.status='closed';syncPaneChrome(pane);updateTermHeader();
    }
  };
}

function updateTermHeader(){
  const bar=document.getElementById('term-tabs');
  if(!bar)return;
  for(const el of bar.querySelectorAll('.term-tab')){
    const ws=termWorkspaces.find(w=>w.id===el.dataset.id);
    if(!ws)continue;
    el.classList.toggle('active',ws.id===activeWsId);
    const statuses=ws.paneIds.map(id=>termPanes.get(id)?.status);
    const dot=el.querySelector('.term-dot');
    if(dot)dot.dataset.state=statuses.every(s=>s==='connected')?'connected':statuses.some(s=>s==='error')?'error':statuses.some(s=>s==='connecting')?'connecting':'closed';
    const bcastBadge=el.querySelector('.term-tab-bcast');
    if(bcastBadge)bcastBadge.hidden=!ws.broadcast;
  }
  const bcastBtn=document.getElementById('term-broadcast');
  const activeWs=getActiveWorkspace();
  if(bcastBtn){
    bcastBtn.classList.toggle('is-active',Boolean(activeWs?.broadcast));
    bcastBtn.disabled=!activeWs;
  }
}

async function terminalPage(view,path,rev){
  const servers=(await api('vps/servers')).slice().sort((a,b)=>String(a.name||a.host||'').localeCompare(String(b.name||b.host||''),undefined,{numeric:true,sensitivity:'base'}));
  if(rev!==revision)return;
  const hashParams=new URLSearchParams(location.hash.split('?')[1]||'');
  const reqId=hashParams.get('machine')||$('#hosts').value;
  if(hashParams.has('machine'))history.replaceState(null,'','#terminal');

  if(reqId){
    const existingWs=termWorkspaces.find(w=>w.paneIds.some(pid=>termPanes.get(pid)?.machineId===reqId));
    if(existingWs&&hashParams.has('machine')){
      activeWsId=existingWs.id;
      const matchPid=existingWs.paneIds.find(pid=>termPanes.get(pid)?.machineId===reqId);
      if(matchPid)existingWs.activePaneId=matchPid;
    }else if(!termWorkspaces.length||hashParams.has('machine')){
      const m=servers.find(s=>s.id===reqId)||servers[0];
      if(m)createWorkspace([m]);
    }
  }else if(!termWorkspaces.length&&servers[0]){
    createWorkspace([servers[0]]);
  }

  const picker=document.createElement('select');picker.className='term-host-select';picker.ariaLabel='Chọn VPS';
  servers.forEach(s=>picker.append(new Option(s.name+(s.host?' ('+s.host+')':''),s.id)));
  if(reqId&&servers.some(s=>s.id===reqId))picker.value=reqId;

  const newBtn=document.createElement('button');newBtn.type='button';newBtn.className='button';newBtn.dataset.tone='create';newBtn.textContent='+ '+vt('Mở tab SSH','New SSH tab');
  newBtn.onclick=()=>{
    const m=servers.find(s=>s.id===picker.value);
    if(!m)return;
    createWorkspace([m]);
    renderAll();
  };

  const splitBtn=document.createElement('button');splitBtn.type='button';splitBtn.className='button';splitBtn.dataset.tone='info';splitBtn.textContent='+ '+vt('Thêm vào tab này','Add to this tab');
  splitBtn.onclick=()=>{
    const m=servers.find(s=>s.id===picker.value);
    if(!m)return;
    const ws=getActiveWorkspace();
    if(!ws){createWorkspace([m]);renderAll();return;}
    const pane=createPane(ws.id,m,{x:10,y:10,w:45,h:45});
    ws.paneIds.push(pane.id);
    const rects=buildAutoRects(ws.paneIds.length);
    ws.paneIds.forEach((pid,i)=>{const p=termPanes.get(pid);if(p)p.rect={...rects[i]};});
    ws.activePaneId=pane.id;
    ws.maximizedPaneId='';
    ws.title=ws.paneIds.length+' VPS';
    renderAll();
  };

  const multiBtn=document.createElement('button');multiBtn.type='button';multiBtn.className='button';multiBtn.dataset.tone='configure';multiBtn.textContent='+ '+vt('Mở nhiều VPS','Open multi-VPS');
  multiBtn.onclick=()=>{
    if(!servers.length)return;
    const items=servers.map(s=>`<label class="term-pick-item"><input type="checkbox" name="machines" value="${escapeHTML(s.id)}"><span><strong>${escapeHTML(s.name)}</strong><small>${escapeHTML(s.user+'@'+(s.host||'local'))}</small></span></label>`).join('');
    modal(vt('Mở nhiều VPS cùng lúc (Split-pane)','Open multiple VPSs (Split-pane)'),
      `<div class="term-pick-bar"><input type="search" id="term-pick-filter" placeholder="${vt('Tìm nhanh VPS…','Filter servers…')}"><button type="button" class="button small" id="term-pick-all">${vt('Chọn tất cả','Select all')}</button><button type="button" class="button small" id="term-pick-none">${vt('Bỏ chọn','Clear')}</button></div>
       <label class="field" style="margin-bottom:8px">${vt('Tên tab workspace','Workspace tab name')}<input name="title" maxlength="40" placeholder="all vps (${servers.length})"></label>
       <div class="term-pick-grid" id="term-pick-grid">${items}</div>
       <label class="field checkbox" style="margin-top:10px"><input type="checkbox" name="broadcast" checked> ${vt('Bật sẵn Broadcast Input (gõ đồng bộ tất cả VPS)','Enable Broadcast Input (type across all VPSs)')}</label>`,
      async form=>{
        const ids=form.getAll('machines');
        if(!ids.length)throw new Error(vt('Chọn ít nhất 1 VPS.','Select at least 1 server.'));
        const chosen=ids.map(id=>servers.find(s=>s.id===id)).filter(Boolean);
        const ws=createWorkspace(chosen,String(form.get('title')||'').trim()||(chosen.length+' VPS'));
        ws.broadcast=form.has('broadcast');
        renderAll();
      });
    const grid=$('#term-pick-grid');
    $('#term-pick-filter').oninput=e=>{
      const q=e.target.value.trim().toLowerCase();
      for(const el of grid.children)el.hidden=q&&!el.textContent.toLowerCase().includes(q);
    };
    $('#term-pick-all').onclick=()=>{for(const cb of grid.querySelectorAll('input[type=checkbox]'))if(!cb.closest('label').hidden)cb.checked=true;};
    $('#term-pick-none').onclick=()=>{for(const cb of grid.querySelectorAll('input[type=checkbox]'))cb.checked=false;};
  };

  $('#heading-actions').append(picker,newBtn,splitBtn,multiBtn);

  const snippets=[
    ['btop','COLORTERM=truecolor btop','monitor'],
    ['htop','htop','monitor'],
    ['df -h','df -h','disk'],
    ['free -h','free -h','disk'],
    ['bench.sh','curl -Lso- bench.sh | bash','monitor'],
    ['nginx -t','sudo nginx -t','web'],
    ['docker ps','docker ps','web'],
    ['ufw','sudo ufw status','sec'],
    ['ports','ss -tulpn','sec'],
    ['sudo -i','sudo -i','sec']
  ];

  view.innerHTML='<section class="term-shell" id="term-shell">'
    +'<div class="term-head">'
      +'<div class="term-tabs" id="term-tabs"></div>'
      +'<div class="term-controls">'
        +'<select class="term-tpl-select" id="term-tpl-select" aria-label="Template"></select>'
        +'<button type="button" class="button small term-icon-btn" id="term-tpl-save" title="'+vt('Lưu hoặc cập nhật template','Save or update template')+'">💾</button>'
        +'<button type="button" class="button small term-icon-btn" id="term-tpl-del" data-tone="remove" hidden title="'+vt('Xoá template đang chọn','Delete selected template')+'">🗑</button>'
        +'<button type="button" class="button small term-icon-btn term-link-toggle'+(linkedResize?' is-active':'')+'" id="term-link-resize" title="'+vt('Kéo dính các ô sát cạnh (bấm để tắt kéo rời)','Linked edge resize (click for free resize)')+'">⛓</button>'
        +'<button type="button" class="button small term-icon-btn" id="term-tile" title="'+vt('Xếp đều các ô thành lưới','Auto-tile panes into grid')+'">⊞</button>'
        +'<button type="button" class="button small term-bcast-toggle" id="term-broadcast" title="'+vt('Gõ đồng bộ tới tất cả VPS trong tab','Broadcast input to all panes')+'">Broadcast</button>'
        +'<button type="button" class="button small term-icon-btn" id="term-font-dn" title="Thu nhỏ chữ">A-</button>'
        +'<button type="button" class="button small term-icon-btn" id="term-font-up" title="Phóng to chữ">A+</button>'
        +'<button type="button" class="button small term-icon-btn" id="term-clear" title="'+vt('Xoá màn hình','Clear')+'">⌫</button>'
        +'<button type="button" class="button small term-icon-btn" id="term-reconnect" title="'+vt('Kết nối lại','Reconnect')+'">↻</button>'
        +'<button type="button" class="button small term-icon-btn" id="term-fullscreen" title="'+vt('Toàn màn hình','Fullscreen')+'">⛶</button>'
      +'</div>'
    +'</div>'
    +'<div class="term-snippets">'+snippets.map(([label,cmd,kind])=>'<button type="button" class="term-chip" data-kind="'+kind+'" data-cmd="'+escapeHTML(cmd)+'">'+escapeHTML(label)+'</button>').join('')+'</div>'
    +'<div class="term-stage" id="term-stage"></div>'
    +'</section>';

  const stage=$('#term-stage'),tabsBar=$('#term-tabs'),shell=$('#term-shell');

  function startPointerOp(e,pane,mode){
    if(e.button!==0||e.target.closest('button'))return;
    const ws=getActiveWorkspace();
    if(!ws||ws.maximizedPaneId===pane.id)return;
    e.preventDefault();
    const stageRect=stage.getBoundingClientRect();
    const startX=e.clientX,startY=e.clientY;
    const orig={...pane.rect};
    const origRight=orig.x+orig.w,origBottom=orig.y+orig.h;
    const others=ws.paneIds.map(id=>termPanes.get(id)).filter(p=>p&&p.id!==pane.id);
    const linkedE=(linkedResize&&mode.includes('e'))?others.filter(p=>Math.abs(p.rect.x-origRight)<1.8&&p.rect.y<origBottom-0.5&&(p.rect.y+p.rect.h)>orig.y+0.5).map(p=>({p,orig:{...p.rect}})):[];
    const linkedW=(linkedResize&&mode.includes('w'))?others.filter(p=>Math.abs((p.rect.x+p.rect.w)-orig.x)<1.8&&p.rect.y<origBottom-0.5&&(p.rect.y+p.rect.h)>orig.y+0.5).map(p=>({p,orig:{...p.rect}})):[];
    const linkedS=(linkedResize&&mode.includes('s'))?others.filter(p=>Math.abs(p.rect.y-origBottom)<1.8&&p.rect.x<origRight-0.5&&(p.rect.x+p.rect.w)>orig.x+0.5).map(p=>({p,orig:{...p.rect}})):[];
    const linkedN=(linkedResize&&mode.includes('n'))?others.filter(p=>Math.abs((p.rect.y+p.rect.h)-orig.y)<1.8&&p.rect.x<origRight-0.5&&(p.rect.x+p.rect.w)>orig.x+0.5).map(p=>({p,orig:{...p.rect}})):[];
    const minW=14,minH=16;
    const maxDxE=linkedE.length?Math.min(100-origRight,...linkedE.map(item=>item.orig.w-minW)):(100-origRight);
    const minDxE=minW-orig.w;
    const minDxW=linkedW.length?Math.max(-orig.x,...linkedW.map(item=>minW-item.orig.w)):(-orig.x);
    const maxDxW=orig.w-minW;
    const maxDyS=linkedS.length?Math.min(100-origBottom,...linkedS.map(item=>item.orig.h-minH)):(100-origBottom);
    const minDyS=minH-orig.h;
    const minDyN=linkedN.length?Math.max(-orig.y,...linkedN.map(item=>minH-item.orig.h)):(-orig.y);
    const maxDyN=orig.h-minH;
    pane.el.classList.add('is-moving');
    let raf=0;
    const onMove=ev=>{
      const rawDx=((ev.clientX-startX)/Math.max(stageRect.width,1))*100;
      const rawDy=((ev.clientY-startY)/Math.max(stageRect.height,1))*100;
      if(mode==='move'){
        pane.rect.x=Math.max(0,Math.min(100-orig.w,orig.x+rawDx));
        pane.rect.y=Math.max(0,Math.min(100-orig.h,orig.y+rawDy));
        applyPaneRect(pane,false);
      }else{
        if(mode.includes('e')){
          const dx=Math.max(minDxE,Math.min(maxDxE,rawDx));
          pane.rect.w=orig.w+dx;
          for(const item of linkedE){item.p.rect.x=item.orig.x+dx;item.p.rect.w=item.orig.w-dx;applyPaneRect(item.p,false);}
        }
        if(mode.includes('w')){
          const dx=Math.max(minDxW,Math.min(maxDxW,rawDx));
          pane.rect.x=orig.x+dx;pane.rect.w=orig.w-dx;
          for(const item of linkedW){item.p.rect.w=item.orig.w+dx;applyPaneRect(item.p,false);}
        }
        if(mode.includes('s')){
          const dy=Math.max(minDyS,Math.min(maxDyS,rawDy));
          pane.rect.h=orig.h+dy;
          for(const item of linkedS){item.p.rect.y=item.orig.y+dy;item.p.rect.h=item.orig.h-dy;applyPaneRect(item.p,false);}
        }
        if(mode.includes('n')){
          const dy=Math.max(minDyN,Math.min(maxDyN,rawDy));
          pane.rect.y=orig.y+dy;pane.rect.h=orig.h-dy;
          for(const item of linkedN){item.p.rect.h=item.orig.h+dy;applyPaneRect(item.p,false);}
        }
        applyPaneRect(pane,false);
        if(!raf)raf=requestAnimationFrame(()=>{raf=0;fitWorkspacePanes(ws);});
      }
    };
    const onUp=()=>{
      window.removeEventListener('pointermove',onMove);
      window.removeEventListener('pointerup',onUp);
      pane.el.classList.remove('is-moving');
      if(mode!=='move')fitWorkspacePanes(ws);
    };
    window.addEventListener('pointermove',onMove);
    window.addEventListener('pointerup',onUp);
  }

  function ensurePaneMounted(pane){
    if(pane.el)return pane.el;
    const wrap=document.createElement('div');
    wrap.className='term-pane-wrap';
    wrap.dataset.paneId=pane.id;
    wrap.innerHTML='<div class="term-pane-card">'
      +'<div class="term-pane-head" title="'+vt('Kéo tiêu đề để di chuyển tự do ô này','Drag header to move this pane freely')+'">'
        +'<div class="term-pane-meta"><span class="term-drag-grip" aria-hidden="true">⋮⋮</span><span class="term-dot" data-state="'+pane.status+'"></span><strong>'+escapeHTML(pane.title)+'</strong><small>'+escapeHTML(pane.subtitle)+'</small></div>'
        +'<div class="term-pane-actions">'
          +'<button type="button" class="term-pane-btn term-pane-sftp" title="'+vt('Mở SFTP cho VPS này','Open SFTP for this server')+'">SFTP</button>'
          +'<button type="button" class="term-pane-btn term-pane-bcast" title="Broadcast">B</button>'
          +'<button type="button" class="term-pane-btn term-pane-max" title="Phóng to">⛶</button>'
          +'<button type="button" class="term-pane-btn term-pane-reconn" title="Kết nối lại">↻</button>'
          +'<button type="button" class="term-pane-btn term-pane-close" title="Đóng">×</button>'
        +'</div>'
      +'</div>'
      +'<div class="term-pane-body"></div>'
      +'<div class="term-resize-n"></div>'
      +'<div class="term-resize-w"></div>'
      +'<div class="term-resize-e"></div>'
      +'<div class="term-resize-s"></div>'
      +'<div class="term-resize-se" title="'+vt('Kéo góc để đổi kích thước','Drag corner to resize')+'">◢</div>'
      +'</div>';
    pane.el=wrap;
    pane.headEl=wrap.querySelector('.term-pane-head');
    pane.bodyEl=wrap.querySelector('.term-pane-body');
    pane.dotEl=wrap.querySelector('.term-dot');
    pane.bcastBtn=wrap.querySelector('.term-pane-bcast');
    pane.maxBtn=wrap.querySelector('.term-pane-max');

    const term=new window.Terminal({
      fontSize:termFontSize,
      fontFamily:'Menlo,Monaco,"DejaVu Sans Mono","Courier New",monospace',
      cursorBlink:false,
      cursorStyle:'block',
      cursorInactiveStyle:'outline',
      drawBoldTextInBrightColors:true,
      minimumContrastRatio:1,
      scrollback:5000,
      theme:{
        background:'#080b10',foreground:'#e6edf3',cursor:'#9da7b3',cursorAccent:'#080b10',
        selectionBackground:'rgba(56,139,253,0.35)',
        black:'#484f58',red:'#ff7b72',green:'#3fb950',yellow:'#d29922',blue:'#58a6ff',magenta:'#bc8cff',cyan:'#39c5cf',white:'#b1bac4',
        brightBlack:'#6e7681',brightRed:'#ffa198',brightGreen:'#56d364',brightYellow:'#e3b341',brightBlue:'#79c0ff',brightMagenta:'#d2a8ff',brightCyan:'#56d4dd',brightWhite:'#f0f6fc'
      }
    });
    const fitAddon=new window.FitAddon.FitAddon();
    term.loadAddon(fitAddon);
    term.open(pane.bodyEl);
    if(term.textarea){
      term.textarea.setAttribute('autocomplete','off');
      term.textarea.setAttribute('autocorrect','off');
      term.textarea.setAttribute('autocapitalize','off');
      term.textarea.setAttribute('spellcheck','false');
      term.textarea.setAttribute('lang','en');
    }
    pane.term=term;pane.fitAddon=fitAddon;

    term.attachCustomKeyEventHandler(ev=>{
      if(!previewMode&&ev.key==='Enter'&&!ev.isComposing&&!ev.shiftKey&&!ev.ctrlKey&&!ev.altKey&&!ev.metaKey){
        if(ev.type==='keydown'){ev.preventDefault();sendPaneInput(pane,'\r');}
        else if(ev.type==='keypress'){ev.preventDefault();}
        return false;
      }
      if(!previewMode&&ev.key==='Tab'&&!ev.ctrlKey&&!ev.altKey&&!ev.metaKey){
        if(ev.type==='keydown'){ev.preventDefault();sendPaneInput(pane,ev.shiftKey?'\x1b[Z':'\t');}
        else if(ev.type==='keypress'){ev.preventDefault();}
        return false;
      }
      return true;
    });
    term.onData(data=>sendPaneInput(pane,data));
    term.onResize(({cols,rows})=>{if(pane.ws?.readyState===1)pane.ws.send(JSON.stringify({type:'resize',cols,rows}));});

    wrap.addEventListener('pointerdown',()=>{
      const ws=termWorkspaces.find(w=>w.id===pane.workspaceId);
      if(ws){
        ws.activePaneId=pane.id;
        for(const id of ws.paneIds)syncPaneChrome(termPanes.get(id));
      }
    });
    pane.bodyEl.onclick=()=>pane.term?.focus();

    pane.headEl.addEventListener('pointerdown',e=>startPointerOp(e,pane,'move'));
    wrap.querySelector('.term-resize-n').addEventListener('pointerdown',e=>startPointerOp(e,pane,'n'));
    wrap.querySelector('.term-resize-w').addEventListener('pointerdown',e=>startPointerOp(e,pane,'w'));
    wrap.querySelector('.term-resize-e').addEventListener('pointerdown',e=>startPointerOp(e,pane,'e'));
    wrap.querySelector('.term-resize-s').addEventListener('pointerdown',e=>startPointerOp(e,pane,'s'));
    wrap.querySelector('.term-resize-se').addEventListener('pointerdown',e=>startPointerOp(e,pane,'se'));

    pane.bcastBtn.onclick=e=>{
      e.stopPropagation();
      pane.broadcastIncluded=!pane.broadcastIncluded;
      syncPaneChrome(pane);
    };
    pane.maxBtn.onclick=e=>{
      e.stopPropagation();
      const ws=termWorkspaces.find(w=>w.id===pane.workspaceId);
      if(!ws)return;
      ws.maximizedPaneId=ws.maximizedPaneId===pane.id?'':pane.id;
      ws.activePaneId=pane.id;
      renderStage();
    };
    wrap.querySelector('.term-pane-sftp').onclick=e=>{e.stopPropagation();window.openSftpForMachine?.(pane.machineId);};
    wrap.querySelector('.term-pane-reconn').onclick=e=>{e.stopPropagation();connectPane(pane);};
    wrap.querySelector('.term-pane-close').onclick=e=>{
      e.stopPropagation();
      const ws=termWorkspaces.find(w=>w.id===pane.workspaceId);
      if(!ws)return;
      ws.paneIds=ws.paneIds.filter(id=>id!==pane.id);
      if(ws.maximizedPaneId===pane.id)ws.maximizedPaneId='';
      disposePane(pane.id);
      if(!ws.paneIds.length){closeWorkspace(ws.id);}
      else{
        if(!ws.paneIds.includes(ws.activePaneId))ws.activePaneId=ws.paneIds[0];
        if(ws.paneIds.length===1){
          const sole=termPanes.get(ws.paneIds[0]);
          if(sole){sole.rect={x:0,y:0,w:100,h:100};ws.title=sole.title;}
        }
      }
      renderAll();
    };

    connectPane(pane);
    return wrap;
  }

  function renderStage(){
    stage.replaceChildren();
    const ws=getActiveWorkspace();
    if(!ws||!ws.paneIds.length){
      stage.innerHTML='<div class="term-empty">'+vt('Chưa có tab SSH nào. Chọn VPS ở trên và bấm + Mở tab SSH hoặc + Mở nhiều VPS.','No SSH tabs open. Select a server above and click + New SSH tab or + Open multi-VPS.')+'</div>';
      updateTermHeader();
      return;
    }
    const canvas=document.createElement('div');
    canvas.className='term-canvas';
    for(const pid of ws.paneIds){
      const pane=termPanes.get(pid);
      if(!pane)continue;
      const el=ensurePaneMounted(pane);
      syncPaneChrome(pane);
      canvas.append(el);
    }
    stage.append(canvas);
    updateTermHeader();
    requestAnimationFrame(()=>{
      fitWorkspacePanes(ws);
      getActivePane()?.term?.focus();
    });
  }

  function renderAll(){
    tabsBar.replaceChildren();
    for(const ws of termWorkspaces){
      const sub=ws.paneIds.length===1?(termPanes.get(ws.paneIds[0])?.subtitle||''):(ws.paneIds.length+' panes');
      const btn=document.createElement('div');
      btn.className='term-tab'+(ws.id===activeWsId?' active':'');
      btn.dataset.id=ws.id;
      btn.innerHTML='<span class="term-dot"></span><span class="term-tab-title"><strong>'+escapeHTML(ws.title)+'</strong><small>'+escapeHTML(sub)+'</small></span><span class="term-tab-bcast" hidden>B</span><button type="button" class="term-tab-close" aria-label="Đóng">×</button>';
      btn.onclick=e=>{
        if(e.target.closest('.term-tab-close')){closeWorkspace(ws.id);renderAll();syncTemplatesUI();return;}
        activeWsId=ws.id;
        renderStage();
        syncTemplatesUI();
      };
      tabsBar.append(btn);
    }
    renderStage();
  }

  const tplSelect=$('#term-tpl-select'),tplSave=$('#term-tpl-save'),tplDel=$('#term-tpl-del');
  const serversById=new Map(servers.map(s=>[s.id,s]));
  function syncTemplatesUI(){
    const list=loadTermTemplates(),ws=getActiveWorkspace();
    tplSelect.innerHTML='<option value="">'+vt('Template ('+list.length+')','Templates ('+list.length+')')+'</option>';
    for(const t of list){
      const count=(t.panes||[]).length;
      tplSelect.append(new Option(t.name+' ('+count+')',t.id));
    }
    if(ws?.templateId&&list.some(t=>t.id===ws.templateId))tplSelect.value=ws.templateId;
    tplDel.hidden=!tplSelect.value;
    const isUpdate=Boolean(ws?.templateId&&list.some(t=>t.id===ws.templateId));
    tplSave.title=isUpdate?vt('Cập nhật template đang mở','Update current template'):vt('Lưu template mới','Save new template');
    tplSave.classList.toggle('is-active',isUpdate);
  }
  tplSelect.onchange=()=>{
    const tid=tplSelect.value;
    tplDel.hidden=!tid;
    if(!tid)return;
    const tpl=loadTermTemplates().find(t=>t.id===tid);
    if(!tpl)return;
    const id='ws-'+(++wsSeq);
    const paneIds=[];
    for(const item of (tpl.panes||[])){
      const m=serversById.get(item.machineId);
      if(!m)continue;
      const p=createPane(id,m,item.rect);
      p.broadcastIncluded=item.broadcastIncluded!==false;
      paneIds.push(p.id);
    }
    if(!paneIds.length)return;
    termWorkspaces.push({id,title:tpl.name,broadcast:Boolean(tpl.broadcast),maximizedPaneId:'',templateId:tpl.id,activePaneId:paneIds[0],paneIds});
    activeWsId=id;
    renderAll();
    syncTemplatesUI();
  };
  tplSave.onclick=()=>{
    const ws=getActiveWorkspace();
    if(!ws)return;
    const list=loadTermTemplates();
    const existing=ws.templateId?list.find(t=>t.id===ws.templateId):null;
    modal(existing?vt('Cập nhật / Lưu template','Update / Save template'):vt('Lưu template SSH','Save SSH template'),
      `<label class="field">${vt('Tên template','Template name')}<input name="name" required maxlength="40" value="${escapeHTML(existing?existing.name:ws.title)}"></label>`
      +(existing?`<label class="field checkbox" style="margin-top:8px"><input type="checkbox" name="as_new"> ${vt('Lưu thành template mới (không ghi đè bản cũ)','Save as new template (keep existing)')}</label>`:''),
      async form=>{
        const name=String(form.get('name')||'').trim();
        if(!name)throw new Error(vt('Nhập tên template.','Enter template name.'));
        const panes=ws.paneIds.map(pid=>termPanes.get(pid)).filter(Boolean).map(p=>({machineId:p.machineId,broadcastIncluded:p.broadcastIncluded,rect:{...p.rect}}));
        if(!panes.length)throw new Error(vt('Tab hiện tại không có khung VPS nào.','No panes to save.'));
        const next=loadTermTemplates();
        const asNew=form.has('as_new');
        if(existing&&!asNew){
          const idx=next.findIndex(t=>t.id===existing.id);
          if(idx>=0)next[idx]={...existing,name,broadcast:ws.broadcast,panes};
          ws.title=name;
        }else{
          const id='tpl-'+Date.now();
          next.push({id,name,broadcast:ws.broadcast,panes});
          ws.templateId=id;ws.title=name;
        }
        saveTermTemplates(next);
        renderAll();
        syncTemplatesUI();
      });
  };
  tplDel.onclick=()=>{
    const tid=tplSelect.value;
    if(!tid)return;
    const list=loadTermTemplates(),tpl=list.find(t=>t.id===tid);
    if(!tpl)return;
    modal(vt('Xoá template','Delete template'),'<p>'+vt('Xoá template ','Delete template ')+'<strong>'+escapeHTML(tpl.name)+'</strong>?</p>',async()=>{
      saveTermTemplates(loadTermTemplates().filter(t=>t.id!==tid));
      for(const w of termWorkspaces)if(w.templateId===tid)w.templateId='';
      syncTemplatesUI();
    });
  };

  $('#term-link-resize').onclick=e=>{
    linkedResize=!linkedResize;
    localStorage.setItem('vps-term-link-resize',linkedResize?'1':'0');
    e.currentTarget.classList.toggle('is-active',linkedResize);
  };

  $('#term-tile').onclick=()=>{
    const ws=getActiveWorkspace();
    if(!ws||!ws.paneIds.length)return;
    ws.maximizedPaneId='';
    const rects=buildAutoRects(ws.paneIds.length);
    ws.paneIds.forEach((pid,i)=>{const p=termPanes.get(pid);if(p)p.rect={...rects[i]};});
    renderStage();
  };

  $('#term-broadcast').onclick=()=>{
    const ws=getActiveWorkspace();
    if(!ws)return;
    ws.broadcast=!ws.broadcast;
    for(const id of ws.paneIds)syncPaneChrome(termPanes.get(id));
    updateTermHeader();
    getActivePane()?.term?.focus();
  };

  for(const chip of shell.querySelectorAll('.term-chip')){
    chip.onclick=()=>{
      const pane=getActivePane();
      if(!pane?.term)return;
      sendPaneInput(pane,chip.dataset.cmd+'\r');
      pane.term.focus();
    };
  }
  const setFont=delta=>{
    termFontSize=Math.min(22,Math.max(10,termFontSize+delta));
    localStorage.setItem('vps-term-font',String(termFontSize));
    for(const p of termPanes.values()){if(p.term){p.term.options.fontSize=termFontSize;p.fitAddon?.fit();}}
  };
  $('#term-font-dn').onclick=()=>setFont(-1);
  $('#term-font-up').onclick=()=>setFont(1);
  $('#term-clear').onclick=()=>{
    const ws=getActiveWorkspace();
    if(!ws)return;
    if(ws.broadcast){for(const id of ws.paneIds)termPanes.get(id)?.term?.clear();}
    else getActivePane()?.term?.clear();
  };
  $('#term-reconnect').onclick=()=>{
    const ws=getActiveWorkspace();
    if(!ws)return;
    if(ws.broadcast){ws.paneIds.forEach((id,idx)=>setTimeout(()=>connectPane(termPanes.get(id)),idx*70));}
    else{const p=getActivePane();if(p)connectPane(p);}
  };
  $('#term-fullscreen').onclick=()=>{
    shell.classList.toggle('is-fullscreen');
    setTimeout(()=>fitWorkspacePanes(getActiveWorkspace()),50);
  };
  const onResize=()=>fitWorkspacePanes(getActiveWorkspace());
  if(window.ResizeObserver)new ResizeObserver(onResize).observe(stage);
  window.addEventListener('resize',onResize);
  renderAll();
  syncTemplatesUI();
}
