// Termius-style multi-tab interactive SSH terminal powered by xterm.js + WebSocket PTY.
const termTabs=[];
let activeTermId='',termSeq=0,termFontSize=Number(localStorage.getItem('vps-term-font')||13);

function termWsUrl(machineId,cols,rows){
  const proto=location.protocol==='https:'?'wss:':'ws:';
  return proto+'//'+location.host+'/api/vps/machines/'+encodeURIComponent(machineId)+'/terminal?cols='+cols+'&rows='+rows;
}

function createTermTab(machine){
  const id='term-'+(++termSeq);
  const subtitle=machine.mode==='ssh'?(machine.user+'@'+machine.host+':'+machine.port):'local';
  const tab={id,machineId:machine.id,title:machine.name||machine.host,subtitle,status:'connecting',term:null,fitAddon:null,ws:null,pane:null};
  termTabs.push(tab);
  activeTermId=id;
  return tab;
}

function closeTermTab(id){
  const idx=termTabs.findIndex(t=>t.id===id);
  if(idx<0)return;
  const [tab]=termTabs.splice(idx,1);
  try{tab.ws?.close();}catch{}
  try{tab.term?.dispose();}catch{}
  tab.pane?.remove();
  if(activeTermId===id)activeTermId=termTabs[Math.max(0,idx-1)]?.id||'';
}

function connectTermTab(tab){
  if(!tab?.term)return;
  try{tab.ws?.close();}catch{}
  tab.status='connecting';
  tab.term.reset();
  tab.fitAddon?.fit();
  const cols=tab.term.cols||100,rows=tab.term.rows||30;
  if(previewMode){
    tab.status='connected';
    tab.term.writeln('\x1b[32m● Connected (Demo)\x1b[0m · '+tab.subtitle);
    tab.term.write('\r\nubuntu@demo-vps:~$ ');
    let line='';
    tab.term.onData(d=>{
      if(d==='\r'){
        tab.term.write('\r\n');
        const cmd=line.trim();line='';
        if(cmd==='clear')tab.term.clear();
        else if(cmd==='uname -a')tab.term.writeln('Linux demo-vps 6.8.0-generic aarch64 GNU/Linux');
        else if(cmd==='uptime')tab.term.writeln(' 14:15:00 up 12 days,  4:20,  1 user,  load average: 0.08, 0.12, 0.09');
        else if(cmd)tab.term.writeln('demo: '+cmd);
        tab.term.write('ubuntu@demo-vps:~$ ');
      }else if(d==='\x7f'){
        if(line.length){line=line.slice(0,-1);tab.term.write('\b \b');}
      }else if(d>=' '){
        line+=d;tab.term.write(d);
      }
    });
    return;
  }
  const ws=new WebSocket(termWsUrl(tab.machineId,cols,rows));
  tab.ws=ws;
  tab.term.writeln('\x1b[90mĐang kết nối SSH tới '+tab.subtitle+'…\x1b[0m');
  ws.onmessage=ev=>{
    let msg;try{msg=JSON.parse(ev.data);}catch{return;}
    if(msg.type==='data')tab.term.write(msg.data);
    else if(msg.type==='status'&&msg.state==='connected'){
      tab.status='connected';updateTermChrome();
      tab.fitAddon?.fit();
      if(tab.id===activeTermId)tab.term?.focus();
      if(ws.readyState===1)ws.send(JSON.stringify({type:'resize',cols:tab.term.cols,rows:tab.term.rows}));
    }else if(msg.type==='error'){
      tab.status='error';updateTermChrome();
      tab.term.writeln('\r\n\x1b[31m✗ '+msg.message+'\x1b[0m');
    }else if(msg.type==='exit'){
      tab.status='closed';updateTermChrome();
      tab.term.writeln('\r\n\x1b[33m[Phiên SSH đã đóng (code '+msg.code+')]\x1b[0m');
    }
  };
  ws.onerror=()=>{tab.status='error';updateTermChrome();};
  ws.onclose=()=>{if(tab.status==='connected'||tab.status==='connecting'){tab.status='closed';updateTermChrome();}};
}

