const dockerTabs=new Map();
async function dockerPage(view,path,rev){
  const host=$('#hosts').value,tab=dockerTabs.get(host)||sessionStorage.getItem('vps-docker-tab:'+host)||'containers';
  view.textContent=vt('Đang kiểm tra Docker…','Checking Docker…');
  const state=await api(path+'/docker/status');
  if(rev!==revision)return;
  const ready=state.active&&state.compose;
  view.innerHTML=`<div class="vps-sections"><button data-dtab="containers">Container</button><button data-dtab="compose">Compose</button>
    <button data-refresh>${vt('Làm mới','Refresh')}</button></div><section class="vps-box docker-panel"><header><h2>${tab==='compose'?'Docker Compose':'Container'}</h2>
    <span>${escapeHTML([state.engine?'Docker Engine':'',state.active?vt('Đang chạy','Running'):vt('Chưa kết nối daemon','Daemon unavailable'),state.compose?'Compose '+state.compose:''].filter(Boolean).join(' · '))}</span></header><div class="docker-body"></div></section>`;
  for(const btn of view.querySelectorAll('[data-dtab]')){
    btn.setAttribute('aria-pressed',String(btn.dataset.dtab===tab));
    btn.onclick=()=>{dockerTabs.set(host,btn.dataset.dtab);vpsGetCache.clear();render();};
  }
  view.querySelector('[data-refresh]').onclick=render;
  const body=view.querySelector('.docker-body');
  if(!ready){
    const fix=document.createElement('button');fix.className='button small';fix.textContent=vt('Mở bộ Docker','Open Docker kit');
    fix.onclick=()=>{packagePages.set(host,'kits');softwareDrafts.set(host,{...(softwareDrafts.get(host)||{}),selected:softwareDrafts.get(host)?.selected||new Set(),mode:'kits',kit:'Docker',filter:'',search:''});location.hash='software';};
    body.append(fix);
    if(state.error){const reason=document.createElement('p');reason.textContent=state.error;body.append(reason);}
    if(!state.active || tab==='compose')return;
  }
  if(tab==='compose'){
    body.insertAdjacentHTML('beforeend',`<form class="compose-form"><label class="field">${vt('File Compose trên VPS','Compose file on server')}<input name="filename" placeholder="/opt/app/compose.yaml" required></label>
    <label><input type="checkbox" name="pull"> ${vt('Tải image mới trước khi triển khai','Pull images before deploying')}</label>
    <button class="button small" type="submit">${vt('Kiểm tra cấu hình','Check configuration')}</button><p role="alert"></p></form>`);
    const form=body.querySelector('form');
    form.onsubmit=async e=>{
      e.preventDefault();const btn=form.querySelector('button'), filename=form.elements.filename.value.trim(),pull=form.elements.pull.checked;
      btn.disabled=true;form.querySelector('[role=alert]').textContent='';
      try{
        const plan=await api(path+'/docker/plan?'+new URLSearchParams({filename}));
        if(!form.isConnected)return;
        modal(vt('Triển khai Compose','Deploy Compose'),'<p>'+escapeHTML($('#hosts').selectedOptions[0].textContent)+' · '+escapeHTML(plan.project)+'</p><code>'+escapeHTML(filename)+'</code><ul>'+plan.services.map(s=>'<li>'+escapeHTML(s.name)+' · '+escapeHTML(s.image)+'</li>').join('')+'</ul><p>'+(pull?'docker compose pull → ':'')+'docker compose up -d</p>',()=>submit('docker/deploy',{filename,pull,revision:plan.revision}));
      }catch(err){form.querySelector('[role=alert]').textContent=err.message;}finally{btn.disabled=false;}
    };
    return;
  }
  if(!state.containers.length){body.append(document.createTextNode(vt('Chưa có container trên VPS.','No containers on this server.')));return;}
  for(const [idx,c] of state.containers.entries()){
    const row=document.createElement('section');row.className='docker-row';
    row.innerHTML='<div><span class="row-number">'+(idx+1)+'.</span> <strong>'+escapeHTML(c.Names)+'</strong><code>'+escapeHTML(c.Image)+'</code></div><div>'+escapeHTML(c.Status)+'<small>'+escapeHTML(c.Ports)+'</small></div><div class="docker-actions"></div>';
    for(const op of ['logs',...(c.State==='running'?['stop','restart']:['start'])]){
      const btn=document.createElement('button');btn.type='button';btn.className='button small';btn.textContent=({logs:'Log',start:'Start',stop:'Stop',restart:'Restart'})[op];
      btn.onclick=async()=>{
        if(op!=='logs'){modal(btn.textContent+' · '+escapeHTML(c.Names),'<p>'+escapeHTML($('#hosts').selectedOptions[0].textContent)+' · '+escapeHTML(c.Image)+'</p>',()=>submit('docker/container',{container:c.ID,operation:op}));return;}
        btn.disabled=true;
        try{const result=await api(path+'/docker/logs?'+new URLSearchParams({container:c.ID}));
          if(btn.isConnected)modal('Log · '+escapeHTML(c.Names),'<pre>'+escapeHTML(result.text||vt('Chưa có log.','No logs yet.'))+'</pre>',async()=>{});
        }catch(err){if(btn.isConnected)modal('Docker','<p>'+escapeHTML(err.message)+'</p>',async()=>{});}
        finally{btn.disabled=false;}
      };
      row.lastElementChild.append(btn);
    }
    body.append(row);
  }
}
