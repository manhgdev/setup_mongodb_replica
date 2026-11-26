// "User & Ổ đĩa": manage Linux users, sudo/groups/SSH keys, disk partitions, mounts, and folder permissions.
async function sysadminPage(view,path,rev){
  const fmtBytes=b=>{
    if(!b)return '0 B';
    const u=['B','KB','MB','GB','TB'];let i=0,v=Number(b);
    while(v>=1024&&i<u.length-1){v/=1024;i++;}
    return v.toFixed(v>=10||i===0?0:1)+' '+u[i];
  };
  view.innerHTML='<div class="loading"><span class="spinner"></span> '+vt('Đang đọc User & Ổ đĩa từ VPS…','Loading users & storage…')+'</div>';
  let data;
  try{data=await api(path+'/sysadmin');}
  catch(err){if(rev===revision)view.innerHTML='<div class="callout error">'+escapeHTML(err.message)+'</div>';return;}
  if(rev!==revision)return;

  const refreshBtn=document.createElement('button');refreshBtn.type='button';refreshBtn.className='button';refreshBtn.dataset.tone='info';refreshBtn.textContent=vt('Làm mới','Refresh');
  refreshBtn.onclick=()=>render();
  const addUserBtn=document.createElement('button');addUserBtn.type='button';addUserBtn.className='button';addUserBtn.dataset.tone='create';addUserBtn.textContent='+ '+vt('Tạo User','Add User');
  addUserBtn.onclick=()=>openUserModal(null);
  const permBtn=document.createElement('button');permBtn.type='button';permBtn.className='button';permBtn.dataset.tone='configure';permBtn.textContent=vt('Phân quyền thư mục','Folder Permissions');
  permBtn.onclick=()=>openPermModal('/data/app');
  $('#heading-actions').append(refreshBtn,permBtn,addUserBtn);

  const userRows=(data.users||[]).map(u=>{
    const badges=[];
    if(u.uid===0)badges.push('<span class="badge dark">ROOT</span>');
    if(u.sudo)badges.push('<span class="badge success">SUDO</span>');
    if(u.nopasswd&&u.uid!==0)badges.push('<span class="badge info">NOPASSWD</span>');
    if(u.locked)badges.push('<span class="badge error">LOCKED</span>');
    if(u.is_current)badges.push('<span class="badge warning">'+vt('Đang SSH','Active SSH')+'</span>');
    const delBtn=u.uid===0||u.is_current?'':'<button type="button" class="button small sys-user-del" data-tone="remove" data-user="'+escapeHTML(u.username)+'">'+vt('Xoá','Delete')+'</button>';
    return '<tr>'
      +'<td><strong>'+escapeHTML(u.username)+'</strong><div class="sys-badges">'+badges.join('')+'</div></td>'
      +'<td class="mono">'+(u.groups||[]).map(g=>'<span class="badge">'+escapeHTML(g)+'</span>').join(' ')+'</td>'
      +'<td><span class="mono">'+escapeHTML(u.home)+'</span><small>'+escapeHTML(u.shell)+'</small></td>'
      +'<td><span class="badge">'+(u.ssh_key_count||0)+' key</span></td>'
      +'<td><div class="actions"><button type="button" class="button small sys-user-edit" data-tone="configure" data-user="'+escapeHTML(u.username)+'">'+vt('Phân quyền / Sửa','Permissions / Edit')+'</button>'+delBtn+'</div></td>'
      +'</tr>';
  }).join('');

  const diskRows=[];
  for(const d of (data.disks||[])){
    const isEmptyDisk=!d.children?.length&&!d.fstype&&!d.protected;
    const diskAct=isEmptyDisk?'<button type="button" class="button small sys-disk-part" data-tone="create" data-dev="'+escapeHTML(d.path)+'">'+vt('Chia phân vùng (GPT)','Create partition')+'</button>':'';
    diskRows.push('<tr class="sys-disk-row">'
      +'<td><strong class="mono">'+escapeHTML(d.path)+'</strong>'+(d.model?'<small>'+escapeHTML(d.model)+'</small>':'')+'</td>'
      +'<td class="mono">'+fmtBytes(d.size)+'</td>'
      +'<td><span class="badge dark">DISK</span> '+(d.fstype?escapeHTML(d.fstype):'—')+'</td>'
      +'<td class="mono">'+(d.mountpoint?escapeHTML(d.mountpoint):'—')+'</td>'
      +'<td><div class="actions">'+diskAct+'</div></td>'
      +'</tr>');
    for(const p of (d.children||[])){
      const acts=[];
      if(p.protected){
        acts.push('<span class="badge dark">'+vt('Hệ thống','System')+'</span>');
      }else if(p.mountpoint){
        acts.push('<button type="button" class="button small sys-perm-path" data-tone="configure" data-path="'+escapeHTML(p.mountpoint)+'">'+vt('Phân quyền','Permissions')+'</button>');
        acts.push('<button type="button" class="button small sys-part-unmount" data-tone="warning" data-dev="'+escapeHTML(p.path)+'" data-mnt="'+escapeHTML(p.mountpoint)+'">Unmount</button>');
      }else{
        if(p.fstype)acts.push('<button type="button" class="button small sys-part-mount" data-tone="create" data-dev="'+escapeHTML(p.path)+'" data-fs="'+escapeHTML(p.fstype)+'">Mount</button>');
        acts.push('<button type="button" class="button small sys-part-format" data-tone="remove" data-dev="'+escapeHTML(p.path)+'">Format</button>');
      }
      diskRows.push('<tr>'
        +'<td style="padding-left:26px"><span class="mono">└ '+escapeHTML(p.path)+'</span>'+(p.uuid?'<small class="mono">UUID: '+escapeHTML(p.uuid)+'</small>':'')+'</td>'
        +'<td class="mono">'+fmtBytes(p.size)+'</td>'
        +'<td>'+(p.fstype?'<span class="badge">'+escapeHTML(p.fstype)+'</span>':'<span class="badge warning">Unformatted</span>')+'</td>'
        +'<td class="mono">'+(p.mountpoint?escapeHTML(p.mountpoint):'—')+'</td>'
        +'<td><div class="actions">'+acts.join('')+'</div></td>'
        +'</tr>');
    }
  }

  const mountRows=(data.mounts||[]).map(m=>'<tr>'
    +'<td class="mono">'+escapeHTML(m.device)+'</td>'
    +'<td class="mono">'+escapeHTML(m.mountpoint)+'</td>'
    +'<td><span class="badge">'+escapeHTML(m.fstype)+'</span></td>'
    +'<td class="mono">'+fmtBytes(m.used)+' / '+fmtBytes(m.size)+' ('+escapeHTML(m.percent)+')</td>'
    +'<td><div class="actions">'+(m.protected?'<span class="badge dark">'+vt('Hệ thống','System')+'</span>':'<button type="button" class="button small sys-perm-path" data-tone="configure" data-path="'+escapeHTML(m.mountpoint)+'">'+vt('Phân quyền','Permissions')+'</button>')+'</div></td>'
    +'</tr>').join('');

  view.innerHTML=''
    +'<section class="panel"><div class="panel-head"><div><h2>'+vt('User Linux & Phân quyền','Linux Users & Permissions')+'</h2><p>'+vt('Quản lý tài khoản hệ điều hành, nhóm quyền (sudo, docker, www-data) và SSH public keys.','Manage OS accounts, groups (sudo, docker, www-data) and SSH public keys.')+'</p></div></div>'
    +'<div class="table-wrap"><table><thead><tr><th>USER</th><th>'+vt('NHÓM','GROUPS')+'</th><th>HOME &amp; SHELL</th><th>SSH KEYS</th><th></th></tr></thead><tbody>'+userRows+'</tbody></table></div></section>'
    +'<section class="panel"><div class="panel-head"><div><h2>'+vt('Ổ đĩa, Phân vùng & Vùng lưu trữ','Disks, Partitions & Mounts')+'</h2><p>'+vt('Chia phân vùng ổ trống, format, mount vào thư mục (tùy chọn lưu /etc/fstab) và phân quyền vùng chia.','Partition free disks, format, mount directories (with optional /etc/fstab persistence) and set permissions.')+'</p></div></div>'
    +'<div class="table-wrap"><table><thead><tr><th>DEVICE</th><th>'+vt('DUNG LƯỢNG','SIZE')+'</th><th>FILESYSTEM</th><th>MOUNT POINT</th><th></th></tr></thead><tbody>'+(diskRows.join('')||'<tr><td colspan="5">—</td></tr>')+'</tbody></table></div></section>'
    +'<section class="panel"><div class="panel-head"><div><h2>'+vt('Dung lượng các vùng đang Mount','Mounted Filesystems')+'</h2></div></div>'
    +'<div class="table-wrap"><table><thead><tr><th>DEVICE</th><th>MOUNT POINT</th><th>TYPE</th><th>'+vt('ĐÃ DÙNG','USED')+'</th><th></th></tr></thead><tbody>'+(mountRows||'<tr><td colspan="5">—</td></tr>')+'</tbody></table></div></section>';

  view.querySelectorAll('.sys-user-edit').forEach(b=>b.onclick=()=>{
    const u=(data.users||[]).find(x=>x.username===b.dataset.user);
    if(u)openUserModal(u);
  });
  view.querySelectorAll('.sys-user-del').forEach(b=>b.onclick=()=>{
    const name=b.dataset.user;
    modal(vt('Xoá User Linux','Delete Linux User'),
      '<p>'+vt('Xoá tài khoản ','Delete account ')+'<strong>'+escapeHTML(name)+'</strong>?</p><label><input type="checkbox" name="remove_home"> '+vt('Xoá luôn thư mục /home/'+escapeHTML(name),'Also remove /home/'+escapeHTML(name))+'</label>',
      async form=>{
        await api(path+'/users',{op:'delete',username:name,remove_home:form.has('remove_home')});
        toast(vt('Đã xoá user ','Deleted user ')+name);render();
      });
  });
  view.querySelectorAll('.sys-perm-path').forEach(b=>b.onclick=()=>openPermModal(b.dataset.path));
  view.querySelectorAll('.sys-disk-part').forEach(b=>b.onclick=()=>openPartitionModal(b.dataset.dev));
  view.querySelectorAll('.sys-part-format').forEach(b=>b.onclick=()=>openFormatModal(b.dataset.dev));
  view.querySelectorAll('.sys-part-mount').forEach(b=>b.onclick=()=>openMountModal(b.dataset.dev,b.dataset.fs));
  view.querySelectorAll('.sys-part-unmount').forEach(b=>b.onclick=()=>{
    const dev=b.dataset.dev,mnt=b.dataset.mnt;
    modal('Unmount '+escapeHTML(dev),
      '<p>Unmount <strong class="mono">'+escapeHTML(mnt)+'</strong>?</p><label><input type="checkbox" name="remove_fstab" checked> '+vt('Gỡ dòng tương ứng khỏi /etc/fstab','Remove entry from /etc/fstab')+'</label>',
      async form=>{
        await api(path+'/storage/mount',{op:'unmount',device:dev,remove_fstab:form.has('remove_fstab')});
        toast('Đã unmount '+mnt);render();
      });
  });

  function openUserModal(u){
    const isEdit=!!u,isRoot=u?.uid===0;
    const presetGroups=['sudo','docker','www-data','adm'];
    const curGroups=new Set(u?.groups||[]);
    const customGroups=(u?.groups||[]).filter(g=>!presetGroups.includes(g)&&g!==u?.username).join(', ');
    modal(isEdit?vt('Phân quyền & Sửa User: ','Edit User: ')+u.username:vt('Tạo User Linux mới','Create Linux User'),
      '<div class="form-grid">'
      +'<label class="field">Username<input name="username" value="'+escapeHTML(u?.username||'')+'" '+(isEdit?'readonly':'required pattern="[a-z_][a-z0-9_-]{0,31}" placeholder="deploy"')+'></label>'
      +'<label class="field">'+(isEdit?vt('Đổi mật khẩu (để trống nếu giữ)','New password (optional)'):vt('Mật khẩu (tùy chọn)','Password (optional)'))+'<input name="password" type="password" autocomplete="new-password"></label>'
      +(isRoot?'':'<label class="field">Shell<select name="shell">'+['/bin/bash','/bin/zsh','/bin/sh','/usr/sbin/nologin'].map(s=>'<option value="'+s+'"'+(u?.shell===s?' selected':'')+'>'+s+'</option>').join('')+'</select></label>')
      +(isEdit?'':'<label class="field">Home directory<input name="home" placeholder="/home/deploy"></label>')
      +(isRoot?'':'<label class="field wide">'+vt('Nhóm tùy chọn thêm (cách nhau dấu phẩy)','Extra groups (comma-separated)')+'<input name="extra_groups" value="'+escapeHTML(customGroups)+'" placeholder="developers, nginx"></label>')
      +'</div>'
      +(isRoot?'':'<fieldset><legend>'+vt('Phân quyền nhanh','Quick Permissions')+'</legend>'
        +presetGroups.map(g=>'<label><input type="checkbox" name="grp" value="'+g+'"'+(curGroups.has(g)?' checked':'')+'> '+g+'</label>').join('')
        +'<label><input type="checkbox" name="nopasswd"'+(u?.nopasswd?' checked':'')+'> sudo -n (NOPASSWD)</label>'
        +(isEdit&&!u.is_current?'<label><input type="checkbox" name="locked"'+(u?.locked?' checked':'')+'> '+vt('Khóa tài khoản (LOCK)','Lock account')+'</label>':'')
        +'</fieldset>')
      +'<label class="field wide" style="margin-top:8px">SSH authorized_keys ('+vt('mỗi dòng 1 public key .pub','one .pub key per line')+')<textarea name="ssh_keys" rows="4" placeholder="ssh-ed25519 AAAA... user@host">'+escapeHTML((u?.ssh_keys||[]).join('\n'))+'</textarea></label>',
      async form=>{
        const extra=(form.get('extra_groups')||'').split(',').map(s=>s.trim()).filter(Boolean);
        const picked=form.getAll('grp');
        const groups=[...new Set([...picked,...extra])];
        const ssh_keys=(form.get('ssh_keys')||'').split('\n').map(s=>s.trim()).filter(Boolean);
        const payload={
          op:isEdit?'update':'create',
          username:(form.get('username')||'').trim(),
          password:form.get('password')||'',
          shell:form.get('shell')||'',
          home:form.get('home')||'',
          groups:isRoot?null:groups,
          sudo:isRoot?true:groups.includes('sudo'),
          nopasswd:isRoot?true:form.has('nopasswd'),
          locked:isEdit&&!isRoot&&!u.is_current?form.has('locked'):null,
          ssh_keys
        };
        await api(path+'/users',payload);
        toast(isEdit?vt('Đã cập nhật user ','Updated user ')+payload.username:vt('Đã tạo user ','Created user ')+payload.username);
        render();
      });
  }

  function openPermModal(defaultPath){
    const userOpts=(data.users||[]).map(u=>'<option value="'+escapeHTML(u.username)+'">'+escapeHTML(u.username)+'</option>').join('');
    const groupOpts=[...new Set([...(data.groups||[]),...(data.users||[]).map(u=>u.username)])].map(g=>'<option value="'+escapeHTML(g)+'">'+escapeHTML(g)+'</option>').join('');
    modal(vt('Phân quyền thư mục / Vùng lưu trữ','Folder & Storage Permissions'),
      '<div class="form-grid">'
      +'<label class="field wide">'+vt('Đường dẫn thư mục','Directory path')+'<input name="path" required value="'+escapeHTML(defaultPath||'/data/app')+'" placeholder="/data/app"></label>'
      +'<label class="field">Owner (User)<select name="owner">'+userOpts+'</select></label>'
      +'<label class="field">Group<select name="group">'+groupOpts+'</select></label>'
      +'<label class="field">Mode (Octal)<input name="mode" id="perm-octal" value="755" pattern="[0-7]{3,4}" required></label>'
      +'<label class="field">Preset<select id="perm-preset"><option value="755">755 (rwxr-xr-x · Web/App)</option><option value="750">750 (rwxr-x--- · Private Group)</option><option value="700">700 (rwx------ · Owner Only)</option><option value="775">775 (rwxrwxr-x · Shared Team)</option><option value="644">644 (rw-r--r-- · File)</option></select></label>'
      +'</div>'
      +'<div class="perm-matrix" id="perm-matrix">'
        +['Owner','Group','Other'].map((role,idx)=>'<div class="perm-col"><strong>'+role+'</strong>'
          +'<label><input type="checkbox" data-role="'+idx+'" data-bit="4"> Read (4)</label>'
          +'<label><input type="checkbox" data-role="'+idx+'" data-bit="2"> Write (2)</label>'
          +'<label><input type="checkbox" data-role="'+idx+'" data-bit="1"> Exec (1)</label></div>').join('')
      +'</div>'
      +'<p><label><input type="checkbox" name="create" checked> '+vt('Tạo thư mục nếu chưa tồn tại (mkdir -p)','Create directory if missing')+'</label></p>'
      +'<p><label><input type="checkbox" name="recursive"> '+vt('Áp dụng đệ quy cho toàn bộ file/thư mục con (-R)','Apply recursively (-R)')+'</label></p>',
      async form=>{
        const res=await api(path+'/storage/permissions',{
          path:form.get('path'),
          owner:form.get('owner'),
          group:form.get('group'),
          mode:form.get('mode'),
          create:form.has('create'),
          recursive:form.has('recursive')
        });
        toast(vt('Đã phân quyền ','Updated permissions ')+res.path+' ('+res.owner+':'+res.group+' '+res.mode+')');
        render();
      });
    const octInput=$('#perm-octal'),preset=$('#perm-preset'),boxes=[...$('#perm-matrix').querySelectorAll('input[type=checkbox]')];
    const syncToBoxes=()=>{
      const val=(octInput.value||'755').slice(-3).padStart(3,'0');
      boxes.forEach(b=>{const d=Number(val[Number(b.dataset.role)]||0);b.checked=Boolean(d&Number(b.dataset.bit));});
    };
    const syncToOctal=()=>{
      const digits=[0,0,0];
      boxes.forEach(b=>{if(b.checked)digits[Number(b.dataset.role)]+=Number(b.dataset.bit);});
      octInput.value=digits.join('');
    };
    preset.onchange=()=>{octInput.value=preset.value;syncToBoxes();};
    octInput.oninput=syncToBoxes;
    boxes.forEach(b=>{b.onchange=syncToOctal;});
    syncToBoxes();
  }

  function openPartitionModal(dev){
    modal(vt('Chia phân vùng mới (GPT): ','Create GPT Partition: ')+escapeHTML(dev),
      '<p>'+vt('Tạo 1 phân vùng chính chiếm 100% dung lượng ổ trống và format sẵn để mount.','Create a single primary partition using 100% of this free disk and format it.')+'</p>'
      +'<label class="field">Filesystem<select name="fstype"><option value="ext4">ext4 (Khuyên dùng cho Linux)</option><option value="xfs">xfs</option></select></label>',
      async form=>{
        const res=await api(path+'/storage/mount',{op:'partition',device:dev,fstype:form.get('fstype')});
        toast(vt('Đã tạo phân vùng ','Created partition ')+res.device);render();
      });
  }

  function openFormatModal(dev){
    modal(vt('Format phân vùng: ','Format Partition: ')+escapeHTML(dev),
      '<div class="callout error">'+vt('Cảnh báo: Mọi dữ liệu trên phân vùng này sẽ bị xoá sạch!','Warning: All data on this partition will be erased!')+'</div>'
      +'<div class="form-grid"><label class="field">Filesystem<select name="fstype"><option value="ext4">ext4</option><option value="xfs">xfs</option></select></label>'
      +'<label class="field">'+vt('Nhập lại tên thiết bị để xác nhận','Type device path to confirm')+'<input name="confirm_device" required placeholder="'+escapeHTML(dev)+'"></label></div>',
      async form=>{
        await api(path+'/storage/mount',{op:'format',device:dev,fstype:form.get('fstype'),confirm_device:form.get('confirm_device')});
        toast(vt('Đã format ','Formatted ')+dev);render();
      });
  }

  function openMountModal(dev,fs){
    const userOpts='<option value="">— '+vt('Giữ mặc định (root)','Keep default (root)')+' —</option>'+(data.users||[]).map(u=>'<option value="'+escapeHTML(u.username)+'">'+escapeHTML(u.username)+'</option>').join('');
    modal('Mount '+escapeHTML(dev)+' ('+escapeHTML(fs)+')',
      '<div class="form-grid">'
      +'<label class="field wide">'+vt('Thư mục Mount Point','Mount Point directory')+'<input name="mountpoint" required placeholder="/mnt/data" value="/mnt/data"></label>'
      +'<label class="field">'+vt('Gán quyền sở hữu sau khi mount','Owner after mount')+'<select name="owner">'+userOpts+'</select></label>'
      +'<label class="field">Mode<input name="mode" value="755"></label>'
      +'</div>'
      +'<p><label><input type="checkbox" name="persist_fstab" checked> '+vt('Tự động mount khi khởi động lại (/etc/fstab với UUID + nofail)','Persist across reboots (/etc/fstab with UUID + nofail)')+'</label></p>',
      async form=>{
        const res=await api(path+'/storage/mount',{
          op:'mount',device:dev,mountpoint:form.get('mountpoint'),
          persist_fstab:form.has('persist_fstab'),owner:form.get('owner'),mode:form.get('mode')
        });
        toast('Đã mount '+dev+' -> '+res.mountpoint);render();
      });
  }
}
