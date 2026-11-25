async function gitPage(view, path, rev) {
  view.textContent = vt('Đang đọc Git và SSH key…', 'Reading Git and SSH keys…');
  const state = await api(path+'/git/status');
  if (rev !== revision) return;
  const e = escapeHTML;
  const labels = {
    'restore-public': vt('Tạo lại public key','Recover public key'), import: vt('Nhập public key','Import public key'), refresh: vt('Làm mới','Refresh'), install: vt('Cài công cụ','Install tools'),
    update: vt('Cập nhật','Update'), identity: vt('Sửa danh tính','Edit identity'),
    create: vt('+ Tạo SSH key','+ Create SSH key'), load: vt('Nạp vào agent','Load into agent'),
    alias: vt('+ Alias','+ Alias'), test: vt('Kiểm tra kết nối','Test connection'),
    delete: vt('Xóa key','Delete key'), unalias: vt('Gỡ alias','Remove alias'), copy: vt('Sao chép','Copy')
  };
  function button(action, tone='info') {
    return `<button type="button" class="button small" data-tone="${tone}" data-git="${action}">${labels[action]}</button>`;
  }
  const ready = state.git && state.ssh;
  const unset = vt('Chưa cấu hình','Not configured');
  view.innerHTML = `<section class="vps-box docker-panel"><header><h2>${vt('Công cụ và danh tính','Tools and identity')}</h2>
    <div class="actions">${button('refresh')}${button(ready?'update':'install','create')}</div></header>
    <div class="docker-body"><div class="docker-row"><div><strong>Git · OpenSSH</strong><small>${e(state.git||'—')} · ${e(state.ssh||'—')}</small></div></div>
    <div class="docker-row"><div><strong>${e(state.username||unset)}</strong><small>${e(state.email||'—')} · Linux user: ${e(state.account||'—')}</small></div>${state.git?button('identity'):''}</div></div></section>
    <section class="vps-box docker-panel git-keys"><header><h2>SSH Key (${state.keys.length+(state.missing_public||[]).length})</h2><div class="actions">
    <a class="button small" href="https://github.com/settings/keys" rel="noopener noreferrer" target="_blank">GitHub Keys ↗</a>
    ${state.ssh?button('import')+button('create','create'):''}</div></header><div class="docker-body" id="git-keys"></div></section>`;
  const list = view.querySelector('#git-keys');
  if (!state.keys.length && !state.missing_public?.length) list.textContent=vt('Chưa có public key trong ~/.ssh của tài khoản này.','No public keys in this account’s ~/.ssh directory.');
  const providers = '<label class="field">Git provider<select name="provider">'+['github.com','gitlab.com','bitbucket.org'].map(p=>'<option>'+p+'</option>').join('')+'</select></label>';
  const pass = '<label class="field">Passphrase<input name="passphrase" type="password" autocomplete="new-password" maxlength="1024"></label>';
  function open(action, fields, params={}) {
    modal(labels[action], fields, form=>{
      if(path!==endpoint() || !view.isConnected) throw new Error(vt('Máy chủ đã thay đổi.','Selected server changed.'));
      return submit('git/'+action,{...params,...Object.fromEntries(form)});
    });
    const password = $('#fields input[type="password"]');
    if(password) $('dialog').addEventListener('close',()=>{password.value='';},{once:true});
  }
  view.querySelector('[data-git="refresh"]').onclick=render;
  view.querySelector('[data-git="install"],[data-git="update"]').onclick=()=>{
    open(ready?'update':'install','<p>Git + OpenSSH Client · '+e($('#hosts').selectedOptions[0].textContent)+'</p><code>apt-get update → apt-get install git openssh-client</code>');
  };
  if(state.git) view.querySelector('[data-git="identity"]').onclick=()=>open('identity',
    `<label class="field">Git Username<input name="username" required maxlength="128" value="${e(state.username)}"></label>
     <label class="field">Git Email<input type="email" name="email" required maxlength="254" value="${e(state.email)}"></label>`);
  if(state.ssh) view.querySelector('[data-git="import"]').onclick=()=>open('import',
    `<label class="field">${vt('Tên key','Key name')}<input name="name" required maxlength="64"></label>
     <label class="field">Public key<textarea name="public_key" required maxlength="16384" placeholder="ssh-ed25519 AAAA…"></textarea></label>`);
  if(state.ssh) view.querySelector('[data-git="create"]').onclick=()=>open('create',
    `<label class="field">${vt('Tên key','Key name')}<input name="name" required maxlength="64" placeholder="id_work"></label>
    <label class="field">${vt('Loại key','Key type')}<select name="kind"><option value="ed25519">ED25519</option><option value="rsa">RSA 4096-bit</option></select></label>
    <label class="field">Email<input type="email" name="email" value="${e(state.email)}"></label>${pass}
    <small>${vt('Có thể để trống passphrase. Nếu dùng, nhập ít nhất 5 ký tự.','Optional passphrase, at least 5 characters when set.')}</small>`);
  for (const key of state.keys) {
    const row = document.createElement('article');
    row.className='git-key';
    const params={name:key.name,fingerprint:key.fingerprint};
    row.innerHTML=`<div class="docker-row"><div><strong>${e(key.name)}</strong><small>${e(key.type)} · ${key.loaded?vt('Đã nạp vào agent','Loaded in agent'):key.paired?vt('Chưa nạp','Not loaded'):vt('Chỉ có public key','Public key only')}</small></div>
      <div class="actions">${key.paired?button('test')+button('alias')+button('load'):''}${button('delete','danger')}</div></div>
      <details><summary>Public key · ${e(key.fingerprint)}</summary><code>${e(key.public)}</code>${button('copy')}</details>`;
    list.append(row);
    row.querySelector('[data-git="copy"]').onclick=async ev=>{
      const btn=ev.currentTarget;
      try {await navigator.clipboard.writeText(key.public);btn.textContent=vt('Đã sao chép','Copied');}
      catch {const range=document.createRange();range.selectNodeContents(row.querySelector('code'));getSelection().removeAllRanges();getSelection().addRange(range);btn.textContent=vt('Nhấn Ctrl/Cmd+C','Press Ctrl/Cmd+C');}
    };
    const target='<p><strong>'+e(key.name)+'</strong> · '+e(key.fingerprint)+'</p>';
    if(key.paired){
      row.querySelector('[data-git="load"]').onclick=()=>open('load',target+pass,params);
      row.querySelector('[data-git="test"]').onclick=()=>open('test',target+providers,params);
      row.querySelector('[data-git="alias"]').onclick=()=>open('alias',target+providers+'<label class="field">Host alias<input required name="alias" maxlength="64" placeholder="github-work"></label>',params);
    }
    row.querySelector('[data-git="delete"]').onclick=()=>open('delete',target+'<p>'+vt('Xóa file key trên VPS và gỡ các alias do Manager tạo cho key này?','Delete these key files on the server and remove their Manager aliases?')+'</p>',params);
    for(const [alias,[provider,name]] of Object.entries(state.aliases)){
      if(name!==key.name) continue;
      const item=document.createElement('div');
      item.className='docker-row';
      item.innerHTML='<code>'+e('git@'+alias+' → '+provider)+'</code>'+button('unalias');
      item.querySelector('button').onclick=()=>open('unalias','<p>'+e(alias)+'</p>',{...params,alias});
      row.append(item);
    }
  }
  for(const name of state.missing_public||[]){
    const row=document.createElement('div');
    row.className='docker-row';
    row.innerHTML='<div><strong>'+e(name)+'</strong><small>'+vt('Thiếu file .pub','Missing .pub file')+'</small></div>'+button('restore-public');
    row.querySelector('button').onclick=()=>open('restore-public','<p>'+e(name)+'</p>'+pass,{name});
    list.append(row);
  }

}
