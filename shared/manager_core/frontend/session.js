function managerLogin(editAccount=false){
  const params=new URLSearchParams({next:location.pathname+location.search+location.hash});
  if(editAccount)params.set('account','1');
  location.replace('/login?'+params);
}

window.addEventListener('storage',event=>{
  if(event.key==='mongo-manager-demo')location.reload();
});

window.zmStorageModal=async function({csrfToken,openModal,closeModal,onSwitched,en=false}){
  const t=(vi,e)=>en?e:vi;
  const req=async(url,body)=>{
    const res=await fetch(url,{method:body?'POST':'GET',headers:{'Content-Type':'application/json','X-MongoDB-Manager':'1','X-CSRF-Token':csrfToken||''},body:body?JSON.stringify(body):undefined});
    const data=await res.json().catch(()=>({}));
    if(!res.ok)throw new Error(typeof data.detail==='string'?data.detail:'HTTP '+res.status);
    return data;
  };
  const info=await req('/api/storage/config');
  const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const presets=info.presets||[];
  const presetHtml=presets.length?`<label class="field wide">${t('Chọn nhanh từ cụm MongoDB đã lưu','Quick pick from saved MongoDB cluster')}<select id="zm-st-preset"><option value="" selected>— ${t('Nhập chuỗi URI thủ công','Enter custom URI')} —</option>${presets.map(p=>`<option value="${esc(p.id)}">${esc(p.name)} (${esc(p.uri_masked)})</option>`).join('')}</select></label>`:'';
  const activeLabel=info.backend==='mongodb'?'MongoDB ('+esc(info.database)+')':'SQLite (manager.sqlite3)';
  const bodyHtml=`<div class="callout neutral" style="margin-bottom:12px">
    <strong>${t('Đang dùng: ','Active: ')}${activeLabel}</strong><br>
    <small>SQLite: ${info.sqlite_count} ${t('bản ghi','records')}${info.mongo_count!=null?' · MongoDB: '+info.mongo_count+' '+t('bản ghi','records'):''}</small>
  </div>
  <div class="form-grid" id="zm-storage-fields">
    <label class="field">${t('Chế độ lưu trữ','Storage backend')}<select name="backend" id="zm-st-backend">
      <option value="sqlite"${info.backend==='sqlite'?' selected':''}>${t('SQLite cục bộ','Local SQLite')}</option>
      <option value="mongodb"${info.backend==='mongodb'?' selected':''}>${t('MongoDB riêng','Dedicated MongoDB')}</option>
    </select></label>
    <label class="field">${t('Áp dụng cho','Apply to')}<select name="scope" id="zm-st-scope">
      <option value="both" selected>${t('Cả 2 bên (MongoDB & VPS Manager)','Both apps (MongoDB & VPS Manager)')}</option>
      <option value="single">${t('Chỉ trang hiện tại','Current app only')}</option>
    </select></label>
  </div>
  <div id="zm-mongo-only"${info.backend==='mongodb'?'':' hidden'}>
    <div class="form-grid" style="margin-top:12px">
      ${presetHtml}
      <label class="field wide">${t('Chuỗi kết nối MongoDB (URI)','MongoDB Connection URI')}<input name="uri" autocomplete="off" placeholder="${esc(info.has_uri?(t('Để trống để giữ URI đã lưu: ','Leave blank to keep: ')+info.uri_masked):'mongodb://user:pass@host:27017/?authSource=admin')}"></label>
      <label class="field wide">${t('Tên Database riêng','Database name')}<input name="database" value="${esc(info.database||'zm_manager')}" placeholder="zm_manager"><small>${t('MongoDB tự tạo database này (ví dụ zm_manager) tách biệt hoàn toàn với dữ liệu app của bạn.','MongoDB creates this database separately from your app databases.')}</small></label>
    </div>
    <div style="display:flex;flex-wrap:wrap;gap:8px;margin-top:10px">
      <button type="button" class="button small" data-tone="info" id="zm-st-test">${t('Kiểm tra kết nối','Test connection')}</button>
      <button type="button" class="button small" data-tone="create" id="zm-st-s2m">${t('Đồng bộ SQLite → MongoDB','Sync SQLite → MongoDB')}</button>
      <button type="button" class="button small" data-tone="configure" id="zm-st-m2s">${t('Đồng bộ MongoDB → SQLite','Sync MongoDB → SQLite')}</button>
    </div>
  </div>
  <output id="zm-st-out" style="display:block;margin-top:10px;font-size:12px"></output>`;
  openModal(t('Lưu trữ dữ liệu ứng dụng (SQLite / MongoDB)','App Data Storage (SQLite / MongoDB)'),bodyHtml,async formEl=>{
    const fd=formEl instanceof FormData?formEl:new FormData(formEl);
    const rootEl=document.getElementById('modal');
    const pid=rootEl.querySelector('#zm-st-preset')?.value||'';
    await req('/api/storage/switch',{backend:fd.get('backend'),scope:fd.get('scope')||'both',uri:(fd.get('uri')||'').trim(),database:(fd.get('database')||'zm_manager').trim(),profile_id:pid,auto_sync:true});
    closeModal();
    if(onSwitched)onSwitched();
  });
  const root=document.getElementById('modal');
  const out=root.querySelector('#zm-st-out'),uriInput=root.querySelector('[name=uri]'),presetSel=root.querySelector('#zm-st-preset'),backendSel=root.querySelector('#zm-st-backend'),mongoBox=root.querySelector('#zm-mongo-only');
  const syncMongoBox=()=>{if(mongoBox)mongoBox.hidden=backendSel.value!=='mongodb';};
  backendSel.onchange=syncMongoBox;syncMongoBox();
  if(presetSel){
    const byId=new Map(presets.map(p=>[p.id,p]));
    presetSel.onchange=()=>{uriInput.value=byId.get(presetSel.value)?.uri||'';};
    uriInput.oninput=()=>{if(uriInput.value.trim())presetSel.value='';};
  }
  const getParams=()=>({uri:(uriInput.value||'').trim(),database:(root.querySelector('[name=database]').value||'zm_manager').trim(),profile_id:presetSel?.value||''});
  root.querySelector('#zm-st-test').onclick=async()=>{
    out.textContent=t('Đang kiểm tra kết nối…','Testing connection…');
    try{const r=await req('/api/storage/test',getParams());out.textContent='✓ '+t('Kết nối OK','Connected')+' · MongoDB '+r.version+' · '+r.latency_ms+' ms ('+(r.collections.length?r.collections.join(', '):t('DB mới chưa có collection','New DB'))+')';}
    catch(e){out.textContent='✗ '+e.message;}
  };
  root.querySelector('#zm-st-s2m').onclick=async()=>{
    out.textContent=t('Đang đồng bộ SQLite → MongoDB…','Syncing SQLite → MongoDB…');
    try{const r=await req('/api/storage/migrate',{direction:'sqlite_to_mongo',...getParams()});out.textContent='✓ '+t('Đã đồng bộ ','Migrated ')+r.migrated+' '+t('bản ghi','records')+' ('+r.kinds+' collections)';}
    catch(e){out.textContent='✗ '+e.message;}
  };
  root.querySelector('#zm-st-m2s').onclick=async()=>{
    out.textContent=t('Đang đồng bộ MongoDB → SQLite…','Syncing MongoDB → SQLite…');
    try{const r=await req('/api/storage/migrate',{direction:'mongo_to_sqlite',...getParams()});out.textContent='✓ '+t('Đã đồng bộ ','Migrated ')+r.migrated+' '+t('bản ghi về SQLite','records to SQLite');}
    catch(e){out.textContent='✗ '+e.message;}
  };
};
