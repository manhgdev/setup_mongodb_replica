window.zmWorkspaceHelper = {
  KEY: 'zm_workspace_user',
  getTarget() {
    return sessionStorage.getItem(this.KEY) || '';
  },
  setTarget(userId) {
    if (userId) sessionStorage.setItem(this.KEY, userId);
    else sessionStorage.removeItem(this.KEY);
    location.reload();
  },
  headers() {
    const t = this.getTarget();
    return t ? { 'X-Workspace-User': t } : {};
  },
  roleLabel(role, en = false) {
    if (role === 'admin') return 'Admin';
    if (role === 'manager') return en ? 'Manager' : 'Quản trị';
    return 'User';
  },
};

window.zmUsersPage = async function ({ container, csrfToken, auth, en = false }) {
  const t = (vi, e) => (en ? e : vi);
  const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const req = async (url, method = 'GET', body = undefined) => {
    const res = await fetch(url, {
      method,
      headers: { 'Content-Type': 'application/json', 'X-MongoDB-Manager': '1', 'X-CSRF-Token': csrfToken || '' },
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(typeof data.detail === 'string' ? data.detail : 'HTTP ' + res.status);
    return data;
  };

  container.innerHTML = `<div class="loading"><span class="spinner"></span>${t('Đang tải danh sách người dùng…', 'Loading users…')}</div>`;
  let state = await req('/api/users');
  let showCreate = false;
  const activeTarget = window.zmWorkspaceHelper.getTarget();
  const isAdmin = auth?.role === 'admin';

  const draw = (notice = '', error = '') => {
    const roleOpts = isAdmin
      ? `<option value="user">User</option><option value="manager">${t('Quản trị', 'Manager')}</option><option value="admin">Admin</option>`
      : `<option value="user">User</option>`;

    const rows = state.users.map((u, idx) => {
      const isSelf = u.id === auth.user_id;
      const canManage = isAdmin || u.role === 'user';
      const roleCell = isAdmin && !isSelf
        ? `<select class="zm-u-role" data-id="${esc(u.id)}" style="height:30px;padding:2px 8px;border:1px solid var(--line);border-radius:6px;background:#fff;font-size:12px">
            <option value="user"${u.role === 'user' ? ' selected' : ''}>User</option>
            <option value="manager"${u.role === 'manager' ? ' selected' : ''}>${t('Quản trị', 'Manager')}</option>
            <option value="admin"${u.role === 'admin' ? ' selected' : ''}>Admin</option>
          </select>`
        : `<span class="badge dark">${esc(window.zmWorkspaceHelper.roleLabel(u.role, en))}</span>`;

      const statusBadge = u.active
        ? `<span class="badge ok">${t('Hoạt động', 'Active')}</span>`
        : `<span class="badge remove">${t('Đã khóa', 'Locked')}</span>`;

      const isCurrentWs = (activeTarget && activeTarget === u.id) || (!activeTarget && isSelf);
      const wsBtn = isCurrentWs
        ? `<span class="badge">${t('Đang mở', 'Current')}</span>`
        : (canManage || isSelf ? `<button type="button" class="button small zm-u-ws" data-id="${esc(isSelf ? '' : u.id)}">${t('Mở Workspace', 'Open Workspace')}</button>` : '');

      const actions = canManage && !isSelf
        ? `<div class="actions">${wsBtn}
            <button type="button" class="button small zm-u-toggle" data-id="${esc(u.id)}" data-active="${u.active}">${u.active ? t('Khóa', 'Lock') : t('Mở khóa', 'Unlock')}</button>
            <button type="button" class="button small zm-u-reset" data-id="${esc(u.id)}" data-name="${esc(u.username)}">${t('Đặt lại MK', 'Reset PW')}</button>
            <button type="button" class="button small danger zm-u-del" data-tone="remove" data-id="${esc(u.id)}" data-name="${esc(u.username)}">${t('Xóa', 'Delete')}</button>
          </div>`
        : wsBtn;

      const meta = [u.created_by ? `${t('Tạo bởi', 'By')} ${u.created_by}` : '', u.created_at ? new Date(u.created_at).toLocaleDateString(en ? 'en-GB' : 'vi-VN') : ''].filter(Boolean).join(' · ');
      return `<tr><td class="row-number">${idx + 1}</td><td><strong>${esc(u.username)}</strong>${isSelf ? ` <small style="color:var(--muted)">(${t('Bạn', 'You')})</small>` : ''}${meta ? `<br><small style="color:var(--muted);font-size:11px">${esc(meta)}</small>` : ''}</td><td>${roleCell}</td><td>${statusBadge}</td><td>${actions}</td></tr>`;
    }).join('');

    container.innerHTML = `<section class="panel">
      <div class="panel-head">
        <div><h2>${t('Danh sách người dùng', 'Users')} (${state.users.length})</h2><p>${t('Mỗi tài khoản có workspace cụm MongoDB và VPS riêng.', 'Each account has its own MongoDB and VPS workspace.')}</p></div>
        <div class="actions" style="align-items:center">
          ${isAdmin ? `<label style="display:inline-flex;align-items:center;gap:6px;font-size:12px;color:var(--ink);cursor:pointer;padding:0 6px"><input type="checkbox" id="zm-allow-reg" ${state.allow_registration ? 'checked' : ''}><span>${t('Cho phép tự đăng ký', 'Self-registration')}</span></label>` : ''}
          <button type="button" class="button primary small" data-tone="create" id="zm-toggle-create">${showCreate ? t('Đóng', 'Close') : '+ ' + t('Tạo tài khoản', 'Create user')}</button>
        </div>
      </div>
      <div style="padding:8px 22px;background:#f8fbf9;border-bottom:1px solid var(--line);font-size:12px;color:var(--muted)">
        <strong>Admin</strong>: ${t('toàn quyền & bật tự đăng ký', 'full access & registration')} ·
        <strong>${t('Quản trị', 'Manager')}</strong>: ${t('quản lý & mở Workspace của User', 'manage & open User workspaces')} ·
        <strong>User</strong>: ${t('chỉ dùng Workspace riêng (không thấy tab này)', 'own workspace only (tab hidden)')}
      </div>
      ${showCreate ? `<div class="panel-body" style="border-bottom:1px solid var(--line);background:#f8fbf9">
        <form id="zm-create-user-form" style="display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px;align-items:end">
          <label class="field">Username<input id="zm-new-uname" required placeholder="username" autocomplete="off"></label>
          <label class="field">${t('Mật khẩu (≥6 ký tự)', 'Password (≥6 chars)')}<input id="zm-new-upass" type="password" required minlength="6" placeholder="••••••" autocomplete="new-password"></label>
          <label class="field">${t('Vai trò', 'Role')}<select id="zm-new-urole">${roleOpts}</select></label>
          <button type="submit" class="button primary" data-tone="create" style="height:39px">+ ${t('Tạo', 'Create')}</button>
        </form>
      </div>` : ''}
      ${notice ? `<div class="callout" style="margin:12px 16px 0">${notice}</div>` : ''}
      ${error ? `<div class="callout error" style="margin:12px 16px 0">${esc(error)}</div>` : ''}
      <div id="zm-user-subpanel"></div>
      <div class="table-wrap"><table>
        <thead><tr><th>#</th><th>USERNAME</th><th>${t('VAI TRÒ', 'ROLE')}</th><th>${t('TRẠNG THÁI', 'STATUS')}</th><th>${t('THAO TÁC', 'ACTIONS')}</th></tr></thead>
        <tbody>${rows}</tbody>
      </table></div>
    </section>`;

    const sub = container.querySelector('#zm-user-subpanel');
    container.querySelector('#zm-toggle-create').onclick = () => { showCreate = !showCreate; draw(); };

    const regEl = container.querySelector('#zm-allow-reg');
    if (regEl) {
      regEl.onchange = async () => {
        try {
          const r = await req('/api/auth/settings', 'POST', { allow_registration: regEl.checked });
          state.allow_registration = r.allow_registration;
          draw(t('Đã cập nhật cấu hình tự đăng ký.', 'Updated self-registration setting.'));
        } catch (e) { draw('', e.message); }
      };
    }

    const createForm = container.querySelector('#zm-create-user-form');
    if (createForm) {
      createForm.onsubmit = async e => {
        e.preventDefault();
        const username = container.querySelector('#zm-new-uname').value.trim();
        const password = container.querySelector('#zm-new-upass').value;
        const role = container.querySelector('#zm-new-urole').value;
        try {
          const res = await req('/api/users', 'POST', { username, password, role });
          state = await req('/api/users');
          showCreate = false;
          draw(t('Đã tạo tài khoản ', 'Created account ') + `<strong>${esc(res.user.username)}</strong> · ${t('Mã khôi phục: ', 'Recovery code: ')}<code>${esc(res.recovery_code)}</code>`);
        } catch (err) { draw('', err.message); }
      };
    }

    for (const sel of container.querySelectorAll('.zm-u-role')) {
      sel.onchange = async () => {
        try {
          await req('/api/users/' + encodeURIComponent(sel.dataset.id), 'PATCH', { role: sel.value });
          state = await req('/api/users');
          draw(t('Đã cập nhật vai trò.', 'Role updated.'));
        } catch (err) { state = await req('/api/users'); draw('', err.message); }
      };
    }

    for (const btn of container.querySelectorAll('.zm-u-toggle')) {
      btn.onclick = async () => {
        try {
          const next = btn.dataset.active !== 'true';
          await req('/api/users/' + encodeURIComponent(btn.dataset.id), 'PATCH', { active: next });
          state = await req('/api/users');
          draw(next ? t('Đã mở khóa tài khoản.', 'Account unlocked.') : t('Đã khóa tài khoản.', 'Account locked.'));
        } catch (err) { draw('', err.message); }
      };
    }

    for (const btn of container.querySelectorAll('.zm-u-ws')) {
      btn.onclick = () => window.zmWorkspaceHelper.setTarget(btn.dataset.id);
    }

    for (const btn of container.querySelectorAll('.zm-u-reset')) {
      btn.onclick = () => {
        sub.innerHTML = `<form id="zm-reset-form" class="callout" style="margin:12px 16px 0;display:flex;gap:10px;align-items:center;flex-wrap:wrap">
          <span>${t('Đặt mật khẩu mới cho', 'New password for')} <strong>${esc(btn.dataset.name)}</strong>:</span>
          <input id="zm-reset-pw" type="password" required minlength="6" placeholder="≥ 6 ${t('ký tự', 'chars')}" style="width:180px;padding:6px 10px;border:1px solid var(--line);border-radius:6px">
          <button type="submit" class="button small primary">${t('Xác nhận', 'Confirm')}</button>
          <button type="button" class="button small" id="zm-reset-cancel">${t('Hủy', 'Cancel')}</button>
        </form>`;
        sub.querySelector('#zm-reset-cancel').onclick = () => { sub.innerHTML = ''; };
        sub.querySelector('#zm-reset-form').onsubmit = async e => {
          e.preventDefault();
          try {
            const pw = sub.querySelector('#zm-reset-pw').value;
            const r = await req('/api/users/' + encodeURIComponent(btn.dataset.id), 'PATCH', { password: pw });
            draw(t('Đã đặt lại mật khẩu. Mã khôi phục mới: ', 'Password reset. New recovery code: ') + `<code>${esc(r.recovery_code)}</code>`);
          } catch (err) { draw('', err.message); }
        };
      };
    }

    for (const btn of container.querySelectorAll('.zm-u-del')) {
      btn.onclick = () => {
        sub.innerHTML = `<div class="callout error" style="margin:12px 16px 0;display:flex;gap:10px;align-items:center;flex-wrap:wrap">
          <span>${t('Xóa tài khoản', 'Delete account')} <strong>${esc(btn.dataset.name)}</strong>?</span>
          <label style="display:flex;align-items:center;gap:5px;font-size:12px"><input type="checkbox" id="zm-del-data"> ${t('Xóa luôn dữ liệu workspace', 'Also delete workspace data')}</label>
          <button type="button" class="button small danger" data-tone="remove" id="zm-del-ok">${t('Xóa vĩnh viễn', 'Delete')}</button>
          <button type="button" class="button small" id="zm-del-cancel">${t('Hủy', 'Cancel')}</button>
        </div>`;
        sub.querySelector('#zm-del-cancel').onclick = () => { sub.innerHTML = ''; };
        sub.querySelector('#zm-del-ok').onclick = async () => {
          try {
            const delData = sub.querySelector('#zm-del-data').checked ? 'true' : 'false';
            await req('/api/users/' + encodeURIComponent(btn.dataset.id) + '?delete_data=' + delData, 'DELETE');
            if (activeTarget === btn.dataset.id) sessionStorage.removeItem(window.zmWorkspaceHelper.KEY);
            state = await req('/api/users');
            draw(t('Đã xóa tài khoản.', 'Account deleted.'));
          } catch (err) { draw('', err.message); }
        };
      };
    }
  };

  draw();
};
