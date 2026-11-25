function managerLogin(editAccount=false){
  const params=new URLSearchParams({next:location.pathname+location.search+location.hash});
  if(editAccount)params.set('account','1');
  location.replace('/login?'+params);
}

window.addEventListener('storage',event=>{
  if(event.key==='mongo-manager-demo')location.reload();
});
