// "Máy chủ": list and manage saved SSH machines (shared records with MongoDB Manager).
async function serversPage(view,path,rev){
  const byHost=(a,b)=>String(a.name||a.host||'').localeCompare(String(b.name||b.host||''),undefined,{numeric:true,sensitivity:'base'});
  const [rawList,clusters]=await Promise.all([api('vps/servers'),api('vps/clusters').catch(()=>[])]);
  const list=rawList.sort((a,b)=>(Number(Boolean(a.profile_id))-Number(Boolean(b.profile_id)))||byHost(a,b));
  const clusterNames=new Map((clusters||[]).map(c=>[c.id,c.name]));
  if(rev!==revision)return;
  const svgIcon=d=>'<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="'+d+'"/></svg>';
  const add=document.createElement('button');add.type='button';add.className='button';add.dataset.tone='create';add.textContent='+ '+vt('Thêm máy chủ','Add server');add.onclick=()=>addVps();
  const bulkAdd=document.createElement('button');bulkAdd.type='button';bulkAdd.className='button';bulkAdd.textContent='+ '+vt('Thêm từ Seed list','Add from Seed list');bulkAdd.onclick=()=>addFromSeeds();
  const copyIps=document.createElement('button');copyIps.type='button';copyIps.className='button';
  const copyIpsHtml=svgIcon('M9 9h11v11H9z M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1')+' '+vt('Copy IP VPS','Copy VPS IPs');
  copyIps.innerHTML=copyIpsHtml;
  copyIps.onclick=async()=>{
    const ips=[...new Set(list.filter(m=>m.mode==='ssh'&&m.host).map(m=>m.host))];
    if(!ips.length)return;
    await navigator.clipboard?.writeText(ips.join('\n'));
    copyIps.textContent='✓ '+vt('Đã copy '+ips.length+' IP','Copied '+ips.length+' IPs');
    setTimeout(()=>{copyIps.innerHTML=copyIpsHtml;},2500);
  };
  const bulkCheck=document.createElement('button');bulkCheck.type='button';bulkCheck.className='button';bulkCheck.dataset.tone='create';bulkCheck.hidden=true;
  const bulkDel=document.createElement('button');bulkDel.type='button';bulkDel.className='button';bulkDel.dataset.tone='remove';bulkDel.hidden=true;
  const clusterBtn=document.createElement('button');clusterBtn.type='button';clusterBtn.className='button small';clusterBtn.dataset.tone='configure';
  clusterBtn.innerHTML=svgIcon('M9 3h6v5H9z M2 16h6v5H2z M16 16h6v5h-6z M12 8v4 M5 16v-4h14v4')+' '+vt('Gán cụm','Assign cluster');
  const selectedIds=new Set();
  function picked(){return list.filter(m=>selectedIds.has(m.id));}
  clusterBtn.onclick=async()=>{
    const latestClusters=await api('vps/clusters').catch(()=>clusters);
    const draft=new Map(list.map(m=>[m.id,m.profile_id||'']));
    const checkedIds=new Set(picked().map(m=>m.id));
    const clusterOpts=sel=>'<option value=""'+(!sel?' selected':'')+'>'+escapeHTML(vt('Độc lập (không thuộc cụm)','Standalone (unlinked)'))+'</option>'+(latestClusters||[]).map(c=>'<option value="'+escapeHTML(c.id)+'"'+(c.id===sel?' selected':'')+'>'+escapeHTML(c.name)+'</option>').join('');
    const filterOpts='<option value="__all__">'+escapeHTML(vt('Tất cả trạng thái','All servers'))+'</option><option value="">'+escapeHTML(vt('Chỉ máy độc lập','Standalone only'))+'</option>'+(latestClusters||[]).map(c=>'<option value="'+escapeHTML(c.id)+'">'+escapeHTML(c.name)+'</option>').join('');
    modal(vt('Gán / đổi / gỡ cụm cho máy chủ','Assign, change or unlink cluster'),
      '<div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">'
      +'<input class="search-box" type="search" id="vps-cluster-find" style="flex:1;min-width:180px;max-width:none" placeholder="'+escapeHTML(vt('Tìm máy chủ, IP…','Find server, IP…'))+'">'
      +'<select id="vps-cluster-filter" style="padding:8px 10px;border:1px solid var(--line);border-radius:6px;background:#fff">'+filterOpts+'</select>'
      +'</div>'
      +'<div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-top:10px;padding:8px 10px;background:#f7faf8;border:1px solid var(--line);border-radius:8px">'
      +'<button type="button" class="button small" id="vc-pick-all">'+escapeHTML(vt('Chọn tất cả','Select all'))+'</button>'
      +'<button type="button" class="button small" id="vc-pick-none">'+escapeHTML(vt('Bỏ chọn','Clear'))+'</button>'
      +'<select id="vc-batch-target" style="flex:1;min-width:160px;padding:6px 8px;border:1px solid var(--line);border-radius:6px;background:#fff">'+clusterOpts('')+'</select>'
      +'<button type="button" class="button small" data-tone="configure" id="vc-batch-apply">'+escapeHTML(vt('Gán các máy đã tick','Apply to checked'))+'</button>'
      +'</div>'
      +'<small id="vps-cluster-meta" style="display:block;margin-top:6px;color:var(--muted)"></small>'
      +'<div id="vps-cluster-list" style="margin-top:6px;max-height:260px;overflow:auto;border:1px solid var(--line);border-radius:8px;padding:6px 10px"></div>',
      async()=>{
        const updates=list.filter(m=>(draft.get(m.id)||'')!==(m.profile_id||''));
        if(!updates.length)return;
        await Promise.all(updates.map(m=>api('vps/servers/'+encodeURIComponent(m.id)+'/cluster',{profile_id:draft.get(m.id)||''},'PATCH')));
        await loadHosts();render();
      });
    const listBox=$('#vps-cluster-list'),metaBox=$('#vps-cluster-meta'),findBox=$('#vps-cluster-find'),filterBox=$('#vps-cluster-filter');
    const getMatched=()=>{
      const q=(findBox.value||'').toLowerCase().trim(),f=filterBox.value;
      return list.filter(m=>{
        const pid=draft.get(m.id)||'';
        if(f!=='__all__'&&pid!==f)return false;
        return !q||(m.name+' '+(m.host||'')+' '+(m.mongo_endpoint||'')).toLowerCase().includes(q);
      });
    };
    const updateMeta=(shownLen,totalLen)=>{
      const changed=list.filter(m=>(draft.get(m.id)||'')!==(m.profile_id||'')).length;
      metaBox.textContent=vt('Đã tick ','Checked ')+checkedIds.size+' · '+vt('Sẽ đổi ','Changed ')+changed+' · '+vt('Hiển thị ','Showing ')+shownLen+'/'+totalLen;
    };
    const drawModalList=()=>{
      const matched=getMatched(),shown=matched.slice(0,100);
      listBox.innerHTML=shown.map(m=>{
        const curPid=draft.get(m.id)||'',dirty=curPid!==(m.profile_id||'');
        return '<div style="display:flex;align-items:center;justify-content:space-between;gap:8px;padding:5px 0;border-bottom:1px solid #eef2ee">'
          +'<label style="display:flex;align-items:center;gap:8px;min-width:0;flex:1;cursor:pointer"><input type="checkbox" value="'+escapeHTML(m.id)+'" '+(checkedIds.has(m.id)?'checked':'')+'><span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap"><strong>'+escapeHTML(m.name)+'</strong>'+(m.host?' <small style="color:var(--muted)">'+escapeHTML(m.host)+'</small>':'')+'</span></label>'
          +'<select data-mid="'+escapeHTML(m.id)+'" style="padding:4px 8px;border:1px solid '+(dirty?'var(--green)':'var(--line)')+';border-radius:6px;background:'+(dirty?'#edf7f1':'#fff')+';max-width:190px">'+clusterOpts(curPid)+'</select>'
          +'</div>';
      }).join('')||'<small>'+vt('Không có máy chủ phù hợp.','No matching servers.')+'</small>';
      updateMeta(shown.length,matched.length);
    };
    listBox.onchange=e=>{
      if(e.target.type==='checkbox'){if(e.target.checked)checkedIds.add(e.target.value);else checkedIds.delete(e.target.value);drawModalList();}
      else if(e.target.dataset.mid){draft.set(e.target.dataset.mid,e.target.value);drawModalList();}
    };
    $('#vc-pick-all').onclick=()=>{for(const m of getMatched())checkedIds.add(m.id);drawModalList();};
    $('#vc-pick-none').onclick=()=>{checkedIds.clear();drawModalList();};
    $('#vc-batch-apply').onclick=()=>{
      let alertEl=$('#fields [role=alert]');
      if(!checkedIds.size){
        if(!alertEl){alertEl=document.createElement('p');alertEl.setAttribute('role','alert');$('#fields').append(alertEl);}
        alertEl.textContent=vt('Tick ít nhất một máy chủ để gán hàng loạt, hoặc đổi trực tiếp ở từng dòng.','Check at least one server for batch apply, or change each row directly.');
        return;
      }
      alertEl?.remove();
      const target=$('#vc-batch-target').value;
      for(const id of checkedIds)draft.set(id,target);
      drawModalList();
    };
    findBox.oninput=filterBox.onchange=drawModalList;
    drawModalList();
  };
  $('#heading-actions').append(bulkCheck,bulkDel,copyIps,bulkAdd,add);
  view.innerHTML='<section class="panel"><div class="panel-head"><div><h2>'+vt('Danh sách máy chủ','Servers')+'</h2></div><div class="actions" id="srv-panel-actions"><input class="search-box" type="search" id="find-server" placeholder="'+vt('Tìm máy chủ, IP…','Find server, IP…')+'"></div></div><div class="table-wrap"><table><thead><tr><th><input type="checkbox" id="select-all-servers" aria-label="Chọn tất cả"></th><th>#</th><th>'+vt('MÁY CHỦ','SERVER')+'</th><th>'+vt('KẾT CHỦ','CONNECTION').replace('KẾT CHỦ','KẾT NỐI')+'</th><th>'+vt('XÁC THỰC','AUTH')+'</th><th></th></tr></thead><tbody></tbody></table></div><div class="panel-foot" id="srv-pager"></div></section>';
  $('#srv-panel-actions').append(clusterBtn);
  const body=view.querySelector('tbody'),pager=$('#srv-pager'),pickAll=$('#select-all-servers');
  let page=1,pageSize=Number(sessionStorage.getItem('vps-srv-ps')||25),query='';
  function syncBulk(){
    const n=selectedIds.size;
    bulkCheck.hidden=bulkDel.hidden=!n;
    bulkCheck.textContent=vt('Kiểm tra ('+n+')','Check ('+n+')');
    bulkDel.textContent=vt('Xóa ('+n+')','Delete ('+n+')');
  }
  function drawPage(){
    const q=query.toLowerCase().trim();
    const filtered=q?list.filter(m=>(m.name+' '+(m.host||'')+' '+(m.user||'')+' '+(m.mongo_endpoint||'')).toLowerCase().includes(q)):list;
    const totalPages=Math.max(1,Math.ceil(filtered.length/pageSize));
    if(page>totalPages)page=totalPages;
    const start=(page-1)*pageSize;
    const slice=filtered.slice(start,start+pageSize);
    body.replaceChildren();
    if(!slice.length){
      body.innerHTML='<tr><td colspan="6">'+(list.length?vt('Không tìm thấy máy chủ phù hợp.','No matching servers.'):vt('Chưa có máy chủ.','No servers yet.'))+'</td></tr>';
    }
    const icon='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true"><path d="M4 4h16v6H4z M4 14h16v6H4z M7 7h.01 M7 17h.01"/></svg>';
    const badge=(t,c)=>'<span class="badge '+c+'">'+t+'</span>';
    slice.forEach((m,idx)=>{
      const tr=document.createElement('tr');
      const ipLabel=m.host||(m.mongo_endpoint?m.mongo_endpoint.replace(/:\d+$/,''):'');
      const clusterLabel=m.profile_id?(clusterNames.get(m.profile_id)||vt('Thuộc cụm MongoDB','In a MongoDB cluster')):vt('Chưa liên kết cụm','Unlinked');
      tr.innerHTML='<td><input type="checkbox" class="srv-pick" value="'+escapeHTML(m.id)+'" '+(selectedIds.has(m.id)?'checked':'')+'></td><td class="row-number">'+(start+idx+1)+'</td><td><div class="host-cell"><span class="server-icon">'+icon+'</span><div><strong>'+escapeHTML(m.name)+'</strong>'+(ipLabel?'<small class="mongo-address">'+escapeHTML(ipLabel)+'</small>':'')+'<small>'+escapeHTML(clusterLabel)+'</small></div></div></td><td>'+badge(m.mode==='ssh'?'SSH':'LOCAL','dark')+' '+(m.mode==='ssh'?'<span class="mono ssh-address">'+escapeHTML(m.user+'@'+(m.host.includes(':')?'['+m.host+']':m.host)+':'+m.port)+'</span>':'')+'</td><td>'+(m.mode==='local'?'—':m.ssh_auth==='password'?vt('Mật khẩu SSH','SSH password')+(m.has_ssh_password?' ✓':''):'SSH key / Agent')+'</td><td><div class="actions"></div></td>';
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
      if(!m.profile_id)mk(vt('Xóa','Delete'),'remove',()=>modal(vt('Xóa hồ sơ máy chủ','Delete server record'),'<p>'+escapeHTML(m.name)+' · '+escapeHTML(vt('Hồ sơ chỉ bị xóa khỏi Manager. Dữ liệu và dịch vụ trên VPS giữ nguyên.','Only the Manager record is removed. Data and services on the VPS stay untouched.'))+'</p>',async()=>{await api('vps/servers/'+encodeURIComponent(m.id),undefined,'DELETE');selectedIds.delete(m.id);setTimeout(()=>loadHosts(),0);}));
      body.append(tr);
    });
    if(pickAll){
      pickAll.checked=slice.length>0&&slice.every(m=>selectedIds.has(m.id));
      pickAll.indeterminate=slice.some(m=>selectedIds.has(m.id))&&!pickAll.checked;
    }
    pager.innerHTML='<div class="actions"><label style="font-size:11px;display:inline-flex;align-items:center;gap:6px">'+vt('Hiển thị','Show')+' <select id="srv-ps" style="padding:3px 6px;border:1px solid var(--line);border-radius:6px">'+[25,50,100].map(n=>'<option value="'+n+'"'+(pageSize===n?' selected':'')+'>'+n+'</option>').join('')+'</select></label><span>'+vt('Trang ','Page ')+page+'/'+totalPages+' ('+filtered.length+' '+vt('máy','servers')+')</span></div><div class="actions"><button type="button" class="button small" id="srv-prev"'+(page<=1?' disabled':'')+'>‹ '+vt('Trước','Prev')+'</button><button type="button" class="button small" id="srv-next"'+(page>=totalPages?' disabled':'')+'>'+vt('Sau','Next')+' ›</button></div>';
    $('#srv-ps').onchange=e=>{pageSize=Number(e.target.value);sessionStorage.setItem('vps-srv-ps',String(pageSize));page=1;drawPage();};
    $('#srv-prev').onclick=()=>{if(page>1){page--;drawPage();}};
    $('#srv-next').onclick=()=>{if(page<totalPages){page++;drawPage();}};
  }
  if(pickAll)pickAll.onchange=()=>{
    const q=query.toLowerCase().trim();
    const filtered=q?list.filter(m=>(m.name+' '+(m.host||'')+' '+(m.user||'')+' '+(m.mongo_endpoint||'')).toLowerCase().includes(q)):list;
    const slice=filtered.slice((page-1)*pageSize,page*pageSize);
    for(const m of slice){if(pickAll.checked)selectedIds.add(m.id);else selectedIds.delete(m.id);}
    drawPage();syncBulk();
  };
  body.addEventListener('change',e=>{
    if(!e.target.classList.contains('srv-pick'))return;
    if(e.target.checked)selectedIds.add(e.target.value);else selectedIds.delete(e.target.value);
    syncBulk();
  });
  $('#find-server').oninput=e=>{query=e.target.value;page=1;drawPage();};
  drawPage();
  syncBulk();
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
  const select=(name,label,options,value)=>'<label class="field">'+label+'<select name="'+name+'">'+options.map(o=>'<option value="'+escapeHTML(o[0])+'"'+(o[0]===String(value)?' selected':'')+'>'+escapeHTML(o[1])+'</option>').join('')+'</select></label>';
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
