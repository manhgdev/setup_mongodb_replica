// All VPS API calls in preview mode terminate here, including unsupported operations.
let sampleCatalog;
async function previewVps(path,data){
  const machine='vps/machines/demo';
  const route=path.split('?')[0];
  const domain='web.example.test';
  const source='/etc/nginx/sites-available/'+domain;
  const site={domain,primary:domain,source,file_id:'web',kind:'proxy',target:'127.0.0.1:3000',listeners:['443'],https:true,enabled:true,managed:false,expires:64,renewal_names:[domain]};
  if(!data){
    switch(route){
      case 'vps/machines':return [{id:'demo',name:'Ubuntu VPS · Demo'}];
      case machine:{
        sampleCatalog ||= await api('vps/catalog');
        return {...sampleCatalog,host:'web-demo',os:'Ubuntu 24.04 LTS',arch:'amd64',cpu:4,memory:'8 GiB',disk_total:80*2**30,disk_used:32*2**30,memory_total:8*2**30,memory_available:5*2**30,load_average:[0.38,0.46,0.42],kernel:'6.8.0-generic',uptime_seconds:896400,disk_free:48*2**30,nginx:'active',manager:'apt',
        packages:{...Object.fromEntries(Object.keys(sampleCatalog.catalog).map(id=>[id,''])),git:'2.43.0',nginx:'1.24.0',curl:'8.5.0','docker-engine':'Docker 28 (demo)','docker-service':'active','docker-compose':'2.40 (demo)'}};}
      case machine+'/git/status':return {git:'git version 2.43',ssh:'OpenSSH 9.6',username:'Demo',email:'demo@example.test',keys:[],aliases:{}};
      case machine+'/docker/status':return {engine:true,active:true,compose:'2.40 (demo)',containers:[{ID:'a'.repeat(64),Names:'web-demo',State:'running',Status:'Up · demo',Image:'nginx:alpine',Ports:'127.0.0.1:8080 → 80'}]};
      case machine+'/firewall':return {ufw:{installed:true,active:true,error:'',rules:[]},ssh_ports:[22],listening:[],oracle:{detected:true,region:'ap-singapore-1',shape:'VM.Standard.A1.Flex',instance_id:'ocid1.instance.oc1..demo'},accounts:[{id:'demo',name:'Demo',auth:'api_key',region:'ap-singapore-1'}],link:{account_id:'demo',account:'Demo',region:''},oci_error:'',
        oci:{instance:{id:'ocid1.instance.oc1..demo',name:'web-demo',state:'RUNNING'},vnics:[{id:'ocid1.vnic.oc1..demo',private_ip:'10.0.0.12',public_ip:'203.0.113.10',vcn:{name:'vcn-demo',cidr:'10.0.0.0/16'},subnet:{name:'public',cidr:'10.0.0.0/24'},security_lists:[{id:'sl',name:'Default',rules:[]}],nsgs:[]}]},
        rows:[{proto:'tcp',min:22,max:22,listening:[{port:22,process:'sshd',local_only:false}],internal:true,external:'open',ufw:'open',oci:'open',warnings:[]},{proto:'tcp',min:80,max:80,listening:[{port:80,process:'nginx',local_only:false}],internal:true,external:'closed',ufw:'open',oci:'closed',warnings:['oci_blocked']},{proto:'tcp',min:443,max:443,listening:[{port:443,process:'nginx',local_only:false}],internal:true,external:'open',ufw:'open',oci:'open',warnings:[]}]};
      case 'vps/servers':return [{id:'demo',name:'Ubuntu VPS · Demo',mode:'ssh',host:'203.0.113.10',port:22,user:'root',ssh_auth:'password',has_ssh_password:true,mongo_endpoint:'203.0.113.10:27017'}];
      case machine+'/docker/logs':return {text:'web-demo · GET / 200'};
      case machine+'/docker/plan':return {project:'web-demo',services:[{name:'web',image:'nginx:alpine'}],revision:'demo'};
      case machine+'/packages':{
        const params=new URL(path,location.origin).searchParams;
        const installed=params.get('scope')==='installed';
        const items=(installed?['curl','git','nginx']:['curl','git','nginx','tree','zip']).filter(name=>name.includes(params.get('query')||'')).map(name=>({name,version:installed?'1.0 (demo)':''}));
        return {total:items.length,items};
      }
      case machine+'/package-plan':{
        const name=new URL(path,location.origin).searchParams.get('name');
        return {target:name,summary:vpsEnglish?'Preview only':'Kế hoạch minh họa'};
      }
      case machine+'/account':return {user:'ubuntu',host:'web.example.test',port:22,sudo:true,auth:'key',password:'no'};
      case machine+'/nginx':return {sites:[site],diagnostics:[],capabilities:{},php_sockets:[]};
      case machine+'/nginx/web/detail':return {source:'server {\n    listen 443 ssl;\n    server_name '+domain+';\n    location / { proxy_pass http://127.0.0.1:3000; }\n}',editable:false,domains:[domain],diagnostics:[],history:[]};
      case machine+'/nginx/web/ssl-status':return {served:{names:[domain],expires:'64 days'},timer:'active'};
      case machine+'/nginx/web/logs':
      case machine+'/pm2':return [];
      case machine+'/jobs':return [{id:'sample',target:'web-demo',label:'Nginx',status:'succeeded',events:[{message:'nginx -t · OK'}]}];
    }
  }
  throw new Error(vpsEnglish?'Preview mode uses sample data. Switch to live data to run this action.':'Đang xem dữ liệu minh họa. Chuyển sang dữ liệu thật để thực hiện thao tác.');
}
