'use strict';

let documentTailObserver;
const demoDocumentCollections=new Map();

function dataLabel(vi,en){ return uiLanguage==='en'?en:vi; }

function bsonValue(value){
  if(value===null || typeof value!=='object')return value===null?'null':String(value);
  const keys=Object.keys(value);
  if(keys.length===1 && keys[0].startsWith('$')){
    const raw=value[keys[0]];
    if(keys[0]==='$date' && raw?.$numberLong){
      const date=new Date(Number(raw.$numberLong));
      if(Number.isFinite(date.getTime()))return date.toISOString();
    }
    return typeof raw==='object'?JSON.stringify(raw):String(raw);
  }
  return null;
}

function documentTree(value,key,edit,path=[key]){
  const leaf=bsonValue(value);
  const row=document.createElement(leaf===null?'details':'div');
  row.className='doc-field';
  const title=leaf===null?document.createElement('summary'):row;
  const name=document.createElement('b');
  name.textContent=key;
  title.append(name);
  const content=document.createElement('code');
  content.textContent=typeof value==='string'?JSON.stringify(value):leaf??(Array.isArray(value)?'Array':'Object')+' · '+Object.keys(value).length;
  if(edit&&leaf!==null){
    const button=document.createElement('button');
    button.type='button';button.className='field-value';
    button.title=dataLabel('Sửa giá trị','Edit value');
    button.append(content);button.onclick=()=>edit(path,value,button);
    title.append(button);
  }else title.append(content);
  if(leaf===null){
    row.append(title);
    row.addEventListener('toggle',()=>{
      if(row.open && row.children.length===1){
        for(const [child,item] of Object.entries(value))row.append(documentTree(item,child,edit,[...path,child]));
      }
    });
  }
  return row;
}

function enableCollectionResize(layout){
  const handle=layout.querySelector('.collection-divider');
  const storageKey='mongo-collections-width-percent';
  const minimum=18,maximum=55;
  function setWidth(value){
    const percent=Math.min(maximum,Math.max(minimum,value));
    layout.style.setProperty('--collection-width',percent+'%');
    handle.setAttribute('aria-valuenow',String(Math.round(percent)));
    handle.setAttribute('aria-valuetext',Math.round(percent)+'%');
    return percent;
  }
  const saved=Number(localStorage.getItem(storageKey));
  let width=setWidth(saved>=minimum&&saved<=maximum?saved:23);
  let drag;
  handle.onpointerdown=e=>{
    if(e.button!==0||!e.isPrimary)return;
    e.preventDefault();
    drag={id:e.pointerId,x:e.clientX,width};
    handle.focus({preventScroll:true});
    handle.setPointerCapture(e.pointerId);
  };
  handle.onpointermove=e=>{
    if(drag?.id===e.pointerId)width=setWidth(drag.width+100*(e.clientX-drag.x)/layout.clientWidth);
  };
  handle.onlostpointercapture=()=>{
    if(drag)localStorage.setItem(storageKey,String(width));
    drag=null;
  };
  handle.onkeydown=e=>{
    const values={ArrowLeft:width-2,ArrowRight:width+2,Home:minimum,End:maximum};
    if(!Object.hasOwn(values,e.key))return;
    e.preventDefault();
    width=setWidth(values[e.key]);localStorage.setItem(storageKey,String(width));
  };
}

function currentExplorerPosition(){
  const position=history.state?.dataExplorer;
  return position?.profileId===profile()?.id && position.demo===demo ? position : null;
}

