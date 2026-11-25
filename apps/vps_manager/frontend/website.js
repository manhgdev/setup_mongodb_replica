async function showWebsite(site, machinePath, currentRevision, initialTab) {
  const path = machinePath + '/nginx/' + site.file_id;
  const detail = await api(path + '/detail');
  if (revision !== currentRevision) return;
  const view = $('#view');
  const tabs = ['Cấu hình', 'SSL', 'Nhật ký', 'Chẩn đoán', 'Lịch sử thay đổi'];
  view.innerHTML = '<article class="panel website-detail"><div class="panel-head"><div><h2>' + escapeHTML(site.domain) +
    '</h2><code class="website-file">' +
    escapeHTML(site.source) + '</code></div><button class="button small" data-tone="info" id="back-sites">← Website</button></div><div class="panel-body"><div class="domain-actions" id="website-tabs"></div><section id="website-body"></section></div></article>';
  $('#back-sites').onclick = () => { history.replaceState(null, '', '#domains'); render(); };
  const body = $('#website-body');
  let generation = 0;
  async function preview(change) {
    const data = {file_id:site.file_id, revision:detail.revision, ...change};
    const result = await api(path + '/diff', data);
    if (!body.isConnected) return;
    modal('Áp dụng Nginx', '<p>' + escapeHTML(detail.domains.join(', ')) + '</p><pre>' +
      escapeHTML(result.diff || 'Không có thay đổi.') + '</pre>', async () => {
      if (result.diff) await submit('apply', data);
    });
  }
  function report(error) {
    const p = document.createElement('p'); p.setAttribute('role','alert'); p.textContent=error.message; body.append(p);
  }
  function select(tab) {
    history.replaceState(null, "", "#domains?site=" + encodeURIComponent(site.file_id) + "&tab=" + encodeURIComponent(tab));
    const active = ++generation;
    body.replaceChildren();
    for(const button of $('#website-tabs').children)button.classList.toggle('primary',button.dataset.tab===tab);
    if(tab===tabs[0]){
      const wrap=document.createElement('div');wrap.className='nginx-code-wrap';
      const highlighted=document.createElement('pre');highlighted.className='nginx-highlight';highlighted.setAttribute('aria-hidden','true');
      const editor=document.createElement('textarea');
      editor.className='nginx-editor';editor.setAttribute('aria-label','Nginx');editor.spellcheck=false;
      editor.value=detail.source;editor.readOnly=!detail.editable;
      wrap.append(highlighted,editor);body.append(wrap);
      function highlight(){
        highlighted.innerHTML=escapeHTML(editor.value+'\n').replace(/(#[^\n]*|\$[A-Za-z_]\w*|\b(?:server|listen|include|location|upstream|root|return|proxy_pass|server_name|ssl_certificate|ssl_certificate_key|add_header|fastcgi_pass|grpc_pass|keepalive|least_conn)\b)/g,
          match=>'<span class="'+(match.startsWith('#')?'syntax-comment':'syntax-directive')+'">'+match+'</span>');
      }
      highlight();
      editor.oninput=highlight;
      editor.onscroll=()=>{highlighted.scrollTop=editor.scrollTop;highlighted.scrollLeft=editor.scrollLeft;};
      if(detail.editable){
        const toolbar=document.createElement('div');toolbar.className='editor-actions';body.append(toolbar);
        const check=document.createElement('button');check.className='button';check.dataset.tone='configure';check.textContent='nginx -t';
        check.onclick=async()=>{
          check.disabled=true;
          try{await api(path+'/check',{source:editor.value,revision:detail.revision});check.textContent='nginx -t ✓';}
          catch(err){report(err);}finally{check.disabled=false;}
        };
        editor.addEventListener('input',()=>{check.textContent='nginx -t';});toolbar.append(check);
        const btn=document.createElement('button');btn.className='button primary';btn.textContent='Xem thay đổi';
        btn.onclick=()=>preview({source:editor.value}).catch(report);toolbar.append(btn);
      }
    }else if(tab===tabs[1]){
      body.textContent=site.https?'HTTPS · '+(site.expires===null?'—':site.expires+' ngày'):'HTTP';
      api(path+'/ssl-status?domain='+encodeURIComponent(site.domain)).then(status=>{
        if(active!==generation)return;
        const info=document.createElement('pre');info.textContent=['certbot.timer · '+status.timer,
          'cron · '+(status.cron?'✓':'—'),status.served?'SNI · '+status.served.names.join(', ')+' · '+status.served.expires:status.error].join('\n');
        body.append(info);
      }).catch(report);
    }else if(tab===tabs[2]){
      const toggle=document.createElement('button'), log=document.createElement('pre');
      toggle.className='button small';let paused=false;toggle.textContent='Tạm dừng';
      toggle.onclick=()=>{paused=!paused;toggle.textContent=paused?'Tiếp tục':'Tạm dừng';};
      body.append(toggle,log);
      const cursors={}, windows=new Map();
      async function poll(){
        if(!body.isConnected||active!==generation)return;
        if(!paused){
          try{
            const records=await api(path+'/logs?cursor='+encodeURIComponent(JSON.stringify(cursors)));
            for(const r of records){
              cursors[r.path]=r.cursor;
              const lines=(windows.get(r.path)||[]).concat(r.lines).slice(-200);
              windows.set(r.path,lines);
            }
            log.textContent=records.map(r=>{
              const lines=windows.get(r.path),counts={},times=[];
              if(r.kind==='access_log')for(const line of lines){
                const match=line.match(/\[([^\]]+)\] "[^"]*" ([1-5])\d{2} /);
                if(match){const group=match[2]+'xx';counts[group]=(counts[group]||0)+1;times.push(match[1]);}
              }
              return [r.path,[times[0],times.at(-1),Object.entries(counts).map(([k,v])=>k+' · '+v).join(' | ')].filter(Boolean).join(' — '),...lines].join('\n');
            }).join('\n\n')||'Chưa tìm thấy log riêng trong cấu hình website.';
          }catch(err){log.textContent=err.message;}
        }
        if(body.isConnected&&active===generation)setTimeout(poll,3000);
      }
      poll();
    }else if(tab===tabs[3]){
      body.textContent=detail.diagnostics.join('\n')||'Không có lỗi cấu hình được ghi nhận.';
    }else{
      for(const snapshot of detail.history){
        const btn=document.createElement('button');btn.className='button small';
        btn.textContent=new Date(Number(BigInt(snapshot.split('.')[0])/1000000n)).toLocaleString();
        btn.disabled=!detail.editable;btn.onclick=()=>preview({snapshot}).catch(report);body.append(btn);
      }
      if(!detail.history.length)body.textContent='Chưa có bản sao từ editor.';
    }
  }
  for(const tab of tabs){
    const btn=document.createElement('button');btn.className='button small';btn.dataset.tab=tab;
    btn.textContent=tab;btn.onclick=()=>select(tab);$('#website-tabs').append(btn);
  }
  select(tabs.includes(initialTab) ? initialTab : tabs[0]);
}