function updateTermChrome(){
  const bar=document.getElementById('term-tabs');
  if(!bar)return;
  for(const el of bar.querySelectorAll('.term-tab')){
    const tab=termTabs.find(t=>t.id===el.dataset.id);
    if(!tab)continue;
    el.classList.toggle('active',tab.id===activeTermId);
    const dot=el.querySelector('.term-dot');
    if(dot)dot.dataset.state=tab.status;
  }
  const stage=document.getElementById('term-stage');
  if(!stage)return;
  for(const tab of termTabs){
    if(tab.pane)tab.pane.hidden=tab.id!==activeTermId;
  }
  const active=termTabs.find(t=>t.id===activeTermId);
  if(active?.fitAddon){
    requestAnimationFrame(()=>{
      active.fitAddon.fit();
      active.term?.focus();
    });
  }
}

async function terminalPage(view,path,rev){
  const servers=await api('vps/servers');
  if(rev!==revision)return;
  const hashParams=new URLSearchParams(location.hash.split('?')[1]||'');
  const reqId=hashParams.get('machine')||$('#hosts').value;
  if(hashParams.has('machine'))history.replaceState(null,'','#terminal');

  if(reqId){
    const existing=termTabs.find(t=>t.machineId===reqId);
    if(existing&&hashParams.has('machine'))activeTermId=existing.id;
    else if(!termTabs.length||hashParams.has('machine')){
      const m=servers.find(s=>s.id===reqId)||servers[0];
      if(m)createTermTab(m);
    }
  }else if(!termTabs.length&&servers[0]){
    createTermTab(servers[0]);
  }

  const picker=document.createElement('select');picker.className='term-host-select';picker.ariaLabel='Chọn VPS';
  servers.forEach(s=>picker.append(new Option(s.name+(s.host?' ('+s.host+')':''),s.id)));
  if(reqId&&servers.some(s=>s.id===reqId))picker.value=reqId;
  const newBtn=document.createElement('button');newBtn.type='button';newBtn.className='button';newBtn.dataset.tone='create';newBtn.textContent='+ '+vt('Mở tab SSH','New SSH tab');
  newBtn.onclick=()=>{
    const m=servers.find(s=>s.id===picker.value);
    if(!m)return;
    createTermTab(m);
    renderTerminalStage();
  };
  $('#heading-actions').append(picker,newBtn);

  const snippets=[
    ['btop','COLORTERM=truecolor btop','monitor'],
    ['htop','htop','monitor'],
    ['df -h','df -h','disk'],
    ['free -h','free -h','disk'],
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
        +'<button type="button" class="button small" id="term-font-dn" title="Thu nhỏ chữ">A-</button>'
        +'<button type="button" class="button small" id="term-font-up" title="Phóng to chữ">A+</button>'
        +'<button type="button" class="button small" id="term-clear">'+vt('Xoá màn hình','Clear')+'</button>'
        +'<button type="button" class="button small" id="term-reconnect">'+vt('Kết nối lại','Reconnect')+'</button>'
        +'<button type="button" class="button small" id="term-fullscreen">'+vt('Toàn màn hình','Fullscreen')+'</button>'
      +'</div>'
    +'</div>'
    +'<div class="term-snippets">'+snippets.map(([label,cmd,kind])=>'<button type="button" class="term-chip" data-kind="'+kind+'" data-cmd="'+escapeHTML(cmd)+'">'+escapeHTML(label)+'</button>').join('')+'</div>'
    +'<div class="term-stage" id="term-stage"></div>'
    +'</section>';

  const stage=$('#term-stage'),tabsBar=$('#term-tabs'),shell=$('#term-shell');

  function mountTab(tab){
    if(tab.pane){
      stage.append(tab.pane);
      return;
    }
    const pane=document.createElement('div');pane.className='term-pane';pane.hidden=tab.id!==activeTermId;
    tab.pane=pane;stage.append(pane);
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
    term.open(pane);
    if(term.textarea){
      term.textarea.setAttribute('autocomplete','off');
      term.textarea.setAttribute('autocorrect','off');
      term.textarea.setAttribute('autocapitalize','off');
      term.textarea.setAttribute('spellcheck','false');
      term.textarea.setAttribute('lang','en');
    }
    tab.term=term;tab.fitAddon=fitAddon;
    term.attachCustomKeyEventHandler(ev=>{
      if(!previewMode&&ev.key==='Enter'&&!ev.isComposing&&!ev.shiftKey&&!ev.ctrlKey&&!ev.altKey&&!ev.metaKey){
        if(ev.type==='keydown'){
          ev.preventDefault();
          if(tab.ws?.readyState===1)tab.ws.send(JSON.stringify({type:'data',data:'\r'}));
        }else if(ev.type==='keypress'){
          ev.preventDefault();
        }
        return false;
      }
      if(!previewMode&&ev.key==='Tab'&&!ev.ctrlKey&&!ev.altKey&&!ev.metaKey){
        if(ev.type==='keydown'){
          ev.preventDefault();
          if(tab.ws?.readyState===1)tab.ws.send(JSON.stringify({type:'data',data:ev.shiftKey?'\x1b[Z':'\t'}));
        }else if(ev.type==='keypress'){
          ev.preventDefault();
        }
        return false;
      }
      return true;
    });
    term.onData(data=>{if(tab.ws?.readyState===1)tab.ws.send(JSON.stringify({type:'data',data}));});
    term.onResize(({cols,rows})=>{if(tab.ws?.readyState===1)tab.ws.send(JSON.stringify({type:'resize',cols,rows}));});
    fitAddon.fit();
    connectTermTab(tab);
    requestAnimationFrame(()=>{fitAddon.fit();if(tab.id===activeTermId)term.focus();});
  }

  function renderTerminalStage(){
    tabsBar.innerHTML='';
    for(const tab of termTabs){
      mountTab(tab);
      const btn=document.createElement('div');btn.className='term-tab'+(tab.id===activeTermId?' active':'');btn.dataset.id=tab.id;
      btn.innerHTML='<span class="term-dot" data-state="'+tab.status+'"></span><span class="term-tab-title"><strong>'+escapeHTML(tab.title)+'</strong><small>'+escapeHTML(tab.subtitle)+'</small></span><button type="button" class="term-tab-close" aria-label="Đóng">×</button>';
      btn.onclick=e=>{
        if(e.target.closest('.term-tab-close')){closeTermTab(tab.id);renderTerminalStage();return;}
        activeTermId=tab.id;updateTermChrome();
      };
      tabsBar.append(btn);
    }
    if(!termTabs.length){
      stage.innerHTML='<div class="term-empty">'+vt('Chưa có tab SSH nào. Chọn VPS ở trên và bấm + Mở tab SSH.','No SSH tabs open. Select a VPS above and click + New SSH tab.')+'</div>';
    }
    updateTermChrome();
  }

  for(const chip of shell.querySelectorAll('.term-chip')){
    chip.onclick=()=>{
      const tab=termTabs.find(t=>t.id===activeTermId);
      if(!tab?.term)return;
      const cmd=chip.dataset.cmd+'\r';
      if(tab.ws?.readyState===1)tab.ws.send(JSON.stringify({type:'data',data:cmd}));
      tab.term.focus();
    };
  }
  const setFont=delta=>{
    termFontSize=Math.min(22,Math.max(11,termFontSize+delta));
    localStorage.setItem('vps-term-font',String(termFontSize));
    for(const t of termTabs){if(t.term){t.term.options.fontSize=termFontSize;t.fitAddon?.fit();}}
  };
  $('#term-font-dn').onclick=()=>setFont(-1);
  $('#term-font-up').onclick=()=>setFont(1);
  $('#term-clear').onclick=()=>{termTabs.find(t=>t.id===activeTermId)?.term?.clear();};
  $('#term-reconnect').onclick=()=>{const t=termTabs.find(x=>x.id===activeTermId);if(t)connectTermTab(t);};
  $('#term-fullscreen').onclick=()=>{
    shell.classList.toggle('is-fullscreen');
    const active=termTabs.find(t=>t.id===activeTermId);
    setTimeout(()=>active?.fitAddon?.fit(),50);
  };
  const onResize=()=>{const active=termTabs.find(t=>t.id===activeTermId);active?.fitAddon?.fit();};
  stage.onclick=()=>{termTabs.find(t=>t.id===activeTermId)?.term?.focus();};
  if(window.ResizeObserver)new ResizeObserver(onResize).observe(stage);
  window.addEventListener('resize',onResize);
  renderTerminalStage();
}
