'use strict';

async function openBackupPreview(machineId, backupId) {
  const text = dataLabel;
  const archive = backupItems.find(item => item.id === backupId) || {id:backupId};
  const base = '/profiles/'+profile().id+'/machines/'+machineId+'/backups/';
  const endpoint = id => base+encodeURIComponent(id)+'/preview';
  const subtitle = item => [item?.source, item?.time && formatDate(item.time),
    text('Chỉ đọc','Read only'),
    item?.oplog && text('Dữ liệu trước khi áp dụng oplog','Data before oplog replay')
  ].filter(Boolean).join(' · ');
  const demoCollections = {users:[{_id:1,username:'demo'}],orders:[{_id:1,total:120}],products:[{_id:1,name:'Demo'}]};
  const loading = uiText('Đang tải…');
  modal(text('Dữ liệu bản backup','Backup data'), `
    <div class="archive-view" data-archive-view>
      <aside class="archive-sidebar">
        <h3>Collections <small data-count></small></h3>
        <label class="field"><input type="search" data-search disabled
          aria-label="${text('Tìm database hoặc collection','Find a database or collection')}"
          placeholder="${text('Tìm database hoặc collection','Find a database or collection')}"></label>
        <div data-names></div>
        <small data-catalog-status role="status"></small>
      </aside>
      <section class="archive-main">
        <header><h3 data-location>Documents</h3><div data-tools></div></header>
        <div class="archive-scroll" data-records></div>
        <div class="archive-pager" data-pager></div>
      </section>
    </div>`, button(uiText('Đóng'),'modal-close'), esc(subtitle(archive)));
  const root = $('[data-archive-view]');
  const get = selector => root.querySelector(selector);
  const search = get('[data-search]'), list = get('[data-names]'), records = get('[data-records]');
  const location = get('[data-location]'), pager = get('[data-pager]'), tools = get('[data-tools]');
  let names = [], selected = 0, offsets = [0], page = 0, request = 0;
  const known = new Set();
  function addNames(pairs, source) {
    for (const [db, coll] of pairs) {
      const key = JSON.stringify([db,coll]);
      if (known.has(key)) continue;
      known.add(key);
      names.push([db,coll,source]);
    }
  }
  const active = () => root.isConnected && $('#modal').open;

  function control(label, handler) {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'button small';
    btn.textContent = label;
    btn.onclick = handler;
    return btn;
  }

  function notice(message, retry) {
    const box = document.createElement('div');
    box.className = 'archive-notice';
    box.setAttribute('role','status');
    box.textContent = message;
    if (retry) box.append(control(text('Thử lại','Retry'), retry));
    records.replaceChildren(box);
  }

  function showNames() {
    const term = search.value.trim().toLowerCase();
    list.replaceChildren();
    let group, inOther = false;
    names.forEach(([db, coll, source], i) => {
      if (!(db+'/'+coll).toLowerCase().includes(term)) return;
      if (source !== archive && !inOther) {
        const label = document.createElement('div');
        label.className = 'archive-group-label';
        label.textContent = text('Từ bản backup khác','From other backups');
        list.append(label);
        group = undefined;
        inOther = true;
      }
      if (group !== db) {
        const heading = document.createElement('h4');
        heading.textContent = db;
        list.append(heading);
        group = db;
      }
      const item = control(coll, () => {
        selected = i;
        offsets = [0];
        page = 0;
        search.value = '';
        showNames();
        list.querySelector('[aria-pressed=true]')?.focus({preventScroll:true});
        loadPage();
      });
      item.className = 'collection-item';
      item.title = db+' / '+coll+' · '+subtitle(source);
      item.setAttribute('aria-pressed',String(i === selected));
      list.append(item);
    });
    if (!list.childElementCount) list.textContent = text('Không tìm thấy collection.','No matching collections.');
    get('[data-count]').textContent = names.length;
  }

  function showPage(rows, more) {
    const offset = offsets[page];
    tools.replaceChildren();
    pager.replaceChildren();
    records.replaceChildren();
    const [db, coll] = names[selected];
    location.textContent = db+' / '+coll;
    if (!rows.length) {
      notice(text('Collection này chưa có document.','This collection has no documents.'));
      return;
    }
    const columns = [...new Set(rows.flatMap(Object.keys))].slice(0,12);
    const grid = document.createElement('div');
    grid.className = 'doc-compact';
    grid.innerHTML = table([uiText('STT'), ...columns.map(esc)], rows.map((doc, i) => {
      const cells = columns.map(key => {
        if (!Object.hasOwn(doc,key)) return '<td>—</td>';
        const value = doc[key];
        const summary = bsonValue(value) ?? ((Array.isArray(value)?'Array':'Object')+' · '+Object.keys(value).length);
        return '<td><code>'+esc(summary.slice(0,160))+'</code></td>';
      });
      return '<tr tabindex="0"><td class="row-number">'+(offset+i+1)+'</td>'+cells.join('')+'</tr>';
    }));
    records.append(grid);
    const prev = control(text('Trước','Previous'), () => { page--; loadPage(); });
    const next = control(text('Sau','Next'), () => { page++; loadPage(); });
    prev.disabled = page === 0;
    next.disabled = !more;
    const range = document.createElement('span');
    range.textContent = 'Documents '+(offset+1)+'–'+(offset+rows.length);
    pager.append(range,prev,next);
    const inspect = (doc,i,row) => {
      const top = records.scrollTop, left = records.scrollLeft;
      const fields = document.createElement('div');
      for (const [key,val] of Object.entries(doc)) fields.append(documentTree(val,key));
      records.replaceChildren(fields);
      records.scrollTo(0,0);
      pager.hidden = true;
      location.textContent = coll+' / Document #'+(offset+i+1);
      const back = control(text('← Danh sách','← Documents'), () => {
        tools.replaceChildren();
        records.replaceChildren(grid);
        location.textContent = db+' / '+coll;
        pager.hidden = false;
        row.focus({preventScroll:true});
        records.scrollTo(left,top);
      });
      const json = control('Extended JSON', () => {
        if (records.firstChild === fields) {
          const pre = document.createElement('pre');
          pre.textContent = JSON.stringify(doc,null,2);
          records.replaceChildren(pre);
          json.textContent = text('Xem trường','View fields');
        } else {
          records.replaceChildren(fields);
          json.textContent = 'Extended JSON';
        }
        records.scrollTo(0,0);
      });
      tools.replaceChildren(back,json);
      back.focus({preventScroll:true});
    };
    Array.from(grid.querySelectorAll('tbody tr')).forEach((row,i) => {
      row.onclick = () => inspect(rows[i],i,row);
      row.onkeydown = e => {
        if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); row.click(); }
      };
    });
  }

  async function loadPage() {
    const token = ++request;
    const [database,collection,source] = names[selected], offset = offsets[page];
    $('#modal .modal-header p').textContent = (source === archive ? '' : text('Bản backup khác','Other backup')+' · ')+subtitle(source);
    location.textContent = database+' / '+collection;
    tools.replaceChildren();
    pager.replaceChildren();
    pager.hidden = false;
    notice(loading);
    try {
      const result = demo ? {records:demoCollections[collection],more:false}
        : await api(endpoint(source.id)+'?'+new URLSearchParams({database,collection,offset}));
      if (!active() || token !== request) return;
      if (result.more) offsets[page+1] = offset+result.records.length;
      showPage(result.records,result.more);
      records.scrollTo(0,0);
    } catch (err) {
      if (active() && token === request) notice(err.message,loadPage);
    }
  }

  // A scoped archive can be browsed alongside snapshots from the same source and storage host.
  async function loadRelated(items) {
    const status = get('[data-catalog-status]');
    const failed = [];
    for (const other of items) {
      if (!active()) return;
      if (other.archives?.length && other.archives.every(part => known.has(JSON.stringify([part.database,part.collection])))) continue;
      status.textContent = text('Đang tìm thêm collection…','Finding more collections…');
      try {
        const {namespaces} = await api(endpoint(other.id));
        if (!active()) return;
        const count = names.length;
        addNames(namespaces,other);
        if (names.length !== count) showNames();
      } catch {
        failed.push(other);
      }
    }
    if (!active()) return;
    status.replaceChildren();
    if (failed.length) {
      status.textContent = text('Chưa đọc được một số bản backup. ','Some backups could not be read. ');
      status.append(control(text('Thử lại','Retry'), () => loadRelated(failed)));
    }
  }

  async function loadCatalog() {
    notice(loading);
    try {
      const pairs = demo ? Object.keys(demoCollections).map(coll => ['application',coll]) : (await api(endpoint(backupId))).namespaces;
      if (!active()) return;
      addNames(pairs,archive);
      search.disabled = false;
      search.oninput = showNames;
      showNames();
      if (archive?.source_id && (archive.databases?.length || archive.collection || archive.application_only || archive.collections?.length || archive.archives?.some(part => part.database))) {
        const related = backupItems.filter(item => item.id !== backupId && item.source_id === archive.source_id && (item.machine_id || machineId) === machineId)
          .sort((a,b) => b.time.localeCompare(a.time));
        void loadRelated(related);
      }
      if (!names.length) {
        notice(text('Bản backup này không có collection dữ liệu để xem.','No data collections in this backup.'));
        return;
      }
      await loadPage();
    } catch (err) {
      if (active()) notice(err.message,loadCatalog);
    }
  }
  await loadCatalog();
}
