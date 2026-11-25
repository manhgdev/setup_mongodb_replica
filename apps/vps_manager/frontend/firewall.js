const fwCache=new Map();
async function fwSubmit(data,path){
  const job=await api(path+'/firewall/change',data);
  if($('dialog')?.open)$('dialog').close();
  const view=$('#view');
  const banner=document.createElement('div');banner.className='fw-job-banner';banner.innerHTML='<span class="spinner"></span><span></span><button type="button" class="banner-close" aria-label="Đóng">×</button>';banner.querySelector('.banner-close').onclick=()=>banner.remove();vpsToastStack().append(banner);
  const spin=banner.querySelector('.spinner'),msg=banner.querySelector('span:not(.spinner)');banner.dataset.state='running';if(spin)spin.hidden=false;msg.textContent=vt('Đang thực hiện…','Running…');
  for(let i=0;i<600;i++){
    await new Promise(r=>setTimeout(r,1000));
    if(location.hash!=='#firewall')return;
    const j=await api('vps/jobs/'+encodeURIComponent(job.id));
    const last=j.events?.at(-1)?.message;
    msg.textContent=(last||vt('Đang thực hiện…','Running…'))+' ('+(i+1)+'s)';
    if(j.status==='succeeded'){fwCache.delete($('#hosts').value);await vpsGetCache.clear();render();return;}
    if(j.status==='failed'||j.status==='interrupted'){
      banner.remove();
      const logs=(j.events||[]).map(e=>e.message).filter(Boolean).slice(-8).join('\n');
      modal('✗ '+(j.label||vt('Thất bại','Failed')),'<div class="callout error" style="white-space:pre-wrap">'+escapeHTML(j.error||vt('Thao tác bị gián đoạn hoặc thất bại.','Action interrupted or failed.'))+'</div>'+(logs?'<details><summary>'+vt('Nhật ký gần nhất','Recent logs')+'</summary><pre>'+escapeHTML(logs)+'</pre></details>':''),async()=>{});
      return;
    }
  }
}
// Firewall page: Ubuntu UFW and Oracle Cloud (Security List / NSG) in one view.
const fwStates={open:['Mở','Open','create'],restricted:['Giới hạn IP','Restricted','warning'],closed:['Đóng','Closed','remove'],denied:['Chặn','Denied','remove'],inactive:['UFW tắt','UFW off','warning']};
const fwWarnings={
  oci_blocked:['UFW đã mở nhưng Oracle Cloud vẫn chặn port này. Dùng “Mở port” và chọn Oracle Cloud.','UFW is open but Oracle Cloud still blocks this port. Use “Open port” and select Oracle Cloud.'],
  ufw_blocked:['Oracle Cloud đã mở nhưng UFW đang chặn port này.','Oracle Cloud allows this port but UFW blocks it.'],
  local_only:['Chỉ nghe 127.0.0.1 (nội bộ).','127.0.0.1 only (local).'],
  blocked_elsewhere:['UFW/Oracle đã mở, LISTEN và truy cập nội bộ được nhưng bên ngoài không kết nối được. Kiểm tra iptables, NAT hoặc firewall của nhà cung cấp.','Both layers allow it and it works locally, yet outside connections fail. Check iptables, NAT or provider firewalls.']
};
const fwTag=(state)=>{if(!state)return '—';const t=fwStates[state];return '<span class="site-tag" data-tone="'+t[2]+'">'+escapeHTML(vt(t[0],t[1]))+'</span>';};
const fwRange=r=>r.min===r.max?String(r.min):r.min+'-'+r.max;
async function firewallPage(view,path,rev,force=false){
  const host=$('#hosts').value;
  let s=force?null:fwCache.get(host);
  if(!s){
    if(!view.querySelector('.fw-panel'))view.innerHTML='<div class="loading"><span class="spinner"></span>'+escapeHTML(vt('Đang kiểm tra firewall…','Checking firewall…'))+'</div>';
    s=await api(path+'/firewall');
    if(rev!==revision)return;
    fwCache.set(host,s);
  }
  const oracle=s.oracle||{},oci=s.oci,vnic=oci?.vnics[0],linked=!!(s.link&&oci);
  const heading=$('#heading-actions');
  const mk=(text,tone,fn,sz='small')=>{const b=document.createElement('button');b.type='button';b.className='button'+(sz?' '+sz:'');if(tone)b.dataset.tone=tone;b.textContent=text;b.onclick=fn;return b;};
  heading.append(mk('+ '+vt('Mở port','Open port'),'create',()=>fwOpenDialog(s,path),''),mk(vt('Làm mới','Refresh'),'info',()=>{fwCache.delete(host);vpsGetCache.clear();render();},''));
  if(oracle.detected)heading.append(mk(vt('Cấu hình Oracle Cloud','Oracle Cloud setup'),'configure',()=>ociDialog(s,path),''));
  if(s.ufw.installed&&!s.ufw.active)heading.append(mk(vt('Bật UFW (giữ SSH)','Enable UFW (keep SSH)'),'warning',()=>modal('UFW','<p>'+escapeHTML(vt('Cho phép cổng SSH '+s.ssh_ports.join(', ')+'/tcp rồi bật UFW.','Allow SSH port '+s.ssh_ports.join(', ')+'/tcp, then enable UFW.'))+'</p>',()=>fwSubmit({op:'enable',layers:['ufw']},path)),''));
  const ufwText=!s.ufw.installed?vt('UFW chưa cài','UFW not installed'):s.ufw.active?vt('UFW đang bật','UFW active'):vt('UFW đang tắt','UFW inactive');
  let oracleText='';
  if(oracle.detected)oracleText=' · Oracle Cloud · '+escapeHTML(oracle.region)+' · '+escapeHTML(oracle.shape)+' · '+(linked?escapeHTML(s.link.account):vt('chưa liên kết tài khoản','account not linked'));
  const notes=[];
  if(s.oci_error)notes.push('Oracle Cloud · '+s.oci_error);
  if(s.ufw.error)notes.push('UFW · '+s.ufw.error);
  const blocked=s.rows.filter(r=>r.warnings.includes('oci_blocked'));
  if(blocked.length)notes.unshift(vt('Port UFW mở nhưng Oracle Cloud chặn: ','UFW open but Oracle Cloud blocks: ')+blocked.map(r=>r.proto+'/'+fwRange(r)).join(', '));
  view.innerHTML=`<section class="vps-box fw-panel"><header><h2>Firewall</h2><span>${escapeHTML(ufwText)}${oracleText}</span></header>
    <div class="fw-body">${notes.map(n=>'<p class="fw-note">'+escapeHTML(n)+'</p>').join('')}
    <div class="table-wrap"><table><thead><tr><th>#</th><th>Port</th><th>LISTEN</th><th>${vt('Nội bộ','Local')}</th><th>${vt('Bên ngoài','External')}</th><th>UFW</th><th>Oracle</th><th></th></tr></thead><tbody></tbody></table></div></div></section>`;
  if(oracle.detected&&!s.link){
    const box=document.createElement('section');box.className='fw-guide';
    box.innerHTML='<h3>'+vt('Kết nối Oracle Cloud để mở port từ Internet','Connect Oracle Cloud to open ports from the Internet')+'</h3>'
     +'<p>'+vt('SSH chỉ sửa được UFW bên trong VPS. Security List/NSG của Oracle nằm ở mạng ảo bên ngoài máy, chỉ thay đổi được qua OCI API bằng danh tính Oracle cấp. Thiết lập một lần, sau đó mở port bằng một nút.','SSH only changes UFW inside the VPS. Oracle Security Lists/NSGs live in the virtual network outside the machine and can only be changed through the OCI API with an Oracle identity. Set it up once, then open ports with one click.')+'</p>'
     +'<ol><li>'+vt('Mở OCI Console → ảnh đại diện → <b>User settings</b> → <b>API keys</b> → <b>Add API key</b> → <b>Generate API key pair</b> → tải <b>private key</b> → <b>Add</b>.','Open OCI Console → avatar → <b>User settings</b> → <b>API keys</b> → <b>Add API key</b> → <b>Generate API key pair</b> → download the <b>private key</b> → <b>Add</b>.')+'</li>'
     +'<li>'+vt('Màn hình “Configuration file preview” hiện <code>user</code>, <code>tenancy</code>, <code>region</code>: sao chép các giá trị này.','The “Configuration file preview” shows <code>user</code>, <code>tenancy</code>, <code>region</code>: copy these values.')+'</li>'
     +'<li>'+vt('Nếu user không phải Administrator, thêm policy (xem “Hướng dẫn thiết lập IAM” trong popup).','If the user is not an Administrator, add the policy (see “IAM setup guide” in the popup).')+'</li>'
     +'<li>'+vt('Bấm <b>Cấu hình Oracle Cloud</b> → <b>Thêm tài khoản</b>, dán OCID và private key, region <code>','Click <b>Oracle Cloud setup</b> → <b>Add account</b>, paste the OCIDs and private key, region <code>')+escapeHTML(oracle.region)+'</code>.</li>'
     +'<li>'+vt('<b>Kiểm tra kết nối</b>, chọn tài khoản cho VPS này rồi <b>Xác nhận</b>. Sau đó dùng <b>Mở port</b> và tích cả UFW lẫn Oracle Cloud.','<b>Test connection</b>, choose the account for this server and <b>Confirm</b>. Then use <b>Open port</b> with both UFW and Oracle Cloud ticked.')+'</li></ol>';
    box.append(mk(vt('Cấu hình Oracle Cloud','Oracle Cloud setup'),'configure',()=>ociDialog(s,path)));
    view.querySelector('.fw-body').prepend(box);
  }
  const body=view.querySelector('tbody');
  if(!s.rows.length)body.innerHTML='<tr><td colspan="8">'+escapeHTML(vt('Chưa có port nào đang LISTEN hoặc có rule.','No listening ports or rules yet.'))+'</td></tr>';
  for(const [idx,r] of s.rows.entries()){
    const tr=document.createElement('tr');
    const listen=r.listening.length?r.listening.map(l=>escapeHTML((l.process||'?')+(r.min===r.max?'':':'+l.port))).join(', '):'—';
    const internal=r.internal===null?'—':r.internal?vt('Truy cập được','Reachable'):vt('Không kết nối','Refused');
    const external=r.external===null?(r.proto==='udp'?vt('Không kiểm tra UDP','UDP not probed'):'—'):r.external==='open'?vt('Truy cập được','Reachable'):vt('Không kết nối','Unreachable');
    tr.innerHTML='<td class="row-number">'+(idx+1)+'</td><td><code>'+escapeHTML(r.proto+'/'+fwRange(r))+'</code></td><td>'+listen+'</td><td>'+escapeHTML(internal)+'</td><td>'+escapeHTML(external)+'</td><td>'+fwTag(r.ufw)+'</td><td>'+fwTag(r.oci)+'</td><td class="fw-actions"></td>';
    const act=tr.lastElementChild;
    const protectedPort=r.proto==='tcp'&&s.ssh_ports.some(p=>p>=r.min&&p<=r.max);
    if(r.warnings.length){const w=document.createElement('small');w.className='site-warning';w.textContent=r.warnings.map(k=>vt(...fwWarnings[k])).join(' ');tr.children[1].append(w);}
    if(r.warnings.includes('oci_blocked'))act.append(mk(vt('Mở Oracle','Open Oracle'),'create',()=>fwOpenDialog(s,path,{port:fwRange(r),proto:r.proto,layers:['oci']})));
    if(protectedPort){const l=document.createElement('small');l.textContent='SSH';act.append(l);}
    else{
      if(r.ufw!=='open'||(oracle.detected&&r.oci!=='open'))act.append(mk(vt('Mở','Open'),'create',()=>fwOpenDialog(s,path,{port:fwRange(r),proto:r.proto})));
      act.append(mk(vt('Đóng','Close'),'remove',()=>fwCloseDialog(s,path,r)));
    }
    body.append(tr);
  }
  if(vnic){
    const d=document.createElement('details');d.className='fw-oci';
    const count=l=>l.rules.length+' rule';
    d.innerHTML='<summary>Oracle Cloud · '+escapeHTML(oci.instance.name)+'</summary><dl><dt>Instance</dt><dd><code>'+escapeHTML(oci.instance.id)+'</code> · '+escapeHTML(oci.instance.state)+'</dd><dt>VNIC</dt><dd><code>'+escapeHTML(vnic.id)+'</code> · '+escapeHTML(vnic.private_ip)+(vnic.public_ip?' → '+escapeHTML(vnic.public_ip):'')+'</dd><dt>VCN</dt><dd>'+escapeHTML(vnic.vcn.name)+' · '+escapeHTML(vnic.vcn.cidr)+'</dd><dt>Subnet</dt><dd>'+escapeHTML(vnic.subnet.name)+' · '+escapeHTML(vnic.subnet.cidr)+'</dd><dt>Security List</dt><dd>'+(vnic.security_lists.map(l=>escapeHTML(l.name)+' · '+count(l)).join('<br>')||'—')+'</dd><dt>NSG</dt><dd>'+(vnic.nsgs.map(l=>escapeHTML(l.name)+' · '+count(l)).join('<br>')||'—')+'</dd></dl>';
    view.querySelector('.fw-body').append(d);
  }
}
function fwLayerFields(s,layers){
  const ociOk=!!(s.oci&&s.link),ufwOk=s.ufw.installed;
  const note=!s.oracle.detected?'':ociOk?'':'<small>'+escapeHTML(vt('Chưa liên kết tài khoản OCI: SSH không sửa được Security List. Đóng popup và làm theo hướng dẫn “Kết nối Oracle Cloud” trên trang Firewall.','No OCI account linked: SSH cannot change Security Lists. Close this popup and follow “Connect Oracle Cloud” on the Firewall page.'))+'</small>';
  return '<fieldset><legend>'+vt('Áp dụng cho','Apply to')+'</legend><label><input type="checkbox" name="ufw" '+(ufwOk&&layers.includes('ufw')?'checked':'')+(ufwOk?'':' disabled')+'> Ubuntu UFW</label>'
   +(s.oracle.detected?' <label><input type="checkbox" name="oci" '+(ociOk&&layers.includes('oci')?'checked':'')+(ociOk?'':' disabled')+'> Oracle Cloud</label>'+note:'')+'</fieldset>';
}
function fwSelected(form){return ['ufw','oci'].filter(k=>form.get(k));}
function fwOpenDialog(s,path,preset={}){
  const vnic=s.oci?.vnics[0],layers=preset.layers||['ufw','oci'];
  const targets=vnic?'<label class="field">'+vt('Vị trí rule Oracle','Oracle rule location')+'<select name="oci_target"><option value="auto">'+vt('Tự chọn (NSG trước, rồi Security List)','Automatic (NSG first, then Security List)')+'</option>'+vnic.nsgs.map(n=>'<option value="nsg:'+escapeHTML(n.id)+'">NSG · '+escapeHTML(n.name)+'</option>').join('')+vnic.security_lists.map(n=>'<option value="sl:'+escapeHTML(n.id)+'">Security List · '+escapeHTML(n.name)+'</option>').join('')+'</select></label>':'';
  modal(vt('Mở port','Open port'),'<p>'+escapeHTML($('#hosts').selectedOptions[0].textContent)+'</p><label class="field">Port<input name="port" required placeholder="443 / 8000-8100" value="'+escapeHTML(preset.port||'')+'"></label>'
   +'<fieldset><legend>'+vt('Giao thức','Protocol')+'</legend><label><input type="checkbox" name="tcp" '+(preset.proto==='udp'?'':'checked')+'> TCP</label> <label><input type="checkbox" name="udp" '+(preset.proto==='udp'?'checked':'')+'> UDP</label></fieldset>'
   +'<label class="field">Source CIDR<input name="source" value="0.0.0.0/0" placeholder="0.0.0.0/0"></label>'+fwLayerFields(s,layers)+targets
   +'<p><small>'+escapeHTML(vt('Không tạo rule trùng, không ghi đè rule hiện có. Port SSH được bảo vệ.','No duplicate rules and no overwrites. SSH ports are protected.'))+'</small></p>',
   form=>{
     const protocols=['tcp','udp'].filter(k=>form.get(k)),selected=fwSelected(form);
     if(!selected.length)throw new Error(vt('Chọn ít nhất một lớp firewall.','Select at least one firewall layer.'));
     if(!protocols.length)throw new Error(vt('Chọn TCP hoặc UDP.','Select TCP or UDP.'));
     return fwSubmit({op:'open',port:form.get('port').trim(),protocols,source:form.get('source').trim(),layers:selected,oci_target:form.get('oci_target')||'auto'},path);
   });
}
function fwCloseDialog(s,path,r){
  const vnic=s.oci?.vnics[0];
  modal(vt('Đóng port','Close port'),'<p>'+escapeHTML($('#hosts').selectedOptions[0].textContent)+' · <code>'+escapeHTML(r.proto+'/'+fwRange(r))+'</code></p><label class="field">Source CIDR<input name="source" value="0.0.0.0/0"></label>'+fwLayerFields(s,['ufw','oci'])
   +'<p><small>'+escapeHTML(vt('Chỉ xóa rule khớp chính xác port, giao thức và source. Rule rộng hơn được giữ nguyên.','Only rules matching port, protocol and source exactly are removed. Wider rules are kept.'))+'</small></p>'
   +(vnic&&s.link?'<input type="hidden" name="oci_target" value="auto">':''),
   form=>{const selected=fwSelected(form);if(!selected.length)throw new Error(vt('Chọn ít nhất một lớp firewall.','Select at least one firewall layer.'));
     return fwSubmit({op:'close',port:fwRange(r),protocols:[r.proto],source:form.get('source').trim(),layers:selected,oci_target:'auto'},path);});
}
function ociAccountDialog(s,path,account){
  const edit=!!account,a=account||{auth:'api_key',region:s.oracle.region||''};
  modal(edit?vt('Sửa tài khoản Oracle Cloud','Edit Oracle Cloud account'):vt('Thêm tài khoản Oracle Cloud','Add Oracle Cloud account'),
   '<label class="field">'+vt('Tên','Name')+'<input name="name" required maxlength="80" value="'+escapeHTML(a.name||'')+'"></label>'
   +'<label class="field">'+vt('Cách xác thực','Authentication')+'<select name="auth"><option value="api_key">API Key</option><option value="instance_principal">Instance Principal</option></select></label>'
   +'<label class="field">Region<input name="region" required placeholder="ap-singapore-1" value="'+escapeHTML(a.region||'')+'"></label>'
   +'<div class="oci-key-fields">'
   +'<label class="field">'+vt('Dán nhanh cấu hình OCI ([DEFAULT] từ Console — tùy chọn)','Quick paste OCI config ([DEFAULT] from Console — optional)')+'<textarea id="oci-config-paste" rows="3" spellcheck="false" placeholder="[DEFAULT]&#10;user=ocid1.user...&#10;tenancy=ocid1.tenancy...&#10;region=ap-singapore-2"></textarea></label>'
   +'<label class="field">Tenancy OCID<input name="tenancy" value="'+escapeHTML(a.tenancy||'')+'"></label><label class="field">User OCID<input name="user" value="'+escapeHTML(a.user||'')+'"></label>'
   +'<label class="field">Fingerprint ('+vt('tự tính nếu để trống','computed when empty')+')<input name="fingerprint" value="'+escapeHTML(a.fingerprint||'')+'"></label>'
   +'<div class="oci-gen-row"><button type="button" class="button small" data-tone="create" id="oci-gen-key">'+vt('Tạo cặp khóa RSA mới','Generate new RSA key pair')+'</button> <label class="button small" style="cursor:pointer">'+vt('Chọn file .pem','Choose .pem file')+'<input type="file" id="oci-pem-file" accept=".pem,.key" hidden></label></div>'
   +'<div id="oci-pub-wrap" hidden><label class="field">'+vt('Public key (dán vào OCI Console → Paste a public key)','Public key (paste into OCI Console → Paste a public key)')+'<textarea id="oci-pub-key" rows="4" readonly spellcheck="false"></textarea></label><button type="button" class="button small" id="oci-copy-pub">'+vt('Sao chép Public key','Copy Public key')+'</button></div>'
   +'<label class="field">Private key PEM'+(edit&&a.has_key?' ('+vt('để trống để giữ key hiện tại','leave empty to keep the current key')+')':'')+'<textarea name="private_key" rows="5" autocomplete="off" spellcheck="false" placeholder="-----BEGIN PRIVATE KEY-----"></textarea></label>'
   +'<label class="field">Passphrase<input name="passphrase" type="password" autocomplete="new-password"></label></div>'
   +'<p><small>'+escapeHTML(vt('Private key được mã hóa trong kho dữ liệu của Manager và không bao giờ hiển thị lại hay ghi vào log.','The private key is encrypted in the Manager data store and is never shown again or logged.'))+'</small></p>',
   async form=>{
     const data=Object.fromEntries(form);for(const k of Object.keys(data))if(typeof data[k]==='string'&&k!=='private_key')data[k]=data[k].trim();
     await api('vps/oci/accounts'+(edit?'/'+encodeURIComponent(a.id):''),data,edit?'PUT':'POST');
     setTimeout(()=>firewallRefreshDialog(path),0);
   });
  const f=$('#popup');f.elements.auth.value=a.auth;
  f.elements.auth.onchange=()=>{const key=f.elements.auth.value==='api_key';f.querySelector('.oci-key-fields').hidden=!key;};
  f.elements.auth.onchange();
  $('#oci-gen-key').onclick=async()=>{
    const btn=$('#oci-gen-key');btn.disabled=true;
    try{
      const res=await api('vps/oci/generate-key',{});
      f.elements.private_key.value=res.private_key;
      f.elements.fingerprint.value=res.fingerprint;
      $('#oci-pub-key').value=res.public_key;
      $('#oci-pub-wrap').hidden=false;
    }catch(err){btn.textContent=err.message;}finally{btn.disabled=false;}
  };
  $('#oci-copy-pub').onclick=async()=>{
    await navigator.clipboard?.writeText($('#oci-pub-key').value);
    $('#oci-copy-pub').textContent=vt('Đã sao chép ✓','Copied ✓');
  };
  $('#oci-config-paste').oninput=e=>{
    const txt=e.target.value;
    const get=k=>txt.match(new RegExp('^'+k+'\\s*=\\s*([^\\s#]+)','m'))?.[1]||'';
    if(get('tenancy'))f.elements.tenancy.value=get('tenancy');
    if(get('user'))f.elements.user.value=get('user');
    if(get('fingerprint'))f.elements.fingerprint.value=get('fingerprint');
    if(get('region'))f.elements.region.value=get('region');
  };
  $('#oci-pem-file').onchange=async e=>{
    const file=e.target.files?.[0];if(!file)return;
    f.elements.private_key.value=await file.text();
  };
}
async function firewallRefreshDialog(path){fwCache.delete($('#hosts').value);const s=await api(path+'/firewall');fwCache.set($('#hosts').value,s);ociDialog(s,path);vpsGetCache.clear();render();}
function ociDialog(s,path){
  const link=s.link||{};
  modal(vt('Cấu hình Oracle Cloud','Oracle Cloud setup'),
   '<p>'+escapeHTML($('#hosts').selectedOptions[0].textContent)+(s.oracle.detected?' · <code>'+escapeHTML(s.oracle.region)+'</code> · <code>'+escapeHTML(s.oracle.instance_id)+'</code>':'')+'</p>'
   +'<label class="field">'+vt('Tài khoản dùng cho VPS này','Account for this server')+'<select name="account"><option value="">—</option>'+s.accounts.map(a=>'<option value="'+escapeHTML(a.id)+'" '+(a.id===link.account_id?'selected':'')+'>'+escapeHTML(a.name+' · '+(a.auth==='api_key'?'API Key':'Instance Principal'))+'</option>').join('')+'</select></label>'
   +'<label class="field">Region ('+vt('để trống để dùng region của VPS','empty uses the server region')+')<input name="region" placeholder="'+escapeHTML(s.oracle.region||'ap-singapore-1')+'" value="'+escapeHTML(link.region||'')+'"></label>'
   +'<div class="oci-accounts">'+s.accounts.map(a=>'<div class="oci-account" data-id="'+escapeHTML(a.id)+'"><strong>'+escapeHTML(a.name)+'</strong><small>'+escapeHTML(a.region)+'</small><span class="oci-result"></span><button type="button" class="button small" data-op="test" data-tone="info">'+vt('Kiểm tra kết nối','Test connection')+'</button><button type="button" class="button small" data-op="edit" data-tone="configure">'+vt('Sửa','Edit')+'</button><button type="button" class="button small" data-op="delete" data-tone="remove">'+vt('Xóa','Delete')+'</button></div>').join('')+'</div>'
   +'<button type="button" class="button small" data-tone="create" id="oci-add">+ '+vt('Thêm tài khoản','Add account')+'</button>'
   +'<details><summary>'+vt('Hướng dẫn thiết lập IAM','IAM setup guide')+'</summary><ol class="oci-guide"><li>'+escapeHTML(vt('API Key: OCI Console → Profile → User settings → API keys → Add API key, tải private key và dán vào Manager.','API Key: OCI Console → Profile → User settings → API keys → Add API key, download the private key and paste it into Manager.'))+'</li><li>'+escapeHTML(vt('Instance Principal: chỉ dùng khi chính Manager chạy trên VM Oracle. Tạo Dynamic Group chứa VM đó.','Instance Principal: only when Manager itself runs on an Oracle VM. Create a Dynamic Group containing that VM.'))+'</li><li>'+escapeHTML(vt('Tạo policy trong compartment của VPS (thay <group> bằng group hoặc dynamic-group):','Create a policy in the VPS compartment (replace <group> with the group or dynamic-group):'))+'<pre>Allow group &lt;group&gt; to read instance-family in compartment &lt;compartment&gt;\nAllow group &lt;group&gt; to read virtual-network-family in compartment &lt;compartment&gt;\nAllow group &lt;group&gt; to manage security-lists in compartment &lt;compartment&gt;\nAllow group &lt;group&gt; to manage network-security-groups in compartment &lt;compartment&gt;</pre></li><li>'+escapeHTML(vt('Dùng “Kiểm tra kết nối”, rồi chọn tài khoản cho VPS và bấm Xác nhận.','Use “Test connection”, then choose the account for this server and press Confirm.'))+'</li></ol></details>',
   async form=>{
     const id=form.get('account');
     if(id)await api(path+'/oci-link',{account_id:id,region:form.get('region').trim()},'PUT');
     else await api(path+'/oci-link',undefined,'DELETE');
     fwCache.delete($('#hosts').value);setTimeout(render,0);
   });
  $('#oci-add').onclick=()=>ociAccountDialog(s,path);
  $('#popup').querySelector('.oci-accounts').onclick=async e=>{
    const btn=e.target.closest('[data-op]');if(!btn)return;
    const row=btn.closest('.oci-account'),account=s.accounts.find(a=>a.id===row.dataset.id),out=row.querySelector('.oci-result');
    if(btn.dataset.op==='edit'){ociAccountDialog(s,path,account);return;}
    if(btn.dataset.op==='delete'){modal(vt('Xóa tài khoản Oracle Cloud','Delete Oracle Cloud account'),'<p>'+escapeHTML(account.name)+'</p>',async()=>{await api('vps/oci/accounts/'+encodeURIComponent(account.id),undefined,'DELETE');setTimeout(()=>firewallRefreshDialog(path),0);});return;}
    btn.disabled=true;out.textContent=vt('Đang kiểm tra…','Testing…');
    try{const r=await api('vps/oci/accounts/'+encodeURIComponent(account.id)+'/test'+(($('#popup').elements.region.value.trim())?'?region='+encodeURIComponent($('#popup').elements.region.value.trim()):''),{});out.textContent='✓ '+r.regions.join(', ');}
    catch(err){out.textContent='✗ '+err.message;}finally{btn.disabled=false;}
  };
}
