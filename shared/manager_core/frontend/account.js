const $ = selector => document.querySelector(selector);
const en = localStorage.getItem('mongo-manager-language') === 'en';
document.documentElement.lang = en ? 'en' : 'vi';
const dataLabel = (vi, english) => en ? english : vi;
const english = {'Đăng nhập':'Sign in','Mật khẩu':'Password','QUẢN TRỊ HỆ THỐNG':'SYSTEM ADMINISTRATION','Quản lý các cụm MongoDB và VPS của bạn.':'Manage your MongoDB clusters and servers.','Phiên tự hết hạn sau 30 phút không hoạt động.':'Your session expires after 30 minutes of inactivity.','Đóng':'Close','Hủy':'Cancel'};
const uiText = text => en ? english[text] || text : text;
const esc = value => String(value).replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
const params = new URLSearchParams(location.search);
let target;
try{target=new URL(params.get('next') || '/',location.origin);}catch{target=new URL('/',location.origin);}
function finish(){
  const allowed = target.origin === location.origin && ['/', '/vps/'].includes(target.pathname);
  location.replace(allowed ? target.href : '/');
}
let csrf = '';
async function api(path, data){
  const response = await fetch('/api'+path,{method:data?'POST':'GET',headers:{'Content-Type':'application/json','X-MongoDB-Manager':'1','X-CSRF-Token':csrf},body:data?JSON.stringify(data):undefined});
  const result = await response.json();
  if(!response.ok)throw new Error(typeof result.detail==='string'?result.detail:'HTTP '+response.status);
  return result;
}
function languagePicker(){
  return '<select class="language-picker" data-language aria-label="Language"><option value="vi" '+(!en?'selected':'')+'>Tiếng Việt</option><option value="en" '+(en?'selected':'')+'>English</option></select>';
}
function button(label, action, glyph='', tone=''){
  return '<button type="button" class="button '+tone+'" data-act="'+action+'">'+label+'</button>';
}
function passwordControl(input){
  return '<span class="password-control">'+input+'<button type="button" data-act="password-toggle" aria-pressed="false" aria-label="'+dataLabel('Hiện mật khẩu','Show password')+'"><svg aria-hidden="true" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor"><path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/></svg></button></span>';
}
function field(name,label,value='',type='text',help='',wide=false){
  const input='<input name="'+name+'" type="'+type+'" value="'+esc(value)+'" autocomplete="'+(type==='password'?(name==='current_password'?'current-password':'new-password'):'username')+'">';
  return '<label class="field '+(wide?'wide':'')+'"><span>'+label+'</span>'+(type==='password'?passwordControl(input):input)+(help?'<small>'+help+'</small>':'')+'</label>';
}
function modal(title,body,footer=''){
  $('#modal-content').innerHTML='<div class="modal-header"><h2>'+title+'</h2></div>'+body+(footer?'<div class="modal-footer">'+footer+'</div>':'');
  if(!$('#modal').open)$('#modal').showModal();
}
function recoveryCopy(value){
  return `<div class="recovery-copy"><code>${esc(value)}</code>${button(dataLabel('Sao chép','Copy'),'copy-recovery','','small')}</div>`;
}
function showRecoveryCode(code){
  const t=dataLabel;
  modal(t('Lưu mã khôi phục','Save your recovery code'),`<div class="modal-body"><p>${t('Lưu mã này để đặt lại mật khẩu quản trị. Mã chỉ hiển thị lần này.','Save this code to reset your administrator password. It is displayed only once.')}</p>${recoveryCopy(code)}</div>`,button(uiText('Đóng'),'modal-close'));
}
const recoveryViewKey='mongo-manager-recovery-view';
function showRecoveryHelp(savedMethod='Terminal'){
  const t=dataLabel;
  const methods={Terminal:'bash start-web.sh',PM2:'pm2 restart mongodb-manager',systemd:'sudo systemctl restart mongodb-manager'};
  modal(t('Hướng dẫn lấy lại mật khẩu','Password recovery guide'),`<div class="modal-body recovery-help">
    <div class="recovery-methods" role="group" aria-label="${t('Cách chạy Manager','Launch method')}">${Object.keys(methods).map(name=>`<button type="button" class="button small" data-method="${name}" aria-pressed="${name==='Terminal'}">${name}</button>`).join('')}</div>
    <div id="recovery-steps"></div></div>`,button(uiText('Đóng'),'modal-close'));
  function updateSteps(method){
    localStorage.setItem(recoveryViewKey,method);
    const systemd=method==='systemd';
    const command=systemd?'sudo -u mongodb-manager /opt/mongodb-manager/.venv/bin/python -m web.manage --data-dir /var/lib/mongodb-manager-web':'.venv/bin/python -m web.manage';
    const location=systemd?t('Trên VPS dùng service systemd đi kèm Manager.','On the VPS using the bundled systemd service.'):t('Mở terminal tại thư mục source của Manager.','Open a terminal in the Manager source directory.');
    $('#recovery-steps').innerHTML=`<section><h3>${t('1. Đặt mật khẩu mới','1. Set a new password')}</h3><p>${location} ${t('Thay USERNAME bằng tên đăng nhập, rồi nhập mật khẩu mới hai lần.','Replace USERNAME with your login and enter the new password twice.')}</p>
      ${recoveryCopy(command+' create-admin --username USERNAME --replace')}
      ${systemd?'':`<small>${t('Nếu dùng MONGO_MANAGER_DATA riêng, đặt biến này như khi chạy Manager.','If you use a custom MONGO_MANAGER_DATA, set it as you do when starting Manager.')}</small>`}
      </section><section><h3>${t('2. Khởi động lại Manager','2. Restart Manager')}</h3><p>${method==='Terminal'?t('Dừng Manager bằng Ctrl+C, chạy lệnh dưới đây rồi đăng nhập lại.','Stop Manager with Ctrl+C, run this command, then sign in again.'):t('Chạy lệnh sau rồi đăng nhập bằng mật khẩu mới.','Run this command, then sign in with the new password.')}</p>
      ${recoveryCopy(methods[method])}</section>`;
  }
  const buttons=document.querySelectorAll('.recovery-methods button');
  const selectMethod=method=>{
    for(const option of buttons)option.setAttribute('aria-pressed',String(option.dataset.method===method));
    updateSteps(method);
  };
  for(const item of buttons)item.onclick=()=>selectMethod(item.dataset.method);
  selectMethod(Object.hasOwn(methods,savedMethod)?savedMethod:'Terminal');
  $('#modal').addEventListener('close',()=>{
    if($('#recovery-form'))localStorage.setItem(recoveryViewKey,'form');
  },{once:true});
}
function showRecoveryForm(){
  localStorage.setItem(recoveryViewKey,'form');
  const t=dataLabel;
  $('#login-root').innerHTML=`<form id="recovery-form" class="login-card recovery-card">
    <div class="recovery-heading"><div class="brand"><span class="brandmark">m</span>MongoDB Manager</div>${languagePicker()}</div>
    <header><h1>${t('Đặt lại mật khẩu quản trị','Reset administrator password')}</h1>
    <p>${t('Dùng mã khôi phục đã lưu khi tạo hoặc sửa tài khoản. Manager không có mật khẩu mở khóa mặc định.','Use the recovery code saved when you created or edited your account. Manager has no default unlock password.')}</p></header>
    ${field('username',t('Tên đăng nhập quản trị','Administrator username'))}
    <div class="recovery-code-field">${field('recovery_code',t('Mã khôi phục','Recovery code'),'','password')}
    ${button(t('Không có mã khôi phục?','No recovery code?'),'recovery-help','','text-button')}</div>
    <div class="recovery-passwords">${field('password',t('Mật khẩu mới','New password'),'','password',t('Ít nhất 6 ký tự','At least 6 characters'))}${field('repeat',t('Nhập lại mật khẩu','Confirm password'),'','password')}</div>
    <div id="login-error" role="alert"></div><button type="submit" class="button primary">${t('Đặt lại mật khẩu','Reset password')}</button>${button(t('Quay lại đăng nhập','Back to sign in'),'back-login','','text-button')}</form>`;
  for(const input of $('#recovery-form').querySelectorAll('input'))input.required=true;
  $('#recovery-form').elements.password.minLength=6;
}
function showLogin(message='',setup=false){
  localStorage.removeItem(recoveryViewKey);
  if($('#modal').open)$('#modal').close();
  const root=$('#login-root');
  const title=setup?dataLabel('Tạo tài khoản quản trị đầu tiên','Create the first administrator account'):uiText("Đăng nhập");
  root.innerHTML=`<form id="login-form" data-setup="${setup}" class="login-card">${languagePicker()}<div class="brand"><span class="brandmark">m</span><span>MongoDB Manager</span></div><div class="eyebrow">${uiText("QUẢN TRỊ HỆ THỐNG")}</div><h1>${title}</h1><p>${uiText("Quản lý các cụm MongoDB và VPS của bạn.")}</p><label class="field"><span>Username</span><input name="username" autocomplete="username" required maxlength="80"></label><label class="field"><span>${uiText("Mật khẩu")}</span>${passwordControl('<input name="password" type="password" autocomplete="'+(setup?'new-password':'current-password')+'" required maxlength="1000" '+(setup?'minlength="6"':'')+'>')}</label>${setup?field('repeat',dataLabel('Nhập lại mật khẩu','Confirm password'),'','password'):''}<div id="login-error" role="alert">${message?esc(message):''}</div><button type="submit" class="button primary">${setup?dataLabel('Tạo tài khoản','Create account'):uiText("Đăng nhập")}</button><small>${setup?dataLabel('Mật khẩu từ 6 ký tự.','Use at least 6 characters.'):uiText("Phiên tự hết hạn sau 30 phút không hoạt động.")}</small>${setup?'':button(dataLabel('Quên mật khẩu?','Forgot password?'),'forgot-password')}</form>`;
}
function editAccount(auth){
  const t=dataLabel;
      const fields=field('username',t('Tên đăng nhập','Username'),auth.username||'','text','',true)
        +(auth.enabled?field('current_password',t('Mật khẩu hiện tại','Current password'),'','password','',true):'')
        +field('password',t('Mật khẩu mới','New password'),'','password',t('Để trống để giữ mật khẩu hiện tại.','Leave blank to keep the current password.'))
        +field('repeat',t('Nhập lại mật khẩu mới','Repeat new password'),'','password');
      modal(t('Sửa tài khoản quản trị','Edit administrator account'),`<form id="manager-admin-form">
        <div class="modal-body"><div class="form-grid">${fields}</div><p role="alert" class="form-error"></p></div>
        <div class="modal-footer">${button(uiText('Hủy'),'modal-close')}<button class="button primary" type="submit">${t('Lưu và đăng nhập lại','Save and sign in again')}</button></div>
      </form>`);
}
document.addEventListener('change',e=>{
  if(e.target.matches('[data-language]')){localStorage.setItem('mongo-manager-language',e.target.value);location.reload();}
});
document.addEventListener('click',async event=>{
  const target=event.target.closest('[data-act]');
  if(!target)return;
  const act=target.dataset.act;
  if(act==='modal-close'){$('#modal').close();return;}
  if(act==='password-toggle'){
    const input=target.previousElementSibling, reveal=input.type==='password';
    input.type=reveal?'text':'password';target.setAttribute('aria-pressed',String(reveal));
    target.setAttribute('aria-label',reveal?dataLabel('Ẩn mật khẩu','Hide password'):dataLabel('Hiện mật khẩu','Show password'));return;
  }
    if(act==='copy-recovery'){
      const code=target.closest('.recovery-copy').querySelector('code');
      try{
        await navigator.clipboard.writeText(code.textContent);
        target.textContent=dataLabel('Đã sao chép','Copied');
      }catch{
        const range=document.createRange();range.selectNodeContents(code);
        const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);
        target.textContent=dataLabel('Nhấn Ctrl+C hoặc ⌘C','Press Ctrl+C or ⌘C');
      }
      return;
    }
    if(act==='recovery-help'){showRecoveryHelp();return;}
    if(act==='forgot-password'){showRecoveryForm();return;}
    if(act==='back-login'){showLogin();return;}
});
document.addEventListener('submit',async event=>{
  if(event.target.id==='manager-admin-form'){
    event.preventDefault();
    const form=event.target, submit=form.querySelector('button[type=submit]');
    const {repeat,...body}=Object.fromEntries(new FormData(form));
    submit.disabled=true;
    try{
      if(repeat!==body.password)throw new Error(dataLabel('Hai mật khẩu chưa khớp.','Passwords do not match.'));
      body.password ||= body.current_password;
      const updated=await api('/auth/admin',body);
      $('#modal').close();showLogin(dataLabel('Đã lưu tài khoản. Vui lòng đăng nhập lại.','Login saved. Please sign in again.'));showRecoveryCode(updated.recovery_code);
    }catch(error){form.querySelector('[role=alert]').textContent=error.message;}
    finally{submit.disabled=false;}
    return;
  }
  if(!['login-form','recovery-form'].includes(event.target.id))return;event.preventDefault();
  const form=event.target,submit=form.querySelector('button[type="submit"]');submit.disabled=true;$('#login-error').replaceChildren();
  try{
    const {repeat,...credentials}=Object.fromEntries(new FormData(form));
    const setup=form.dataset.setup==='true';
    const recovering=form.id==='recovery-form';
    if((setup||recovering)&&credentials.password!==repeat)throw new Error(dataLabel('Hai mật khẩu chưa khớp.','Passwords do not match.'));
    if(recovering){
      const result=await api('/auth/recover',credentials);
      showLogin(dataLabel('Đã đặt lại mật khẩu. Hãy đăng nhập.','Password reset. Please sign in.'));
      showRecoveryCode(result.recovery_code);return;
    }
    const result=await api(setup?'/auth/setup':'/auth/login', credentials);
    form.elements.password.value='';if(result.recovery_code){showRecoveryCode(result.recovery_code);$('#modal').addEventListener('close',finish,{once:true});}else finish();}
  catch(error){const output=$('#login-error');if(output)output.textContent=error.message;}
  finally{submit.disabled=false;}
});
async function boot(){
  const auth=await api('/auth/status');
  csrf=auth.csrf;
  if(auth.authenticated){
    if(params.get('account')==='1'){
      $('#login-root').replaceChildren();editAccount(auth);
      $('#modal').addEventListener('close',()=>{if(!$('#login-form'))finish();},{once:true});
    }else finish();
    return;
  }
  const saved=localStorage.getItem(recoveryViewKey);
  showLogin('',!auth.enabled);
  if(saved&&auth.enabled){showRecoveryForm();if(saved!=='form')showRecoveryHelp(saved);}
}
boot().catch(err=>showLogin(err.message));
