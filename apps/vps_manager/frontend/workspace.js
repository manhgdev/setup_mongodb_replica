const vt=(vi,en)=>vpsEnglish?en:vi;
const packagePages=new Map();

function packagesPage(view,path,host){
  const page=packagePages.get(host)||'kits';
  if(page==='kits')return view;
  view.innerHTML='<button type="button" class="text-button" id="back-kits">← '+vt('Bộ cài của tôi','My kits')+'</button><div id="package-content"></div>';
  $('#back-kits').onclick=()=>{packagePages.set(host,'kits');render();};
  const content=$('#package-content');
  const remote=page==='repository';
  content.innerHTML=`<section class="vps-box"><form class="vps-search"><input type="search" maxlength="100" aria-label="${vt('Tên gói','Package name')}" placeholder="${remote?vt('Tên gói trong kho, ví dụ tree','Repository package, e.g. tree'):vt('Lọc theo tên gói…','Filter by package name…')}"><button class="button small">${vt('Tìm','Search')}</button></form>
    <div class="vps-package-results" aria-live="polite"></div><div class="vps-pager"></div></section>`;
  const form=content.querySelector('form'),results=content.querySelector('.vps-package-results'),pager=content.querySelector('.vps-pager');
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
      if(!content.isConnected){
        observer.disconnect();
        window.removeEventListener('resize',resize);
        return;
      }
      timer=setTimeout(()=>{
        if(!content.isConnected)return;
        const next=capacity();
        if(next===limit)return;
        offset=Math.floor(offset/next)*next;
        limit=next;load();
      },150);
    }
    const observer=new ResizeObserver(resize);
    observer.observe(content);
    window.addEventListener('resize',resize);
  }
  async function load(){
    const current=++generation;
    pager.replaceChildren();
    if(remote&&!query){results.textContent=vt('Nhập tên để tìm trong kho của VPS.','Enter a name to search this server’s repositories.');return;}
    results.textContent=vt('Đang đọc danh sách gói…','Reading packages…');
    try{
      const data=await api(path+'/packages?'+new URLSearchParams({scope:page,query,offset,limit}));
      if(current!==generation||!content.isConnected)return;
      results.replaceChildren();
      for(const item of data.items){
        const row=document.createElement('div');row.className='vps-package';
        const title=document.createElement('strong');title.textContent=title.title=item.name;
        const version=document.createElement('code');version.textContent=version.title=item.version;row.append(title,version);
        if(remote){
          const btn=document.createElement('button');btn.className='button small';btn.textContent=vt('Xem kế hoạch','Preview');
          btn.onclick=async()=>{
            btn.disabled=true;
            try{
              const plan=await api(path+'/package-plan?'+new URLSearchParams({name:item.name}));
              if(!btn.isConnected)return;
              modal(vt('Cài gói từ kho','Install repository package'),'<p>'+escapeHTML($('#hosts').selectedOptions[0].textContent)+' · '+escapeHTML(plan.target)+'</p><pre>'+escapeHTML(plan.summary)+'</pre>',()=>submit('native-install',{name:item.name,target:plan.target}));
            }catch(err){if(btn.isConnected)row.append(document.createTextNode(err.message));}
            finally{btn.disabled=false;}
          };row.append(btn);
        }
        results.append(row);
      }
      if(!data.total){results.textContent=vt('Không tìm thấy gói.','No packages found.');return;}
      const count=document.createElement('span');count.textContent=(offset+1)+'–'+(offset+data.items.length)+' / '+data.total;pager.append(count);
      for(const [delta,label] of [[-limit,vt('Trước','Previous')],[limit,vt('Sau','Next')]]){
        const btn=document.createElement('button');btn.className='button small';btn.textContent=label;
        btn.disabled=offset+delta<0||offset+delta>=data.total;btn.onclick=()=>{offset+=delta;load();};pager.append(btn);
      }
    }catch(err){if(current===generation&&content.isConnected)results.textContent=err.message;}
  }
  form.onsubmit=e=>{e.preventDefault();offset=0;query=form.querySelector('input').value.trim();load();};
  load();return null;
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
          else if(endpoint()===path&&location.hash==='#overview')render();
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
  view.innerHTML=`<article class="vps-box"><header class="vps-machine"><div><h2>${escapeHTML(info.host)}</h2><p>${escapeHTML([info.os,info.arch,info.manager].filter(Boolean).join(' · '))}</p></div><button class="button small" data-tone="configure" id="account">${vt('Tài khoản & SSH','Account & SSH')}</button></header>
    <form class="hostname-form"><label>${vt('Hostname mới','New hostname')}<input name="hostname" required maxlength="63" placeholder="web-01" autocomplete="off" autocapitalize="none" spellcheck="false"></label><button type="submit" class="button small" data-tone="configure">${vt('Đổi hostname','Change hostname')}</button><output class="hostname-status" aria-live="polite"></output></form>
    <div class="overview-meters" id="ov-meters">${renderMeters(info)}</div><div class="overview-system" id="ov-system">${renderUptime(info)}</div></article>
    <div class="overview-panels">${panel('ov-processes',vt('Tác vụ đang chạy · CPU & RAM','Running processes · CPU & RAM'),'terminal','SSH Terminal','<span class="ov-live"><i></i>Live · 3s</span>')}
    ${panel('ov-sites',vt('Website & chứng chỉ','Websites & certificates'),'domains','Nginx')}
    ${panel('ov-jobs',vt('Tác vụ gần đây','Recent jobs'),'jobs',vt('Lịch sử','History'))}</div>`;
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
  populate($('#ov-jobs'),path+'/jobs',jobs=>{
    const labels={running:vt('Đang chạy','Running'),queued:vt('Đang chờ','Queued'),succeeded:vt('Hoàn tất','Completed'),failed:vt('Có lỗi','Failed'),interrupted:vt('Gián đoạn','Interrupted')};
    return jobs.slice(0,5).map(j=>row(j.label,[j.created_at?new Date(j.created_at).toLocaleString(vpsEnglish?'en-GB':'vi-VN',{day:'2-digit',month:'2-digit',hour:'2-digit',minute:'2-digit'}):'',labels[j.status]||j.status].filter(Boolean).join(' · '),j.id)).join('')||vt('Chưa ghi nhận tác vụ cho máy này.','No recorded jobs for this server.');
  });
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
  const job=jobs.find(j=>j.id===id)||jobs[0];
  if(!job){view.innerHTML='<div class="vps-box vps-empty">'+vt('Máy này chưa có tác vụ.','This server has no jobs yet.')+'</div>';return;}
  view.innerHTML='<div class="vps-jobs"><div class="vps-job-list"></div><article class="vps-box vps-job-log"></article></div>';
  const list=view.querySelector('.vps-job-list');
  const tones={queued:'warning',running:'info',succeeded:'create',failed:'remove',interrupted:'remove'};
  for(const [idx,j] of jobs.entries()){
    const btn=document.createElement('button');btn.dataset.job=j.id;btn.setAttribute('aria-pressed',String(job.id===j.id));
    const when=j.created_at?new Date(j.created_at).toLocaleTimeString():'';
    const last=(j.events||[]).at(-1)?.message||'';
    btn.innerHTML='<div style="display:flex;justify-content:space-between;gap:6px;align-items:center"><strong>'+(idx+1)+'. '+escapeHTML(j.label)+'</strong><span class="site-tag" data-tone="'+(tones[j.status]||'info')+'">'+escapeHTML(labels[j.status]||j.status)+'</span></div>'
      +(last&&last!==j.label?'<small style="color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis">'+escapeHTML(last)+'</small>':'')
      +(when?'<span>'+escapeHTML(when)+'</span>':'');
    list.append(btn);
  }
  const detail=view.querySelector('.vps-job-log');
  const started=job.created_at?new Date(job.created_at).toLocaleString():'';
  detail.innerHTML='<div style="display:flex;justify-content:space-between;align-items:center;gap:8px;flex-wrap:wrap"><h2>'+escapeHTML(job.label)+'</h2><span class="site-tag" data-tone="'+(tones[job.status]||'info')+'">'+escapeHTML(labels[job.status]||job.status)+'</span></div><p>'+escapeHTML(job.target)+(started?' · '+escapeHTML(started):'')+'</p><pre>'+escapeHTML((job.events||[]).map(e=>e.message).join('\n')||'…')+'</pre>';
  if(job.error){const error=document.createElement('div');error.className='callout error';error.style.margin='8px 0 0';error.textContent=job.error;detail.append(error);}
  if(job.result){const result=document.createElement('pre');result.textContent=JSON.stringify(job.result,null,2);detail.append(result);}
}