async function openDataExplorer(database,position=null){
  const area=$('#query-result'),pid=profile()?.id;
  if(!area||!pid)return;
  const root=document.createElement('div');
  root.className='data-explorer';
  area.replaceChildren(root);
  const active=()=>root.isConnected && currentRoute==='data' && profile()?.id===pid;
  function remember(details={}){
    history.replaceState({...history.state,dataExplorer:{profileId:pid,demo,database,...details}},'');
  }
  function backToDatabases(){
    history.replaceState({...history.state,dataExplorer:null},'');
    render();
  }
  if(!position)remember();
  const text=dataLabel;
  const sample=collection=>Array.from({length:24},(_,i)=>collection==='users'
    ?{_id:i+1,username:'user_'+String(i+1).padStart(2,'0'),active:i%2===0,metadata:{tags:['demo'],sequence:i+1}}
    :{_id:i+1,event:i%2?'sign_in':'page_view',metadata:{source:'web',sequence:i+1}});

  root.innerHTML=`<button class="text-button" data-back>← Databases</button><div class="loading">${uiText('Đang tải…')}</div>`;
  root.querySelector('[data-back]').onclick=backToDatabases;
  let collections;
  try{
    collections=demo?['users','events'].map(name=>({name,indexes:[{name:'_id_',key:{_id:1}}]})):
      await api('/profiles/'+pid+'/query/namespaces?database='+encodeURIComponent(database));
  }catch(e){if(active())root.querySelector('.loading').outerHTML=errorBox(e.message);return;}
  if(!active())return;
  root.innerHTML=`<div class="data-path"><button type="button" class="icon-button" data-panel aria-controls="collection-sidebar"></button><button class="text-button" data-back>Databases</button> / <strong>${esc(database)}</strong></div>
    <div class="data-layout"><aside id="collection-sidebar" class="data-sidebar"><h2>Collections <small>${collections.length}</small></h2>
    <input type="search" aria-label="Collections" placeholder="${text('Tìm collection','Find collection')}">
    <div class="collection-list"></div>
    <button type="button" class="icon-button panel-bottom-toggle" data-panel aria-controls="collection-sidebar"></button>
    <div class="collection-divider" role="separator" tabindex="0" aria-orientation="vertical" aria-controls="collection-sidebar"
      aria-valuemin="18" aria-valuemax="55" aria-label="${text('Điều chỉnh độ rộng Collections','Resize Collections')}"></div></aside><section class="data-docs"></section></div>`;
  root.querySelector('[data-back]').onclick=backToDatabases;
  const list=root.querySelector('.collection-list'),body=root.querySelector('.data-docs');
  enableCollectionResize(root.querySelector('.data-layout'));
  const panelToggles=root.querySelectorAll('[data-panel]');
  function showCollections(open){
    root.classList.toggle('collections-hidden',!open);
    for(const panelToggle of panelToggles){
      panelToggle.textContent=open?'«':'»';
      panelToggle.setAttribute('aria-expanded',String(open));
      panelToggle.title=panelToggle.ariaLabel=open?text('Thu gọn Collections','Collapse collections'):text('Mở Collections','Expand collections');
    }
  }
  showCollections(localStorage.getItem('mongo-collections-hidden')!=='1');
  for(const panelToggle of panelToggles)panelToggle.onclick=()=>{
    const open=root.classList.contains('collections-hidden');
    localStorage.setItem('mongo-collections-hidden',open?'0':'1');
    showCollections(open);
  };
  let selected,request=0;
  function listCollections(term=''){
    list.replaceChildren();
    for(const c of collections.filter(c=>c.name.toLowerCase().includes(term.toLowerCase()))){
      const button=document.createElement('button');
      button.type='button';button.title=c.name;button.ariaLabel=c.name;button.className='collection-item';
      button.innerHTML=icon('db')+'<span>'+esc(c.name)+'</span>';
      button.setAttribute('aria-pressed',String(c===selected));button.onclick=()=>openCollection(c);
      list.append(button);
    }
  }
  const search=root.querySelector('input[type=search]');
  search.oninput=()=>listCollections(search.value);
  function openCollection(c,saved=null){
    documentTailObserver?.disconnect();
    selected=c;listCollections(search.value);
    let offsets=saved?.offsets??[0],pageIndex=saved?.pageIndex??0,limit=Math.min(saved?.limit??25,25);
    let filter=saved?.filter??{field:'',value:''};
    const writable=(!c.type || c.type==='collection') && !['admin','local','config'].includes(database) && !c.name.startsWith('system.');
    const demoKey=JSON.stringify([pid,database,c.name]);
    function demoRows(){
      if(!demoDocumentCollections.has(demoKey))demoDocumentCollections.set(demoKey,sample(c.name));
      return demoDocumentCollections.get(demoKey);
    }
    const addLabel=text('Thêm document','Add document'),editLabel=text('Sửa JSON','Edit JSON'),deleteLabel=text('Xóa','Delete');
    async function writeDocument(action,original,raw){
      if(demo){
        const rows=demoRows();
        const draft=raw===undefined?null:JSON.parse(raw);
        if(raw!==undefined&&(!draft||typeof draft!=='object'||Array.isArray(draft)))throw Error(text('Cần nhập một object JSON.','Enter a JSON object.'));
        if(action==='insert'){
          if(!Object.hasOwn(draft,'_id'))draft._id=crypto.randomUUID();
          if(rows.some(row=>JSON.stringify(row._id)===JSON.stringify(draft._id)))throw Error(text('_id đã tồn tại.','Duplicate _id.'));
          rows.push(draft);
        }else{
          const i=rows.indexOf(original);
          if(i<0)throw Error(text('Document đã thay đổi.','Document changed.'));
          if(action==='delete')rows.splice(i,1);
          else{
            if(JSON.stringify(original._id)!==JSON.stringify(draft._id))throw Error(text('Giữ nguyên _id.','Keep the original _id.'));
            rows[i]=draft;
          }
        }
      }else await api('/profiles/'+pid+'/documents/write',{method:'POST',body:JSON.stringify({database,collection:c.name,action,original:JSON.stringify(original),document:raw})});
    }
    function showFields(container,original){
      function edit(path,value,button){
        if(container.querySelector('.inline-field-form'))return;
        const form=document.createElement('form');form.className='inline-field-form';
        form.innerHTML=`<textarea rows="1"></textarea><button class="button small primary" type="submit">${text('Lưu','Save')}</button><button class="button small" type="button">${uiText('Hủy')}</button><span role="alert"></span>`;
        const input=form.querySelector('textarea'),cancel=form.querySelector('[type=button]');
        const save=form.querySelector('[type=submit]');
        const footer=container.closest('dialog')?.querySelector('.modal-footer');
        if(footer){
          form.id='inspected-field-form';
          save.setAttribute('form',form.id);
          save.className='button primary';
          footer.insertBefore(save,footer.querySelector('[data-act=modal-close]'));
        }
        const wrapper=value&&typeof value==='object'?Object.keys(value)[0]:null;
        const numeric=['$numberInt','$numberLong','$numberDouble','$numberDecimal'].includes(wrapper);
        input.value=numeric?value[wrapper]:typeof value==='string'?value:JSON.stringify(value);
        input.setAttribute('aria-label',path.join('.'));
        const previewHeight=button.getBoundingClientRect().height;
        button.replaceWith(form);
        input.style.minHeight=`min(${Math.ceil(previewHeight)}px, 60vh)`;
        function fitValue(){
          input.style.height='auto';
          input.style.height=(input.scrollHeight+input.offsetHeight-input.clientHeight)+'px';
        }
        fitValue();
        input.oninput=fitValue;
        input.setSelectionRange(0,0);
        input.focus({preventScroll:true});
        cancel.onclick=()=>{save.remove();form.replaceWith(button);button.focus();};
        input.onkeydown=e=>{
          if(e.isComposing)return;
          if(e.key==='Escape'){e.preventDefault();e.stopPropagation();cancel.click();}
          if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();form.requestSubmit();}
        };
        form.onsubmit=async e=>{
          e.preventDefault();
          if(input.disabled||!active()||selected!==c)return;
          input.disabled=true;cancel.disabled=true;save.disabled=true;
          try{
            const next=numeric?{[wrapper]:input.value}:typeof value==='string'?input.value:JSON.parse(input.value);
            const draft=structuredClone(original);
            let parent=draft;
            for(const key of path.slice(0,-1))parent=parent[key];
            parent[path.at(-1)]=next;
            await writeDocument('replace',original,JSON.stringify(draft));
            save.remove();
            if(active()&&selected===c){
              if(container.closest('.inspected-doc')){
                const fresh=demo?demoRows().find(row=>JSON.stringify(row._id)===JSON.stringify(draft._id)):draft;
                container.replaceChildren(docActions(fresh));showFields(container,fresh);
              }
              await load();
            }
            toast(text('Đã lưu giá trị.','Value saved.'));
          }catch(err){form.querySelector('[role=alert]').textContent=err.message;input.disabled=false;cancel.disabled=false;save.disabled=false;input.focus();}
        };
      }
      for(const [key,value] of Object.entries(original)){
        container.append(documentTree(value,key,writable&&key!=='_id'?edit:null));
      }
    }
    function editDocument(action,original){
      const deleting=action==='delete';
      const title=action==='insert'?addLabel:deleting?text('Xóa document','Delete document'):text('Sửa document','Edit document');
      modal(title,`<div class="modal-body"><p><strong>${esc(database)} / ${esc(c.name)}</strong></p>${deleting?
        '<p>_id · <code>'+esc(JSON.stringify(original._id))+'</code></p>':
        '<label class="field"><span>Extended JSON</span><textarea rows="14" data-editor spellcheck="false"></textarea></label>'}
        <div role="alert" data-write-error></div></div>`,
        `<button class="button" data-act="modal-close">${uiText('Hủy')}</button><button class="button ${deleting?'danger':'primary'}" data-save-document>${deleting?deleteLabel:text('Lưu','Save')}</button>`);
      const editor=$('[data-editor]'),save=$('[data-save-document]'),error=$('[data-write-error]');
      if(editor)editor.value=JSON.stringify(original??{},null,2);
      save.onclick=async()=>{
        if(!active()||selected!==c)return;
        save.disabled=true;
        try{
          await writeDocument(action,original,editor?.value);
          if(save.isConnected)$('#modal').close();
          toast(deleting?text('Đã xóa document.','Document deleted.'):text('Đã lưu document.','Document saved.'));
          if(active()&&selected===c)await load();
        }catch(e){error.className='form-error';error.textContent=e.message;save.disabled=false;}
      };
    }
    function docActions(doc){
      const bar=document.createElement('div');bar.className='doc-controls';
      for(const [label,action] of [[editLabel,'replace'],[deleteLabel,'delete']]){
        const btn=document.createElement('button');btn.type='button';btn.className='button small'+(action==='delete'?' danger':'');
        btn.textContent=label;btn.onclick=()=>editDocument(action,doc);bar.append(btn);
      }
      return bar;
    }
    body.innerHTML=`<header class="data-title"><div><small>COLLECTION</small><h2>${esc(c.name)}</h2></div>${writable?'<button class="button primary" data-add-document>'+addLabel+'</button>':''}<button type="button" class="button small" data-backup-collection>${text('Backup collection','Back up collection')}</button></header>
      ${c.type==='view'?'':'<details class="data-index"><summary>Indexes</summary><pre></pre></details>'}
      <form class="data-filter"><label>${text('Trường','Field')}<input name="field" placeholder="metadata.sequence"></label>
      <label>${text('Giá trị JSON','JSON value')}<input name="value" placeholder='42 · "admin" · true'></label>
      <button class="button" type="submit">${text('Lọc','Filter')}</button></form>
      <div class="doc-controls"><label>${text('Hiển thị','View')} <select data-view><option value="compact">${text('Bảng gọn','Compact table')}</option><option value="detail">${text('Chi tiết','Details')}</option></select></label>
      <label>${text('Document mỗi trang','Documents per page')} <select data-limit>${[5,10,25].map(n=>`<option ${n===limit?'selected':''}>${n}</option>`).join('')}</select></label></div>
      <div class="doc-results" role="region" aria-label="Documents" tabindex="0" aria-live="polite"></div>`;
    body.querySelector('[data-backup-collection]').onclick=()=>openAction('backup',{databases:[database],collections:[c.name]});
    if(writable)body.querySelector('[data-add-document]').onclick=()=>editDocument('insert');
    const form=body.querySelector('form'),results=body.querySelector('.doc-results');
    form.elements.field.value=filter.field;
    form.elements.value.value=filter.value;
    const view=body.querySelector('[data-view]');
    view.value=localStorage.getItem('mongo-manager-data-view')==='detail'?'detail':'compact';
    let batches=[],nextBatch,columns=[];
    view.onchange=()=>{localStorage.setItem('mongo-manager-data-view',view.value);renderBatches();};
    body.querySelector('[data-limit]').onchange=e=>{limit=Number(e.target.value);offsets=[0];pageIndex=0;load();};
    const indexes=body.querySelector('.data-index');
    if(indexes)indexes.ontoggle=async()=>{
      if(!indexes.open||indexes.dataset.loaded)return;
      indexes.dataset.loaded='1';
      const output=indexes.querySelector('pre');
      output.textContent=uiText('Đang tải…');
      try{
        const data=demo?c.indexes:await api('/profiles/'+pid+'/query/indexes?'+new URLSearchParams({database,collection:c.name}));
        output.textContent=JSON.stringify(data,null,2);
      }catch(e){output.textContent=e.message;delete indexes.dataset.loaded;}
    };
    form.onsubmit=e=>{e.preventDefault();filter={field:form.elements.field.value.trim(),value:form.elements.value.value.trim()};offsets=[0];pageIndex=0;load();};
    const toolbar=document.createElement('div'),listArea=document.createElement('div'),tail=document.createElement('button');
    toolbar.className='doc-toolbar';tail.type='button';tail.className='button small doc-tail';
    results.before(toolbar);
    results.replaceChildren(listArea,tail);
    let currentPage=pageIndex,jumpAfterLoad=null;
    function drawPages(){
      if(!batches.length)return;
      const batch=batches.find(item=>item.index===currentPage);
      const range=batch?.rows.length?(batch.offset+1)+'–'+(batch.offset+batch.rows.length):'0';
      const last=offsets.length-1;
      const numbers=[...new Set([0,currentPage-1,currentPage,currentPage+1,last])]
        .filter(i=>i>=0&&i<=last).sort((a,b)=>a-b);
      const pageButton=(i,label,disabled=false,current=false)=>`<button class="button small" data-page="${i}" ${disabled?'disabled':''} ${current?'aria-current="page"':''}>${label}</button>`;
      toolbar.innerHTML=`<strong>Documents</strong><span>${range}</span><nav class="doc-pages" aria-label="${text('Phân trang','Pagination')}">`+
        pageButton(currentPage-1,text('Trước','Previous'),currentPage===0)+
        numbers.map((i,n)=>(n&&i>numbers[n-1]+1?'…':'')+pageButton(i,i+1,false,i===currentPage)).join('')+
        pageButton(currentPage+1,text('Sau','Next'),currentPage===last)+'</nav>';
      remember({collection:c.name,offsets,pageIndex:currentPage,limit,filter});
    }
    function scrollToBatch(batch){
      const top=batch.anchor?.getBoundingClientRect().top;
      if(top!==undefined)results.scrollTop+=top-results.getBoundingClientRect().top;
      currentPage=batch.index;drawPages();
    }
    toolbar.onclick=e=>{
      const button=e.target.closest('button[data-page]');
      if(!button||button.disabled)return;
      const index=Number(button.dataset.page);
      const batch=batches.find(item=>item.index===index);
      if(batch){jumpAfterLoad=null;scrollToBatch(batch);}
      else if(index===batches.at(-1)?.index+1){
        jumpAfterLoad=index;
        if(nextBatch===index)fetchBatch(index);
      }else{pageIndex=index;load();}
    };
    results.onscroll=()=>{
      if(!batches.length)return;
      const top=results.getBoundingClientRect().top+2;
      const batch=results.scrollTop>0&&results.scrollTop+results.clientHeight>=results.scrollHeight-1
        ?batches.at(-1):batches.findLast(item=>item.anchor?.getBoundingClientRect().top<=top)??batches[0];
      if(batch.index!==currentPage){currentPage=batch.index;drawPages();}
    };
    tail.onclick=()=>fetchBatch(nextBatch);
    function load(){
      documentTailObserver?.disconnect();
      currentPage=pageIndex;jumpAfterLoad=null;
      batches=[];columns=[];nextBatch=undefined;results.scrollTop=0;
      listArea.replaceChildren();toolbar.replaceChildren();
      return fetchBatch(pageIndex);
    }
    async function fetchBatch(index){
      if(index===undefined||!active()||selected!==c)return;
      nextBatch=undefined;
      documentTailObserver?.disconnect();
      const seq=++request,offset=offsets[index];
      tail.hidden=false;tail.disabled=true;tail.textContent=uiText('Đang tải…');
      try{
        let page;
        if(demo){
          if(!filter.field && filter.value)throw Error(text('Nhập tên trường cần lọc.','Enter a field name.'));
          const value=filter.field?JSON.parse(filter.value):null;
          const rows=demoRows().filter(d=>!filter.field||JSON.stringify(filter.field.split('.').reduce((o,k)=>o?.[k],d))===JSON.stringify(value));
          page={records:rows.slice(offset,offset+limit),more:rows.length>offset+limit};
        }else page=await api('/profiles/'+pid+'/documents',{method:'POST',body:JSON.stringify({database,collection:c.name,offset,limit,...filter})});
        if(!active()||seq!==request)return;
        const rows=page.records;
        if(!rows.length&&!batches.length&&pageIndex>0){pageIndex--;return load();}
        if(rows.length||!batches.length){
          const batch={rows,offset,index};
          batches.push(batch);
          batch.anchor=renderBatch(rows,offset);
        }
        if(page.more&&rows.length){
          offsets[index+1]=offset+rows.length;
          nextBatch=index+1;
        }
        if(!page.more)offsets.length=rows.length||index===0?index+1:index;
        drawPages();
        tail.hidden=nextBatch===undefined;tail.disabled=false;tail.textContent=text('Tải thêm','Load more');
        if(jumpAfterLoad===index){
          jumpAfterLoad=null;
          scrollToBatch(batches.at(-1));
        }
        if(!tail.hidden){
          documentTailObserver=new IntersectionObserver(entries=>{
            if(entries.some(entry=>entry.isIntersecting)&&seq===request)fetchBatch(nextBatch);
          },{root:results,rootMargin:'0px'});
          documentTailObserver.observe(tail);
        }
      }catch(e){
        if(!active()||seq!==request)return;
        nextBatch=index;tail.disabled=false;tail.textContent=e.message+' · '+text('Thử lại','Retry');
      }
    }
    function renderBatches(){
      listArea.replaceChildren();columns=[];
      for(const batch of batches)batch.anchor=renderBatch(batch.rows,batch.offset);
    }
    function renderBatch(rows,offset){
      if(rows.length&&view.value==='compact'){
        const known=new Set(columns);
        const added=[];
        for(const doc of rows){
          for(const key of Object.keys(doc)){
            if(known.has(key))continue;
            known.add(key);added.push(key);
          }
        }
        columns=columns.concat(added);
        const existing=listArea.querySelector('table');
        if(existing&&added.length){
          existing.tHead.rows[0].insertAdjacentHTML('beforeend',added.map(key=>`<th>${esc(key)}</th>`).join(''));
          const missing='<td>—</td>'.repeat(added.length);
          for(const row of existing.tBodies[0].rows)row.insertAdjacentHTML('beforeend',missing);
        }
        const cells=rows.map((doc,i)=>`<tr data-inspect="${i}" tabindex="0" aria-haspopup="dialog"><td class="row-number">${offset+i+1}</td>${columns.map(key=>{
          if(!Object.hasOwn(doc,key))return '<td>—</td>';
          const value=doc[key],summary=bsonValue(value)??(Array.isArray(value)?'Array':'Object')+' ('+Object.keys(value).length+')';
          return `<td><code>${esc(summary.slice(0,160))}</code></td>`;
        }).join('')}</tr>`);
        if(!listArea.firstChild)listArea.insertAdjacentHTML('beforeend',`<div class="doc-compact">${table([uiText('STT'),...columns.map(esc)],[])}</div>`);
        const tbody=listArea.querySelector('tbody');
        const firstNewRow=tbody.rows.length;
        tbody.insertAdjacentHTML('beforeend',cells.join(''));
        for(let i=0;i<rows.length;i++){
          const row=tbody.rows[firstNewRow+i];
          row.onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();row.click();}};
          row.onclick=()=>{
            const doc=rows[Number(row.dataset.inspect)];
            modal('Document',`<div class="modal-body inspected-doc"></div>`,`<button class="button" data-act="modal-close">${uiText('Đóng')}</button>`);
            const container=document.querySelector('.inspected-doc');
            if(writable)container.append(docActions(doc));
            showFields(container,doc);
          };
        }
        return tbody.rows[firstNewRow];
      }
      const firstNewCard=listArea.children.length;
      if(!rows.length)listArea.insertAdjacentHTML('beforeend',`<p class="doc-empty">${text('Không có document phù hợp.','No matching documents.')}</p>`);
      rows.forEach((doc,i)=>{
        const card=document.createElement('details');card.className='doc-card';
        const id=doc._id===undefined?'#'+(offset+i+1):bsonValue(doc._id)??JSON.stringify(doc._id);
        card.innerHTML=`<summary><span>_id</span><code>${esc(id)}</code></summary>`;
        card.addEventListener('toggle',()=>{
          if(!card.open||card.children.length!==1)return;
          const fields=document.createElement('div');
          showFields(fields,doc);
          const toggle=document.createElement('button');
          toggle.type='button';toggle.className='doc-view-toggle';toggle.textContent='Extended JSON';
          toggle.setAttribute('aria-pressed','false');
          toggle.onclick=()=>{
            const raw=toggle.getAttribute('aria-pressed')==='false';
            toggle.setAttribute('aria-pressed',String(raw));
            toggle.textContent=raw?text('Xem trường','View fields'):'Extended JSON';
            if(raw){
              const pre=document.createElement('pre');pre.className='doc-json';
              pre.textContent=JSON.stringify(doc,null,2);fields.after(pre);fields.hidden=true;
            }else{fields.nextElementSibling.remove();fields.hidden=false;}
          };
          if(writable)card.append(docActions(doc));
          card.append(toggle,fields);
        });
        listArea.append(card);
        if(i===0&&offset===batches[0].offset)card.open=true;
      });
      return listArea.children[firstNewCard];
    }
    load();
  }
  const previous=collections.find(c=>c.name===position?.collection);
  if(previous)openCollection(previous,position);
  else if(collections.length)openCollection(collections[0]);
  else body.textContent=text('Database chưa có collection.','This database has no collections.');
}
